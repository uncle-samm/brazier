-module(brazier_application_ffi).
-export([trap_exit/0, receive_wait_event/1, get_env_int/1,
         fail_loudly/1, once_new/0, once_take/1, stop_supervisor/2,
         remember_app/3, forget_app/1, remembered_apps/0, app_watcher/1,
         is_remembered/1, is_linked/1, await_exit/1,
         drain_exclusively/1, take_pending_sigterm/0, pass_on_sigterm/0]).

%% The persistent_term key of one running application, by supervisor pid.
-define(APP_KEY(Pid), {?MODULE, started_app, Pid}).

%% Enable trapping of exit signals (SIGTERM etc.)
trap_exit() ->
    process_flag(trap_exit, true),
    nil.

%% Block until SIGTERM (forwarded by brazier_signal_handler) or the exit of
%% a linked process. Waited holds the supervisors of the applications this
%% process waits on (linked to it when the wait began). Returns:
%%
%% - sigterm;
%% - shutdown_requested for a `normal` exit of a waited supervisor
%%   (application.stop on it);
%% - {other_link_exited_normally, FromBin} for a `normal` exit of any other
%%   linked process: a helper that finished is not a request to stop, and
%%   without trapping exits it would not have touched this process either,
%%   so the caller logs it and waits again;
%% - {linked_process_exited, ReasonBin} for any other exit, of whichever
%%   linked process. A supervisor that gives up after too many restarts
%%   exits with `shutdown`: that is a failure, not a request, so it is
%%   reported as an exit too. Because the caller traps exits, swallowing
%%   those would leave the application running with a dead tree.
%%
%% No timeout: nothing needs to happen until one arrives.
receive_wait_event(Waited) when is_list(Waited) ->
    receive
        {brazier_signal, sigterm} -> sigterm;
        {'EXIT', From, normal} ->
            case lists:member(From, Waited) of
                true -> shutdown_requested;
                false -> {other_link_exited_normally, format("~p", [From])}
            end;
        {'EXIT', From, Reason} ->
            {linked_process_exited, format("~p exited with ~p", [From, Reason])}
    end.

%% The applications started on this node and not stopped, newest first,
%% keyed by their supervisor pid. wait_forever stops them on SIGTERM, from
%% whichever process it runs in, so the record is node-wide: one
%% persistent_term per application, as brazier_http_conns does for a
%% listener's bound port. Starts and stops are rare, which is what
%% persistent_term is for. Each entry is written by the application's
%% watcher (application.gleam), which monitors the supervisor first and
%% erases the entry when the tree goes, stopped or crashed, as OTP's
%% application controller notices an application master's exit.
remember_app(Pid, App, Watcher) when is_pid(Pid), is_pid(Watcher) ->
    persistent_term:put(?APP_KEY(Pid),
                        {erlang:unique_integer([monotonic]), App, Watcher}),
    nil.

%% Whether there was an entry to erase.
forget_app(Pid) when is_pid(Pid) ->
    persistent_term:erase(?APP_KEY(Pid)).

remembered_apps() ->
    Started = [{Seq, App} || {?APP_KEY(_Pid), {Seq, App, _Watcher}} <- persistent_term:get()],
    [App || {_Seq, App} <- lists:reverse(lists:keysort(1, Started))].

%% The watcher of a remembered application: {ok, Pid} | {error, nil}.
app_watcher(Pid) when is_pid(Pid) ->
    case persistent_term:get(?APP_KEY(Pid), undefined) of
        {_Seq, _App, Watcher} -> {ok, Watcher};
        undefined -> {error, nil}
    end.

is_remembered(Pid) when is_pid(Pid) ->
    persistent_term:get(?APP_KEY(Pid), undefined) =/= undefined.

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
