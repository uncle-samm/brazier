-module(beacon_cluster_test_ffi).

%% Helpers that multi-node tests run ON a peer node (through rpc). The test
%% runner is not distributed, so results come back as rpc return values.

-export([spawn_recorders/2, spawn_recorder/1, recorded/1, recorded_all/1,
         recorded_count/1, spawn_counters/2, counter_value/0, round_done_at/1, now_us/0, os_us/0,
         report/1, fail/1,
         worker_queue_len/1, suspend_worker/1, resume_worker/1,
         remote_worker_nodes/1, count_events/1, counted_events/0,
         registered/1, alive/1, kill/1, wait_down/2, record_event/4]).

-define(EVENTS, beacon_test_counted_events).

%% --- Recorders: subscribers that remember what they received ---

spawn_recorders(Topic, Count) ->
    [spawn_recorder([Topic]) || _ <- lists:seq(1, Count)].

%% A process subscribed to Topics that records every delivery. Unlinked:
%% it outlives the rpc call that started it.
spawn_recorder(Topics) ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        [{ok, nil} = beacon_pubsub_ffi:subscribe(T) || T <- Topics],
        Parent ! {Ref, ready},
        recorder_loop([])
    end),
    receive
        {Ref, ready} -> Pid
    after 5000 ->
        erlang:error({recorder_not_ready, Pid})
    end.

recorder_loop(Acc) ->
    receive
        {beacon_pubsub, _Topic, Message} ->
            recorder_loop([Message | Acc]);
        {recorded, From, Ref} ->
            From ! {Ref, lists:reverse(Acc)},
            recorder_loop(Acc)
    end.

%% Messages Pid recorded, oldest first.
recorded(Pid) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! {recorded, self(), Ref},
    receive
        {Ref, Messages} ->
            erlang:demonitor(Ref, [flush]),
            Messages;
        {'DOWN', Ref, process, Pid, Reason} ->
            erlang:error({recorder_down, Pid, Reason})
    after 5000 ->
        erlang:error({recorder_timeout, Pid})
    end.

recorded_all(Pids) ->
    [recorded(Pid) || Pid <- Pids].

recorded_count(Pid) ->
    length(recorded(Pid)).

%% --- Counters: cheap subscribers for fan-out benchmarks ---

-define(COUNTER, beacon_test_delivery_counter).

%% Count subscribers to Topic that each bump one shared lock-free atomic
%% per delivery (ETS update_counter on one key serialises them and would
%% dominate the measurement). Whenever the total reaches a multiple of
%% Count (one complete fan-out round), the subscriber that completed it
%% stores the OS time under {done, Round}. Peers share the host clock, so
%% these times compare across nodes. The table is owned by a long-lived
%% process; the atomic lives in persistent_term (written once per node).
spawn_counters(Topic, Count) ->
    Parent = self(),
    Ref = make_ref(),
    spawn(fun() ->
        ?COUNTER = ets:new(?COUNTER, [set, public, named_table]),
        Parent ! {Ref, ready},
        receive stop -> ok end
    end),
    receive {Ref, ready} -> ok after 5000 -> erlang:error(counter_table_not_ready) end,
    ok = persistent_term:put(?COUNTER, atomics:new(1, [{signed, false}])),
    Pids = [spawn_counter(Topic, Count) || _ <- lists:seq(1, Count)],
    length(Pids).

spawn_counter(Topic, Target) ->
    Parent = self(),
    Ref = make_ref(),
    Atomic = persistent_term:get(?COUNTER),
    Pid = spawn(fun() ->
        {ok, nil} = beacon_pubsub_ffi:subscribe(Topic),
        Parent ! {Ref, ready},
        counter_loop(Atomic, Target)
    end),
    receive
        {Ref, ready} -> Pid
    after 5000 ->
        erlang:error({counter_not_ready, Pid})
    end.

counter_loop(Atomic, Target) ->
    receive
        {beacon_pubsub, _Topic, _Message} ->
            N = atomics:add_get(Atomic, 1, 1),
            case N rem Target of
                0 -> true = ets:insert(?COUNTER, {{done, N div Target}, os_us()});
                _ -> true
            end,
            counter_loop(Atomic, Target)
    end.

counter_value() ->
    atomics:get(persistent_term:get(?COUNTER), 1).

%% When fan-out round Round completed on this node: {ok, OsMicros} or
%% {error, nil} if it has not yet.
round_done_at(Round) ->
    case ets:lookup(?COUNTER, {done, Round}) of
        [{_, At}] -> {ok, At};
        [] -> {error, nil}
    end.

%% --- Forwarding workers ---

worker(Shard) ->
    Name = list_to_atom("beacon_pubsub_worker_" ++ integer_to_list(Shard)),
    case whereis(Name) of
        undefined -> erlang:error({no_worker, Shard});
        Pid -> Pid
    end.

worker_queue_len(Shard) ->
    {message_queue_len, Len} = erlang:process_info(worker(Shard), message_queue_len),
    Len.

suspend_worker(Shard) ->
    ok = sys:suspend(worker(Shard)),
    nil.

resume_worker(Shard) ->
    ok = sys:resume(worker(Shard)),
    nil.

%% Nodes whose shard-Shard worker this node's pg scope currently lists.
remote_worker_nodes(Shard) ->
    lists:usort([node(P) || P <- pg:get_members(beacon_pubsub_pg, {beacon_pubsub, Shard}),
                            node(P) =/= node()]).

%% --- Telemetry counting on a peer ---

%% Record every EventName (a list of binaries) emitted on this node, with
%% its measurements, in a public table owned by a long-lived process.
count_events(EventName) ->
    Parent = self(),
    Ref = make_ref(),
    spawn(fun() ->
        ?EVENTS = ets:new(?EVENTS, [ordered_set, public, named_table]),
        Parent ! {Ref, ready},
        receive stop -> ok end
    end),
    receive {Ref, ready} -> ok after 5000 -> erlang:error(counter_not_ready) end,
    Atoms = [binary_to_atom(S, utf8) || S <- EventName],
    ok = telemetry:attach(<<"beacon-test-event-counter">>, Atoms,
                          fun ?MODULE:record_event/4, nil),
    nil.

%% The queue_len measurement of each counted event, oldest first.
counted_events() ->
    [maps:get(queue_len, M, -1) || {_, M} <- ets:tab2list(?EVENTS)].

record_event(_Name, Measurements, _Metadata, nil) ->
    true = ets:insert(?EVENTS, {erlang:unique_integer([monotonic]), Measurements}),
    ok.

%% --- Processes ---

registered(Name) ->
    case whereis(binary_to_atom(Name, utf8)) of
        undefined -> {error, nil};
        Pid -> {ok, Pid}
    end.

alive(Pid) -> is_process_alive(Pid).

kill(Pid) ->
    true = exit(Pid, kill),
    nil.

%% Wait until Pid is dead. True if it died within TimeoutMs.
wait_down(Pid, TimeoutMs) ->
    Ref = erlang:monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, _} -> true
    after TimeoutMs ->
        erlang:demonitor(Ref, [flush]),
        false
    end.

%% --- Benchmarks ---

now_us() -> erlang:monotonic_time(microsecond).

os_us() -> os:system_time(microsecond).

%% eunit captures standard output; benchmark lines go to the user console.
report(Line) ->
    ok = io:format(user, "~ts~n", [Line]),
    nil.

%% Raise an error with Reason (a harness test needs a body that fails at
%% run time, where the compiler cannot see it coming).
fail(Reason) ->
    erlang:error({deliberate_failure, Reason}).
