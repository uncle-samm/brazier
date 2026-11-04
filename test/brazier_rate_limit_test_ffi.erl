-module(brazier_rate_limit_test_ffi).
%% Test helpers that put a limiter's owner in a known state without sleeps.
-export([suspend/1, resume/1, trace_receives/1, await_call_received/2]).

%% sys:suspend/1: the owner stops handling messages (calls queue up).
suspend(Pid) ->
    ok = sys:suspend(Pid),
    nil.

resume(Pid) ->
    ok = sys:resume(Pid),
    nil.

%% Have the calling process told of every message Pid receives.
trace_receives(Pid) ->
    1 = erlang:trace(Pid, true, ['receive', {tracer, self()}]),
    nil.

%% Wait until Pid has a gen_server call in its mailbox. gen_server:call
%% monitors the server before it sends, so from then on the caller sees the
%% server's exit reason, not noproc. {ok, nil} | {error, nil} on timeout.
await_call_received(Pid, TimeoutMs) ->
    receive
        {trace, Pid, 'receive', {'$gen_call', _From, _Request}} ->
            erlang:trace(Pid, false, ['receive']),
            {ok, nil}
    after TimeoutMs ->
        {error, nil}
    end.
