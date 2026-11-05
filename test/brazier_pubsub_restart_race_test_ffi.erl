-module(brazier_pubsub_restart_race_test_ffi).

%% Helpers for pubsub_restart_race_test: hold a subscriber at each point of
%% brazier_pubsub_ffi:subscribe/1 in turn while its partition is killed.
%%
%% The node runs one scheduler (multi-scheduling blocked), so a process runs
%% until it blocks or uses up its reductions. The subscriber starts a fresh
%% time slice (erlang:yield/0), wakes the test, and spends all but Budget of
%% its reductions (erlang:bump_reductions/1): it is scheduled out at the
%% first call inside subscribe/1 after Budget reductions, and the test,
%% queued ahead of it, runs before it does again. The test suspends it
%% there and kills its partition. Then, by mode:
%%   - up: the test waits for the supervisor to restart the partition and
%%     resumes the subscriber, which meets the restarted partition's tables
%%     under the old partition's table names;
%%   - down: the supervisor is suspended (sys:suspend/1) before the kill, and
%%     the subscriber is resumed and runs to its end while the partition is
%%     dead and its name and tables are gone; the restart follows.
%% A down hold runs with a subscriber that traps exits and with one that
%% does not: link/1 to a dead process fails only in the second. Budgets
%% 1, 2, ... hold it at every call in subscribe/1 in turn, up to the first
%% that lets it return before the kill. Each hold gets its own PubSub, with
%% one partition: one kill each stays within the restart intensity.
%%
%% Where a hold fell is read while the subscriber is held: how many of its
%% erlang:whereis/1 calls had returned the partition about to be killed
%% (the lookup, the check after the link, the check after the inserts),
%% which of its rows that partition's tables hold, and whether subscribe/1
%% had returned. The calls are traced (erlang:trace_delivered/1 makes the
%% trace messages sent before the hold arrive first). ets:insert/2 is not
%% traced: a call trace pattern on it takes away the scheduling point
%% before it, which is where the narrowest hold falls.
%%
%% Only for a fresh peer node: it blocks multi-scheduling and sets global
%% call trace patterns while it runs.

-export([sweep/2]).

-define(CONTEXT_REDS, 4000).
-define(MAX_BUDGET, 2000).
-define(TIMEOUT_MS, 5000).
-define(CONFIG_KEY, {brazier_pubsub, config}).
-define(PARTITION_SUP, brazier_pubsub_partition_sup).
-define(MODES, [{up, trapping}, {down, trapping}, {down, not_trapping}]).

%% Hold a subscriber to Topic at every point of subscribe/1 in turn, in
%% every mode, under PubSub started with Config (one partition). Returns
%% {Violations, Seen}: each hold whose subscriber was left in a state other
%% than
%%   - subscribed: Ok, its rows in the restarted partition's tables, and
%%     linked to that partition;
%%   - lost with the killed partition: Ok, no rows, not linked to the
%%     restarted partition;
%%   - refused: NotStarted, no rows, not linked to the restarted partition;
%%   - killed with the partition: a subscriber that does not trap exits,
%%     linked to the partition when it was killed;
%% or that holds the exit of a link to the dead partition made after it
%% died, or whose hold fell nowhere position/1 names; and the sorted
%% "mode: where the hold fell: state" of every other hold.
sweep(Config, Topic) ->
    {module, brazier_pubsub_ffi} = code:ensure_loaded(brazier_pubsub_ffi),
    Blocked = erlang:system_flag(multi_scheduling, block),
    true = lists:member(Blocked, [blocked, disabled]),
    Returns = [{'_', [], [{return_trace}]}],
    1 = erlang:trace_pattern({erlang, whereis, 1}, Returns, [local]),
    1 = erlang:trace_pattern({brazier_pubsub_ffi, subscribe, 1}, Returns, [local]),
    try
        Holds = lists:append([holds(Config, Topic, Mode, 1, []) || Mode <- ?MODES]),
        Named = [Hold#{position => position(AtHold)} || Hold = #{at_hold := AtHold} <- Holds],
        Violations = [format(Hold) || Hold = #{state := State, position := Position} <- Named,
                                      State =:= violation orelse Position =:= unclassified],
        Seen = lists:usort([seen(Mode, Position, State, Final)
                            || #{mode := Mode, position := Position, state := State,
                                 final := Final} <- Named,
                               State =/= violation, Position =/= unclassified]),
        {Violations, Seen}
    after
        1 = erlang:trace_pattern({brazier_pubsub_ffi, subscribe, 1}, false, [local]),
        1 = erlang:trace_pattern({erlang, whereis, 1}, false, [local]),
        Unblocked = erlang:system_flag(multi_scheduling, unblock),
        true = lists:member(Unblocked, [enabled, disabled])
    end.

