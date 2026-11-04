-module(brazier_application_ffi).
-export([trap_exit/0, receive_wait_event/0, get_env_int/1,
         fail_loudly/1, once_new/0, once_take/1, stop_supervisor/2,
         remember_app/2, forget_app/1, remembered_apps/0, is_linked/1, await_exit/1,
         drain_exclusively/1, take_pending_sigterm/0, pass_on_sigterm/0]).

%% The persistent_term key of one running application, by supervisor pid.
-define(APP_KEY(Pid), {?MODULE, started_app, Pid}).

%% Enable trapping of exit signals (SIGTERM etc.)
trap_exit() ->
    process_flag(trap_exit, true),
    nil.

%% Block until SIGTERM (forwarded by brazier_signal_handler) or the exit of
%% a linked process. Returns sigterm, shutdown_requested for a `normal`
%% exit (application.stop on the root supervisor), and
%% {linked_process_exited, ReasonBin} for any other exit. A supervisor that
%% gives up after too many restarts exits with `shutdown`: that is a
%% failure, not a request, so it is reported as an exit too. Because the
%% caller traps exits, swallowing those would leave the application running
%% with a dead tree. No timeout: nothing needs to happen until one arrives.
receive_wait_event() ->
    receive
        {brazier_signal, sigterm} -> sigterm;
        {'EXIT', _From, normal} -> shutdown_requested;
        {'EXIT', From, Reason} ->
            {linked_process_exited,
             iolist_to_binary(io_lib:format("~p exited with ~p", [From, Reason]))}
    end.

%% The applications started on this node and not stopped, newest first,
%% keyed by their supervisor pid. wait_forever stops them on SIGTERM, from
%% whichever process it runs in, so the record is node-wide: one
%% persistent_term per application, written when it starts and erased when
%% it stops, as brazier_http_conns does for a listener's bound port. Starts
%% and stops are rare, which is what persistent_term is for. A tree that
%% died without `stop` keeps its entry until a `stop` or a SIGTERM finds it
%% not running.
remember_app(Pid, App) when is_pid(Pid) ->
    persistent_term:put(?APP_KEY(Pid), {erlang:unique_integer([monotonic]), App}),
    nil.

forget_app(Pid) when is_pid(Pid) ->
    _ = persistent_term:erase(?APP_KEY(Pid)),
    nil.

remembered_apps() ->
    Started = [{Seq, App} || {?APP_KEY(_Pid), {Seq, App}} <- persistent_term:get()],
    [App || {_Seq, App} <- lists:reverse(lists:keysort(1, Started))].

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
%% Returns a URL-safe base64-encoded string prefixed with "brazier_".
%% Run Drain while holding the node's SIGTERM drain lock: every process in
%% wait_forever is told about SIGTERM, and they drain one after the other,
%% so an application is never stopped by two of them at once, and none
%% returns while another is still draining. The lock is global's, scoped to
%% this node (global:trans with Nodes = [node()], retried until taken).
drain_exclusively(Drain) when is_function(Drain, 0) ->
    global:trans({brazier_sigterm_drain, self()}, Drain, [node()], infinity).

%% A SIGTERM the handler forwarded to this process and nobody received:
%% true once per pending one. Checked after the handler let this process
%% go, so every forwarded SIGTERM is already in the mailbox (the handler
%% sends it before it answers the leave). A zero timeout reads the mailbox
%% without waiting.
take_pending_sigterm() ->
    receive
        {brazier_signal, sigterm} -> true
    after 0 -> false
    end.

%% Hand a SIGTERM back to the signal server, as the VM delivers one: to the
%% other waiters if any, else to OTP's handler (init:stop()).
pass_on_sigterm() ->
    gen_event:notify(erl_signal_server, sigterm),
    nil.

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
    erlang:error({brazier_application, Reason}).

%% A one-shot flag shared by every process holding it: once_take/1 returns
%% true for the first caller only (atomic compare-and-exchange 0 -> 1).
once_new() ->
    atomics:new(1, []).

once_take(Ref) ->
    atomics:compare_exchange(Ref, 1, 0, 1) =:= ok.

%% Stop a supervisor synchronously with reason `normal`: it terminates its
%% children in reverse start order, then exits. A linked caller that does
%% not trap exits is unaffected by a normal exit. A supervisor that is not
%% running is {error, {not_running, Text}}, apart from a stop that failed,
%% {error, {stop_failed, Text}}.
stop_supervisor(Pid, Timeout) ->
    try proc_lib:stop(Pid, normal, Timeout) of
        ok -> {ok, nil}
    catch
        exit:noproc ->
            {error, {not_running, format("~p is not running", [Pid])}};
        exit:timeout ->
            {error, {stop_failed,
                     format("~p did not stop within ~pms", [Pid, Timeout])}};
        exit:Reason ->
            {error, {stop_failed,
                     format("~p exited with ~p while stopping", [Pid, Reason])}}
    end.

format(Format, Args) ->
    iolist_to_binary(io_lib:format(Format, Args)).
