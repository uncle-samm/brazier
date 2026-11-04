-module(brazier_await_ffi).
-export([barrier/2, watch_info/2, watch_exit/2, watch_down/2, next_info/2,
         unwatch/1, watch_pg_scope/1, next_pg_leave/3, unwatch_pg_scope/1,
         start_pg_scope/1, stop_pg_scope/1, pg_scope_watched/1]).

%% A pg scope of its own for a test of the watch helpers, unlinked so the
%% test stops it explicitly. Scope names a new atom chosen by the test.
start_pg_scope(ScopeName) ->
    {ok, Pid} = pg:start(binary_to_atom(ScopeName)),
    Pid.

stop_pg_scope(ScopeName) ->
    ok = gen_server:stop(binary_to_existing_atom(ScopeName)),
    nil.

%% Whether the watch's scope monitor is still in place. pg:demonitor/2
%% removes it if it is (ok) and reports false if not, so the watch must not
%% be used afterwards.
pg_scope_watched({Scope, Ref}) ->
    case pg:demonitor(Scope, Ref) of
        ok -> true;
        false -> false
    end.

%% A mailbox barrier on an OTP process (a gleam_otp actor, gen_server or any
%% sys-compliant process). sys:get_state/2 is answered in mailbox order, so
%% when it returns the process has handled every message sent to it before
%% the call. Anything it sent the caller while handling them is already in
%% the caller's mailbox: messages between one pair of processes keep their
%% order.
%%
%% Returns {error, Reason} instead of raising so the Gleam side can name the
%% process in its failure.
barrier(Pid, TimeoutMs) ->
    try sys:get_state(Pid, TimeoutMs) of
        _State -> {ok, nil}
    catch
        exit:{Reason, {sys, get_state, _}} -> {error, format(Reason)}
    end.

%% Tell the caller every time the sys-compliant process Pid receives the
%% plain (non-call, non-cast) message MessageAtom, e.g. a timer tick sent
%% with erlang:send_after. Uses the sys debug hook (sys:install/2), which
%% gen_server, gen_statem and supervisor run on every incoming message
%% before handling it. gleam_otp 1.3 actors discard sys debug requests, so
%% an install on one times out ({error, timeout}). The hook lives as long
%% as Pid, or until unwatch/1 removes it.
watch_info(Pid, MessageName) when is_binary(MessageName) ->
    Message = binary_to_existing_atom(MessageName),
    install_watch(Pid, fun(M) -> M =:= Message end).

%% Tell the caller when the sys-compliant process Pid (a supervisor, or any
%% process trapping exits) receives the exit signal of Child as a message.
watch_exit(Pid, Child) when is_pid(Child) ->
    install_watch(Pid, fun
        ({'EXIT', From, _Reason}) -> From =:= Child;
        (_) -> false
    end).

%% Tell the caller when the sys-compliant process Pid receives the DOWN of
%% a monitor it holds on Target (a presence shard on a tracked process).
watch_down(Pid, Target) when is_pid(Target) ->
    install_watch(Pid, fun
        ({'DOWN', _Ref, process, From, _Reason}) -> From =:= Target;
        (_) -> false
    end).

install_watch(Pid, Matches) ->
    Self = self(),
    Ref = make_ref(),
    Hook = fun(State, Event, _ProcState) ->
        case Event of
            {in, M} ->
                case Matches(M) of
                    true -> Self ! {brazier_await_info, Ref};
                    false -> ok
                end;
            _ ->
                ok
        end,
        State
    end,
    try sys:install(Pid, {Hook, ok}) of
        ok -> {ok, {Pid, Ref, Hook}}
    catch
        exit:{Reason, {sys, install, _}} -> {error, format(Reason)}
    end.

%% The next notice from watch_info/2: Pid has received the message. It may
%% still be handling it; follow with barrier/2 to know it is done.
next_info({_Pid, Ref, _Hook}, TimeoutMs) ->
    receive
        {brazier_await_info, Ref} -> {ok, nil}
    after TimeoutMs -> {error, nil}
    end.

%% Remove a watch's hook from its process and flush its notices. A hook
%% otherwise lives as long as the process, and the shared PubSub partitions
%% and presence shards outlive every test: a forgotten hook keeps sending
%% notices to the test process, which eunit reuses for the module's later
%% tests. The watched process must still be alive; sys:remove/2 exits if
%% it is not.
unwatch({Pid, Ref, Hook}) ->
    ok = sys:remove(Pid, Hook),
    flush_info(Ref).

flush_info(Ref) ->
    receive
        {brazier_await_info, Ref} -> flush_info(Ref)
    after 0 -> nil
    end.

%% Subscribe to membership changes in a pg scope (pg:monitor_scope/1).
%% pg removes a member when it exits; the notice is sent once pg has updated
%% its tables, so a membership read after it is final.
watch_pg_scope(ScopeName) when is_binary(ScopeName) ->
    Scope = binary_to_existing_atom(ScopeName),
    case whereis(Scope) of
        undefined -> {error, <<"pg scope ", ScopeName/binary, " is not running">>};
        _ ->
            {Ref, _Groups} = pg:monitor_scope(Scope),
            {ok, {Scope, Ref}}
    end.

%% Wait until Pid has left a group of the watched scope. Leave notices for
%% other processes are consumed and skipped.
next_pg_leave({_Scope, Ref}, Pid, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    next_pg_leave_loop(Ref, Pid, Deadline).

next_pg_leave_loop(Ref, Pid, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Ref, leave, _Group, Pids} ->
            case lists:member(Pid, Pids) of
                true -> {ok, nil};
                false -> next_pg_leave_loop(Ref, Pid, Deadline)
            end;
        {Ref, join, _Group, _Pids} ->
            next_pg_leave_loop(Ref, Pid, Deadline)
    after Remaining -> {error, nil}
    end.

unwatch_pg_scope({Scope, Ref}) ->
    ok = pg:demonitor(Scope, Ref),
    flush_pg_notices(Ref).

flush_pg_notices(Ref) ->
    receive
        {Ref, _Kind, _Group, _Pids} -> flush_pg_notices(Ref)
    after 0 -> nil
    end.

format(Term) ->
    iolist_to_binary(io_lib:format("~0p", [Term])).