%% Budgets from 1 up to the first whose subscribe/1 returned before the hold.
holds(Config, Topic, Mode, Budget, Acc) ->
    Hold = hold(Config, Topic, Mode, Budget),
    case Hold of
        #{at_hold := #{returned := true}} ->
            lists:reverse([Hold | Acc]);
        _ when Budget >= ?MAX_BUDGET ->
            erlang:error({brazier_race_subscribe_never_returned_before_the_hold, Mode, Budget});
        _ ->
            holds(Config, Topic, Mode, Budget + 1, [Hold | Acc])
    end.

hold(Config, Topic, Mode = {Phase, Trapping}, Budget) ->
    {ok, nil} = brazier_pubsub_ffi:start(Config),
    #{partitions := 1, partition_names := {Name}, keys := {Keys}, pids := {Pids}} =
        persistent_term:get(?CONFIG_KEY),
    Old = whereis(Name),
    true = is_pid(Old),
    Sup = whereis(?PARTITION_SUP),
    true = is_pid(Sup),
    Test = self(),
    Trap = Trapping =:= trapping,
    {Subscriber, Ref} =
        spawn_monitor(fun() -> subscriber(Test, Topic, Name, Keys, Pids, Old, Budget, Trap) end),
    1 = erlang:trace(Subscriber, true, [call, {tracer, Test}]),
    Subscriber ! brazier_race_go,
    receive
        {brazier_race_holding, Subscriber} -> ok
    after ?TIMEOUT_MS ->
        erlang:error({brazier_race_subscriber_never_started, Mode, Budget})
    end,
    %% The subscriber is scheduled out (inside subscribe/1, or blocked once
    %% it returned): this process was queued ahead of it.
    true = erlang:suspend_process(Subscriber),
    Traced = traced(Subscriber, Old),
    {links, Links} = process_info(Subscriber, links),
    AtHold = Traced#{rows_in_old => rows(Subscriber, Topic, Keys, Pids),
                     linked_to_old => lists:member(Old, Links)},
    {New, Outcome} =
        case Phase of
            up ->
                {Restarted, ok} = restart(Sup, Name, Old, fun() -> ok end),
                true = erlang:resume_process(Subscriber),
                {Restarted, returned(Subscriber, Ref, Mode, Budget)};
            down ->
                Down = fun() ->
                           run_while_down(Subscriber, Ref, Mode, Budget, AtHold, Name, Keys, Pids)
                       end,
                restart(Sup, Name, Old, Down)
        end,
    Final = check(Subscriber, Ref, Mode, Budget, Outcome),
    %% Tracing ends with the subscriber; what it traced after the hold is
    %% not needed, but it must not be left in this process's mailbox.
    _AfterHold = traced(Subscriber, Old),
    {ok, nil} = brazier_pubsub_ffi:stop(),
    #{mode => Mode, budget => Budget, outcome => Outcome, final => Final, at_hold => AtHold,
      old => Old, new => New, state => state(Subscriber, Topic, Outcome, Final)}.

