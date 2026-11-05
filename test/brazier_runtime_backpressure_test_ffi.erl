-module(brazier_runtime_backpressure_test_ffi).
%% Wait for a runtime to receive the DOWN of a connection owner it
%% monitors. A gleam_otp actor runs no sys debug hook (see
%% brazier_await_ffi:watch_down/2), so the runtime's 'receive' events are
%% traced instead, in a trace session of the test's own (OTP 27 `trace`
%% module), which no other tracer on the node shares.
%%
%% A DOWN is sent by the exiting process, so a test that only waits for its
%% own monitor to fire knows nothing about when the runtime's DOWN arrives:
%% signals from different senders are not ordered. The trace message is
%% sent by the runtime itself when the DOWN enters its mailbox, so a barrier
%% on the runtime after it proves the DOWN was handled.
-export([trace_receive/1, await_down_received/3, stop_trace/2,
         monitored_pids/1]).

%% The pids of the processes Pid monitors (by pid; it monitors no name).
monitored_pids(Pid) ->
    {monitors, Monitors} = erlang:process_info(Pid, monitors),
    [Target || {process, Target} <- Monitors, is_pid(Target)].

trace_receive(Pid) ->
    Name = list_to_atom("brazier_backpressure_" ++ integer_to_list(erlang:unique_integer([positive]))),
    Session = trace:session_create(Name, self(), []),
    1 = trace:process(Session, Pid, true, ['receive']),
    Session.

%% {ok, nil} once Pid has received the DOWN of a monitor on Target;
%% {error, nil} if it has not within Timeout ms. Other trace messages stay
%% in the mailbox until stop_trace/2.
await_down_received(Pid, Target, Timeout) ->
    receive
        {trace, Pid, 'receive', {'DOWN', _Ref, process, Target, _Reason}} -> {ok, nil}
    after Timeout ->
        {error, nil}
    end.

%% Destroy the session and drop the trace messages it left in the mailbox.
stop_trace(Session, Pid) ->
    true = trace:session_destroy(Session),
    flush(Pid).

flush(Pid) ->
    receive
        {trace, Pid, _, _} -> flush(Pid)
    after 0 ->
        nil
    end.
