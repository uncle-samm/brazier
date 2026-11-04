-module(beacon_dev_ffi).
-export([reload_modules/1, start_app/1,
         start_native_watcher/1, poll_native_watcher/0,
         watcher_requirement/0, find_executable/1,
         enable_live_reload/0, live_reload_enabled/0, live_reload_topic/0,
         notify_browser_reload/0]).

%% Paths arrive as UTF-8 binaries and are converted with the unicode module,
%% never binary_to_list/list_to_binary, so a non-ASCII project path works.

%% Process-dictionary key of the dev process.
-define(WATCHER_KEY, beacon_native_watcher_port).

%% The PubSub topic WebSocket handlers subscribe to in dev mode, and the
%% message a rebuild broadcasts on it. beacon_transport_ffi:ws_classify_message/1
%% turns {beacon_pubsub, ?RELOAD_TOPIC, ?RELOAD_MESSAGE} into dev_reload.
-define(RELOAD_TOPIC, <<"beacon:dev:reload">>).
-define(RELOAD_MESSAGE, beacon_dev_reload).
-define(LIVE_RELOAD_KEY, {beacon_dev, live_reload}).

%% Load every module in Ebin whose compiled code differs from the loaded
%% version, or that is not loaded yet. Any module that cannot be reloaded
%% makes the whole call an error naming it.
reload_modules(Ebin) ->
    Dir = unicode:characters_to_list(Ebin),
    case file:list_dir(Dir) of
        {ok, Files} ->
            Modules = lists:sort(
                [filename:rootname(F) || F <- Files, filename:extension(F) =:= ".beam"]
            ),
            reload_each(Dir, Modules, [], []);
        {error, Reason} ->
            {error, format("Cannot list ~ts: ~tp", [Dir, Reason])}
    end.

reload_each(_Dir, [], Reloaded, []) ->
    {ok, [unicode:characters_to_binary(M) || M <- lists:reverse(Reloaded)]};
reload_each(_Dir, [], _Reloaded, Failed) ->
    {error, unicode:characters_to_binary(lists:join("; ", lists:reverse(Failed)))};
reload_each(Dir, [Name | Rest], Reloaded, Failed) ->
    Module = list_to_atom(Name),
    Base = filename:join(Dir, Name),
    case reload(Module, Base) of
        unchanged -> reload_each(Dir, Rest, Reloaded, Failed);
        reloaded -> reload_each(Dir, Rest, [Name | Reloaded], Failed);
        {failed, Reason} ->
            beacon_log_ffi:error(<<"beacon.dev">>, "Cannot reload ~ts: ~ts", [Name, Reason]),
            reload_each(Dir, Rest, Reloaded, [[Name, ": ", Reason] | Failed])
    end.

reload(Module, Base) ->
    case changed(Module, Base ++ ".beam") of
        {error, Reason} -> {failed, Reason};
        {ok, false} -> unchanged;
        {ok, true} ->
            %% soft_purge refuses while a process still runs the old version,
            %% instead of killing it.
            case code:soft_purge(Module) of
                false -> {failed, <<"a process still runs its previous version">>};
                true ->
                    case code:load_abs(Base) of
                        {module, Module} -> reloaded;
                        {error, Reason} -> {failed, format("~p", [Reason])}
                    end
            end
    end.

changed(Module, Path) ->
    case code:is_loaded(Module) of
        false -> {ok, true};
        {file, _} ->
            case beam_lib:md5(Path) of
                {ok, {Module, Md5}} -> {ok, Md5 =/= Module:module_info(md5)};
                {ok, {Other, _}} ->
                    {error, format("~ts defines module ~p", [Path, Other])};
                {error, beam_lib, Reason} ->
                    {error, format("Cannot read ~ts: ~tp", [Path, Reason])}
            end
    end.

%% Call Module:main() in a process linked to the caller. A crash in the app
%% takes dev mode down with it; main returning ends the program, as it does
%% under `gleam run`.
start_app(ModuleName) ->
    Module = binary_to_atom(ModuleName),
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, main, 0) of
                true ->
                    spawn_link(fun() ->
                        Module:main(),
                        beacon_log_ffi:notice(<<"beacon.dev">>, "~p:main/0 returned; stopping", [Module]),
                        erlang:halt(0)
                    end),
                    {ok, nil};
                false ->
                    {error, format("The app module ~p has no main/0; dev mode starts the app by calling it.", [Module])}
            end;
        {error, Reason} ->
            {error, format("Cannot load the app module ~p: ~p", [Module, Reason])}
    end.

