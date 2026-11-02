-module(beacon_cluster_test_ffi).

%% Helpers that multi-node tests run ON a peer node (through rpc). The test
%% runner is not distributed, so results come back as rpc return values.

-export([spawn_recorders/2, spawn_recorder/1, recorded/1, recorded_all/1,
         recorded_count/1, spawn_counters/2, counter_value/0, round_done_at/1, now_us/0, os_us/0,
         report/1, fail/1,
         worker_queue_len/1, suspend_worker/1, resume_worker/1,
         remote_worker_nodes/1, count_events/1, counted_events/0,
         registered/1, alive/1, kill/1, wait_down/2, record_event/4,
         record_events/1, recorded_events/0, record_named_event/4, putenv/2,
         dist_protocol/1, dist_optfile/1]).

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

%% --- Telemetry recording with metadata ---

-define(NAMED, beacon_test_named_events).

%% Record every event in EventNames (each a list of binaries) emitted on
%% this node: its dotted name and its node and reason metadata.
record_events(EventNames) ->
    Parent = self(),
    Ref = make_ref(),
    spawn(fun() ->
        ?NAMED = ets:new(?NAMED, [ordered_set, public, named_table]),
        Parent ! {Ref, ready},
        receive stop -> ok end
    end),
    receive {Ref, ready} -> ok after 5000 -> erlang:error(recorder_table_not_ready) end,
    Names = [[binary_to_atom(S, utf8) || S <- Name] || Name <- EventNames],
    ok = telemetry:attach_many(<<"beacon-test-named-events">>, Names,
                               fun ?MODULE:record_named_event/4, nil),
    nil.

record_named_event(Name, _Measurements, Metadata, nil) ->
    Dotted = iolist_to_binary(lists:join(<<".">>, [atom_to_binary(A) || A <- Name])),
    true = ets:insert(?NAMED, {erlang:unique_integer([monotonic]), Dotted,
                               maps:get(node, Metadata, <<>>),
                               maps:get(reason, Metadata, <<>>)}),
    ok.

%% Recorded events, oldest first, as {event, Name, Node, Reason}.
recorded_events() ->
    [{event, Name, Node, Reason} || {_, Name, Node, Reason} <- ets:tab2list(?NAMED)].

putenv(Name, Value) ->
    true = os:putenv(unicode:characters_to_list(Name), unicode:characters_to_list(Value)),
    nil.

%% The distribution carrier of the connection to Node (tcp, tls, ...), or
%% {error, nil} when not connected.
dist_protocol(Node) ->
    case net_kernel:node_info(Node) of
        {ok, Info} ->
            case proplists:get_value(address, Info) of
                {net_address, _, _, Protocol, _} -> {ok, atom_to_binary(Protocol)};
                Other -> erlang:error({unexpected_node_address, Other})
            end;
        {error, _} ->
            {error, nil}
    end.

%% --- TLS distribution ---

-define(FIXTURES, "test/fixtures/dist_tls").
-define(OPTFILE_DIR, "build/test/dist_tls").

%% Write an -ssl_dist_optfile for a test node and return its absolute path.
%% Cert is the fixture name of the node's certificate ("node", "rogue") or
%% "none" for a node without one. Every node trusts only the cluster CA and
%% requires a peer certificate. Server name checking is off: the fixtures
%% cannot name the host that runs the tests (production keeps it on).
dist_optfile(Cert) ->
    Fixture = fun(F) -> filename:absname(filename:join(?FIXTURES, F)) end,
    Own = case Cert of
              <<"none">> -> [];
              Name -> [{certfile, Fixture(binary_to_list(Name) ++ ".pem")},
                       {keyfile, Fixture(binary_to_list(Name) ++ ".key")}]
          end,
    Trust = [{cacertfile, Fixture("ca.pem")}, {verify, verify_peer}],
    Terms = [{server, Own ++ Trust ++ [{fail_if_no_peer_cert, true}]},
             {client, Own ++ Trust ++ [{server_name_indication, disable}]}],
    Path = filename:absname(filename:join(?OPTFILE_DIR, binary_to_list(Cert) ++ ".conf")),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, io_lib:format("~p.~n", [Terms])),
    unicode:characters_to_binary(Path).

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