%% With the partition dead and not restarted (its supervisor suspended):
%% resume the subscriber and wait for subscribe/1 to return, or for the
%% subscriber to exit. One that does not trap exits and was linked to the
%% partition when it was held dies with it, suspended.
run_while_down(Subscriber, Ref, Mode, Budget, AtHold, Name, Keys, Pids) ->
    %% The partition's name and tables went before its DOWN was sent.
    undefined = whereis(Name),
    undefined = ets:whereis(Keys),
    undefined = ets:whereis(Pids),
    case {Mode, AtHold} of
        {{down, not_trapping}, #{linked_to_old := true}} ->
            receive
                {'DOWN', Ref, process, Subscriber, Reason} -> {exited, Reason}
            after ?TIMEOUT_MS ->
                erlang:error({brazier_race_linked_subscriber_survived, Mode, Budget})
            end;
        _ ->
            true = erlang:resume_process(Subscriber),
            returned(Subscriber, Ref, Mode, Budget)
    end.

returned(Subscriber, Ref, Mode, Budget) ->
    receive
        {brazier_race_returned, Subscriber, Result} -> {returned, Result};
        {'DOWN', Ref, process, Subscriber, Reason} -> {exited, Reason}
    after ?TIMEOUT_MS ->
        erlang:error({brazier_race_subscriber_never_returned, Mode, Budget})
    end.

%% What a subscriber that returned holds once the partition has restarted.
check(Subscriber, Ref, Mode, Budget, {returned, _Result}) ->
    Subscriber ! brazier_race_check,
    Holding =
        receive
            {brazier_race_checked, Subscriber, H} -> H
        after ?TIMEOUT_MS ->
            erlang:error({brazier_race_subscriber_never_checked, Mode, Budget})
        end,
    Subscriber ! brazier_race_done,
    receive
        {'DOWN', Ref, process, Subscriber, normal} -> ok;
        {'DOWN', Ref, process, Subscriber, Reason} ->
            erlang:error({brazier_race_subscriber_crashed, Mode, Budget, Reason})
    after ?TIMEOUT_MS ->
        erlang:error({brazier_race_subscriber_never_exited, Mode, Budget})
    end,
    Holding;
check(_Subscriber, _Ref, _Mode, _Budget, {exited, _Reason}) ->
    exited.

subscriber(Test, Topic, Name, Keys, Pids, Old, Budget, Trap) ->
    receive brazier_race_go -> ok end,
    %% A subscriber that traps exits survives the partition's death.
    false = process_flag(trap_exit, Trap),
    erlang:yield(),
    Test ! {brazier_race_holding, self()},
    true = erlang:bump_reductions(?CONTEXT_REDS - Budget),
    Result = brazier_pubsub_ffi:subscribe(Topic),
    Test ! {brazier_race_returned, self(), Result},
    receive brazier_race_check -> ok end,
    New = whereis(Name),
    {links, Links} = process_info(self(), links),
    {messages, Messages} = process_info(self(), messages),
    Holding = #{rows => rows(self(), Topic, Keys, Pids),
                linked_to_new => lists:member(New, Links),
                exits_from_old => [Reason || {'EXIT', From, Reason} <- Messages, From =:= Old]},
    Test ! {brazier_race_checked, self(), Holding},
    receive brazier_race_done -> ok end.

%% Subscriber's rows for Topic in the partition tables now named Keys and
%% Pids.
rows(Subscriber, Topic, Keys, Pids) ->
    {ets:lookup(Pids, Subscriber), ets:match_object(Keys, {Topic, Subscriber})}.

%% Kill partition Old and return {its replacement, what WhileDown returned}
%% once the partition supervisor has handled Old's exit (one_for_one
%% restarts it in there). WhileDown runs after Old's DOWN, with the
%% supervisor suspended, so before the restart.
restart(Sup, Name, Old, WhileDown) ->
    {ok, Watch} = brazier_await_ffi:watch_exit(Sup, Old),
    try
        ok = sys:suspend(Sup),
        MRef = monitor(process, Old),
        true = exit(Old, kill),
        receive
            {'DOWN', MRef, process, Old, killed} -> ok
        after ?TIMEOUT_MS ->
            erlang:error({brazier_race_partition_never_died, Name, Old})
        end,
        Result = WhileDown(),
        ok = sys:resume(Sup),
        case brazier_await_ffi:next_info(Watch, ?TIMEOUT_MS) of
            {ok, nil} -> ok;
            {error, nil} -> erlang:error({brazier_race_partition_exit_not_handled, Name, Old})
        end,
        {ok, nil} = brazier_await_ffi:barrier(Sup, ?TIMEOUT_MS),
        case whereis(Name) of
            New when is_pid(New), New =/= Old -> {New, Result};
            Other -> erlang:error({brazier_race_partition_not_restarted, Name, Old, Other})
        end
    after
        nil = brazier_await_ffi:unwatch(Watch)
    end.

