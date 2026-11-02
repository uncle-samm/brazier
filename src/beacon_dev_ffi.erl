-module(beacon_dev_ffi).
-export([sleep/1, check_for_changes/1, record_file_timestamps/1,
         find_gleam_files/1, reload_modules/1, start_app/1,
         start_native_watcher/1, poll_native_watcher/0,
         native_watcher_available/0, notify_browser_reload/0]).

%% Paths arrive as UTF-8 binaries and are converted with the unicode module,
%% never binary_to_list/list_to_binary, so a non-ASCII project path works.

%% Process-dictionary keys of the dev process.
-define(TIMESTAMP_KEY, beacon_dev_timestamps).
-define(WATCHER_KEY, beacon_native_watcher_port).

sleep(Ms) ->
    timer:sleep(Ms),
    nil.

%% Record the modification time of every .gleam file below Dirs, as the
%% baseline for check_for_changes/1.
record_file_timestamps(Dirs) ->
    erlang:put(?TIMESTAMP_KEY, timestamps(Dirs)),
    nil.

%% True when a .gleam file below Dirs was added, removed or modified since the
%% last call (or since record_file_timestamps/1).
check_for_changes(Dirs) ->
    Old = case erlang:get(?TIMESTAMP_KEY) of
        undefined -> [];
        T -> T
    end,
    New = timestamps(Dirs),
    erlang:put(?TIMESTAMP_KEY, New),
    Old =/= New.

timestamps(Dirs) ->
    Files = lists:flatmap(fun find_gleam_files/1, Dirs),
    [{F, mtime(F)} || F <- Files].

%% A file that vanished between listing and stat records its error, which
%% differs from any earlier timestamp, so the change is still detected.
mtime(File) ->
    case file:read_file_info(File, [{time, posix}]) of
        {ok, Info} -> element(6, Info);
        {error, Reason} -> {error, Reason}
    end.

%% Every .gleam file below Dir, recursively. A Dir that does not exist has
%% none; a directory that exists but cannot be listed crashes the caller.
find_gleam_files(Dir) ->
    DirStr = unicode:characters_to_list(Dir),
    case filelib:is_dir(DirStr) of
        true ->
            {ok, Entries} = file:list_dir(DirStr),
            lists:flatmap(
                fun(Entry) ->
                    Path = filename:join(DirStr, Entry),
                    case filelib:is_dir(Path) of
                        true -> find_gleam_files(unicode:characters_to_binary(Path));
                        false ->
                            case filename:extension(Entry) of
                                ".gleam" -> [unicode:characters_to_binary(Path)];
                                _ -> []
                            end
                    end
                end,
                lists:sort(Entries)
            );
        false ->
            []
    end.

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
            logger:error("[beacon.dev] Cannot reload ~ts: ~ts", [Name, Reason]),
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
                        logger:notice("[beacon.dev] ~p:main/0 returned; stopping", [Module]),
                        erlang:halt(0)
                    end),
                    {ok, nil};
                false ->
                    {error, format("The app module ~p has no main/0; dev mode starts the app by calling it.", [Module])}
            end;
        {error, Reason} ->
            {error, format("Cannot load the app module ~p: ~p", [Module, Reason])}
    end.

%% Notify connected browsers to reload via PubSub.
notify_browser_reload() ->
    try pg:get_members(beacon_pg, <<"beacon:reload">>) of
        Pids ->
            [Pid ! {beacon_reload} || Pid <- Pids],
            {ok, nil}
    catch
        Class:Reason ->
            logger:warning("[beacon.dev] notify_browser_reload failed: ~p:~p", [Class, Reason]),
            {error, format("~p:~p", [Class, Reason])}
    end.

%% True when fswatch (macOS) or inotifywait (Linux) is installed.
native_watcher_available() ->
    case watcher_command([]) of
        {ok, Program, _Args} -> os:find_executable(Program) =/= false;
        {unsupported, _} -> false
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

%% Start a watcher that reports the next change below Dirs and exits.
start_native_watcher(Dirs) ->
    case watcher_command([unicode:characters_to_list(D) || D <- Dirs]) of
        {unsupported, Os} ->
            {error, format("No native watcher for os:type() = ~p", [Os])};
        {ok, Program, Args} ->
            case os:find_executable(Program) of
                false ->
                    {error, unicode:characters_to_binary(["Executable not found: ", Program])};
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