%% Turn live reload on for this VM: every WebSocket connection opened from
%% now on subscribes to the reload topic. Called once by beacon/dev before it
%% starts the app; nothing turns it off, because dev mode runs until the VM
%% stops. A persistent_term is read without copying on every connection and
%% written once.
enable_live_reload() ->
    persistent_term:put(?LIVE_RELOAD_KEY, true),
    nil.

%% True only in a VM where beacon/dev called enable_live_reload/0. Outside dev
%% mode the key is absent, which is the normal production state, not an
%% error.
live_reload_enabled() ->
    persistent_term:get(?LIVE_RELOAD_KEY, false).

live_reload_topic() ->
    ?RELOAD_TOPIC.

%% Tell every WebSocket connection on this node to reload its page. Returns
%% the number of connections subscribed when the broadcast was sent.
notify_browser_reload() ->
    Count = beacon_pubsub_ffi:local_subscriber_count(?RELOAD_TOPIC),
    case beacon_pubsub_ffi:local_broadcast(?RELOAD_TOPIC, ?RELOAD_MESSAGE) of
        {ok, nil} -> {ok, Count};
        {error, Reason} -> {error, format("PubSub refused the reload broadcast: ~tp", [Reason])}
    end.

%% The watcher program for this OS and the package that provides it, for the
%% error dev mode exits with when the program is not installed.
watcher_requirement() ->
    case watcher_command([]) of
        {ok, "fswatch", _} -> {ok, {<<"fswatch">>, <<"fswatch (brew install fswatch)">>}};
        {ok, "inotifywait", _} -> {ok, {<<"inotifywait">>, <<"inotify-tools (apt install inotify-tools)">>}};
        {unsupported, Os} -> {error, format("Dev mode watches files with fswatch on macOS or inotifywait on Linux; "
                                            "there is no watcher for os:type() = ~p", [Os])}
    end.

watcher_command(DirArgs) ->
    case os:type() of
        {unix, darwin} ->
            {ok, "fswatch", ["-1", "--include", "\\.gleam$", "--exclude", ".*"] ++ DirArgs};
        {unix, linux} ->
            {ok, "inotifywait", ["-r", "-e", "modify,create,delete,move", "--include", "\\.gleam$"] ++ DirArgs};
        Other ->
            {unsupported, Other}
    end.

%% The path of Program on the PATH.
find_executable(Program) ->
    case os:find_executable(unicode:characters_to_list(Program)) of
        false -> {error, nil};
        Path -> {ok, unicode:characters_to_binary(Path)}
    end.

%% Start a watcher that reports the next change below Dirs and exits.
start_native_watcher(Dirs) ->
    case watcher_command([unicode:characters_to_list(D) || D <- Dirs]) of
        {unsupported, Os} ->
            {error, format("No native watcher for os:type() = ~p", [Os])};
        {ok, Program, Args} ->
            case os:find_executable(Program) of
                false ->
                    {error, unicode:characters_to_binary([Program, " is not installed or not on the PATH"])};
                Executable ->
                    try open_port({spawn_executable, Executable},
                                  [{args, Args}, stream, exit_status, binary]) of
                        Port ->
                            erlang:put(?WATCHER_KEY, Port),
                            {ok, nil}
                    catch
                        error:Reason ->
                            {error, format("Cannot start ~ts: ~tp", [Program, Reason])}
                    end
            end
    end.

%% Wait up to 100ms for the watcher. True when it reported a change; the
%% watcher is then closed and must be restarted for the next change. A
%% watcher that exits with a non-zero status crashes dev mode.
poll_native_watcher() ->
    case erlang:get(?WATCHER_KEY) of
        undefined -> erlang:error(native_watcher_not_started);
        Port ->
            receive
                {Port, {data, _}} ->
                    close_watcher(Port),
                    true;
                {Port, {exit_status, 0}} ->
                    erlang:erase(?WATCHER_KEY),
                    true;
                {Port, {exit_status, Status}} ->
                    erlang:error({native_watcher_failed, Status})
            after 100 ->
                false
            end
    end.

close_watcher(Port) ->
    erlang:erase(?WATCHER_KEY),
    case erlang:port_info(Port) of
        undefined -> ok;
        _ -> port_close(Port)
    end,
    receive {Port, _} -> ok after 0 -> ok end,
    ok.

format(Format, Args) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).