%% What Subscriber has traced so far: how many of its whereis/1 calls
%% returned Old, and whether subscribe/1 returned. Every trace message it
%% sent before this call has arrived once trace_delivered answers.
traced(Subscriber, Old) ->
    TraceRef = erlang:trace_delivered(Subscriber),
    receive
        {trace_delivered, Subscriber, TraceRef} -> ok
    after ?TIMEOUT_MS ->
        erlang:error({brazier_race_trace_not_delivered, Subscriber})
    end,
    traced(Subscriber, Old, #{found_old => 0, returned => false}).

traced(Subscriber, Old, Acc = #{found_old := Found}) ->
    receive
        {trace, Subscriber, return_from, {erlang, whereis, 1}, Old} ->
            traced(Subscriber, Old, Acc#{found_old := Found + 1});
        {trace, Subscriber, return_from, {erlang, whereis, 1}, _Other} ->
            traced(Subscriber, Old, Acc);
        {trace, Subscriber, call, {erlang, whereis, [_Name]}} ->
            traced(Subscriber, Old, Acc);
        {trace, Subscriber, call, {brazier_pubsub_ffi, subscribe, [_Topic]}} ->
            traced(Subscriber, Old, Acc);
        {trace, Subscriber, return_from, {brazier_pubsub_ffi, subscribe, 1}, _Result} ->
            traced(Subscriber, Old, Acc#{returned := true})
    after 0 ->
        Acc
    end.

%% A subscriber that trapped exits may hold the exit of a link it made
%% before the partition died (killed), never that of one it made after
%% (noproc): subscribe/1 removes a link it made when it does not subscribe.
state(Self, Topic, {returned, {ok, nil}},
      #{rows := {[{Self, Topic}], [{Topic, Self}]}, linked_to_new := true, exits_from_old := Exits})
  when Exits =:= [] orelse Exits =:= [killed] ->
    subscribed;
state(_Self, _Topic, {returned, {ok, nil}},
      #{rows := {[], []}, linked_to_new := false, exits_from_old := Exits})
  when Exits =:= [] orelse Exits =:= [killed] ->
    lost_with_the_killed_partition;
state(_Self, _Topic, {returned, {error, not_started}},
      #{rows := {[], []}, linked_to_new := false, exits_from_old := Exits})
  when Exits =:= [] orelse Exits =:= [killed] ->
    refused;
state(_Self, _Topic, {exited, killed}, exited) ->
    killed_with_the_partition;
state(_Self, _Topic, _Outcome, _Final) ->
    violation.

%% Where a hold fell, from what the subscriber had done when it was held.
%% None falls after the inserts and before the check that follows them: a
%% traced call (that check's whereis/1) has no scheduling point before it.
position(#{returned := true, linked_to_old := true}) ->
    returned_before_the_kill;
position(#{found_old := 3, returned := false, rows_in_old := {[_], [_]}, linked_to_old := true}) ->
    held_after_the_recheck;
position(#{found_old := 0, returned := false, rows_in_old := {[], []}, linked_to_old := false}) ->
    held_before_the_lookup;
position(#{found_old := 1, returned := false, rows_in_old := {[], []}, linked_to_old := false}) ->
    held_before_the_link;
position(#{found_old := 1, returned := false, rows_in_old := {[], []}, linked_to_old := true}) ->
    held_after_the_link_before_the_check;
position(#{found_old := 2, returned := false, rows_in_old := {[], []}, linked_to_old := true}) ->
    held_after_the_check_before_the_inserts;
position(#{found_old := 2, returned := false, rows_in_old := {[_], []}, linked_to_old := true}) ->
    held_between_the_inserts;
position(_AtHold) ->
    unclassified.

seen({Phase, Trapping}, Position, State, Final) ->
    Exit = case Final of
               #{exits_from_old := [killed]} -> <<", holding the partition's exit">>;
               _ -> <<>>
           end,
    format_text("~ts, ~ts: ~ts: ~ts~ts", [Phase, Trapping, Position, State, Exit]).

format(Term) ->
    format_text("~0p", [Term]).

format_text(Format, Args) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).
