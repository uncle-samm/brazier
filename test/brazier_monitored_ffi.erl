-module(brazier_monitored_ffi).

%% Test processes whose monitor cannot race their exit, and test bodies run
%% in a process of their own (see test/brazier/monitored.gleam).

-export([isolated/1, with_cleanup/2, format_term/1]).

%% Run Fun, then Cleanup, whether Fun returned or raised (ExUnit's
%% on_exit/1). Fun's exception is re-raised unchanged after Cleanup.
with_cleanup(Cleanup, Fun) ->
    try Fun()
    after Cleanup()
    end.

%% A term as Erlang prints it (~0p), for asserting on exit reasons.
format_term(Term) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Term])).

%% Run Fun in a new process and return its result once that process has
%% exited, so everything it held dies with it: its PubSub and presence
%% subscriptions, its links, its mailbox and the telemetry handlers that
%% filter on its pid. eunit runs every test of a module in one process, so
%% state a failing test leaves in that process reaches the tests after it;
%% ExUnit runs each test in a process of its own for the same reason.
%%
%% The process is spawned with its monitor (spawn_monitor/1), so its DOWN
%% carries the real reason. A crash in Fun fails the caller with that
%% reason. A watchdog kills the process if the caller dies first (eunit's
%% timeout), so a stuck body never outlives its test.
isolated(Fun) ->
    Parent = self(),
    Tag = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() -> Parent ! {Tag, Fun()} end),
    Watchdog = spawn(fun() -> watchdog(Parent, Pid, Tag) end),
    Result = receive
        {Tag, Value} ->
            %% The body returned; its process exits normally next.
            receive
                {'DOWN', Monitor, process, Pid, normal} -> {ok, Value};
                {'DOWN', Monitor, process, Pid, Reason} -> {error, {after_return, Reason}}
            end;
        {'DOWN', Monitor, process, Pid, Reason} ->
            {error, Reason}
    end,
    Watchdog ! {Tag, done},
    case Result of
        {ok, Returned} -> Returned;
        {error, Failure} -> erlang:error({isolated_test_failed, Failure})
    end.

watchdog(Parent, Pid, Tag) ->
    ParentMonitor = erlang:monitor(process, Parent),
    receive
        {'DOWN', ParentMonitor, process, Parent, _} -> exit(Pid, kill);
        {Tag, done} -> ok
    end.
