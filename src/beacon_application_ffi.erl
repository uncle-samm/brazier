-module(beacon_application_ffi).
-export([trap_exit/0, receive_wait_event/0, get_env_int/1, generate_strong_secret/0,
         fail_loudly/1, once_new/0, once_take/1, stop_supervisor/2,
         remember_app/2, forget_app/1, remembered_apps/0, is_linked/1, await_exit/1]).

-define(APPS_KEY, '$beacon_started_apps').

%% Enable trapping of exit signals (SIGTERM etc.)
trap_exit() ->
    process_flag(trap_exit, true),
    nil.

%% Block until SIGTERM (forwarded by beacon_signal_handler) or the exit of
%% a linked process. Returns sigterm, shutdown_requested for a `normal`
%% exit (application.stop on the root supervisor), and
%% {linked_process_exited, ReasonBin} for any other exit. A supervisor that
%% gives up after too many restarts exits with `shutdown`: that is a
%% failure, not a request, so it is reported as an exit too. Because the
%% caller traps exits, swallowing those would leave the application running
%% with a dead tree. No timeout: nothing needs to happen until one arrives.
receive_wait_event() ->
    receive
        {beacon_signal, sigterm} -> sigterm;
        {'EXIT', _From, normal} -> shutdown_requested;
        {'EXIT', From, Reason} ->
            {linked_process_exited,
             iolist_to_binary(io_lib:format("~p exited with ~p", [From, Reason]))}
    end.

%% The applications this process started and has not stopped, newest first,
%% keyed by their supervisor pid. wait_forever stops them on SIGTERM.
remember_app(Pid, App) when is_pid(Pid) ->
    put(?APPS_KEY, [{Pid, App} | lists:keydelete(Pid, 1, apps())]),
    nil.

forget_app(Pid) when is_pid(Pid) ->
    put(?APPS_KEY, lists:keydelete(Pid, 1, apps())),
    nil.

remembered_apps() ->
    [App || {_Pid, App} <- apps()].

apps() ->
    case get(?APPS_KEY) of
        undefined -> [];
        Apps when is_list(Apps) -> Apps
    end.

is_linked(Pid) ->
    {links, Links} = process_info(self(), links),
    lists:member(Pid, Links).

%% The exit message of a linked process this process (trapping exits) just
%% stopped. INVARIANT: the caller checked the link before stopping it, so
%% the message is certain to arrive; no timeout is needed.
await_exit(Pid) ->
    receive
        {'EXIT', Pid, Reason} ->
            iolist_to_binary(io_lib:format("~p", [Reason]))
    end.

%% Generate a cryptographically secure secret key using crypto:strong_rand_bytes/1.
%% Returns a URL-safe base64-encoded string prefixed with "beacon_".
generate_strong_secret() ->
    Bytes = crypto:strong_rand_bytes(32),
    Base = base64:encode(Bytes, #{mode => urlsafe, padding => false}),
    <<"beacon_", Base/binary>>.

%% Get an integer environment variable.
%% {ok, N} | {error, env_not_set} | {error, {env_not_integer, ValueBin}}.
get_env_int(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, env_not_set};
        Value ->
            try list_to_integer(string:trim(Value)) of
                N -> {ok, N}
            catch
                error:badarg ->
                    {error, {env_not_integer, unicode:characters_to_binary(Value)}}
            end
    end.

%% Stop the calling process with an error. Used where continuing would
%% hide a configuration or supervision failure.
fail_loudly(Reason) when is_binary(Reason) ->
    erlang:error({beacon_application, Reason}).

%% A one-shot flag shared by every process holding it: once_take/1 returns
%% true for the first caller only (atomic compare-and-exchange 0 -> 1).
once_new() ->
    atomics:new(1, []).

once_take(Ref) ->
    atomics:compare_exchange(Ref, 1, 0, 1) =:= ok.

%% Stop a supervisor synchronously with reason `normal`: it terminates its
%% children in reverse start order, then exits. A linked caller that does
%% not trap exits is unaffected by a normal exit.
stop_supervisor(Pid, Timeout) ->
    try proc_lib:stop(Pid, normal, Timeout) of
        ok -> {ok, nil}
    catch
        exit:noproc ->
            {error, iolist_to_binary(io_lib:format("~p is not running", [Pid]))};
        exit:timeout ->
            {error, iolist_to_binary(
                      io_lib:format("~p did not stop within ~pms", [Pid, Timeout]))};
        exit:Reason ->
            {error, iolist_to_binary(
                      io_lib:format("~p exited with ~p while stopping", [Pid, Reason]))}
    end.
