-module(brazier_cluster_test_ffi).

%% Helpers that multi-node tests run ON a peer node (through rpc). The test
%% runner is not distributed, so results come back as rpc return values.

-export([spawn_recorders/2, spawn_recorder/1, recorded/1, recorded_all/1,
         recorded_count/1, spawn_counters/2, counter_value/0, round_done_at/1, now_us/0, os_us/0,
         report/1, fail/1,
         worker_queue_len/1, suspend_worker/1, resume_worker/1,
         remote_worker_nodes/1, count_events/1, counted_events/0,
         registered/1, alive/1, kill/1, wait_down/2, record_event/4,
         record_events/1, recorded_events/0, record_named_event/4, putenv/2,
         dist_protocol/1, dist_optfile/1, no_argument/0, option_groups/1,
         write_optfile/1, atom_exists/1, state_holds/1, status_holds/1,
         send_marked_hellos/1, manager_suspend/0, manager_resume/0, manager_barrier/0,
         pending_check/1, nodeup_queued/1, send_check_timeout/2, reconnect/1,
         peer_status/1, send_hello/2, watch_nodes/0, node_events/1,
         node_events_after_down/1, disconnect/1, sync_global/0,
         spawn_verified_waiter/1, waiter_result/2,
         forge_forward/3, deliver_forged/2, store_message_from/1,
         presence_message_from/1, partition_churn/3]).

-define(EVENTS, brazier_test_counted_events).

%% --- Recorders: subscribers that remember what they received ---

spawn_recorders(Topic, Count) ->
    [spawn_recorder([Topic]) || _ <- lists:seq(1, Count)].

%% A process subscribed to Topics that records every delivery. Unlinked:
%% it outlives the rpc call that started it.
spawn_recorder(Topics) ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        [{ok, nil} = brazier_pubsub_ffi:subscribe(T) || T <- Topics],
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
        {brazier_pubsub, _Topic, Message} ->
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

-define(COUNTER, brazier_test_delivery_counter).

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
        {ok, nil} = brazier_pubsub_ffi:subscribe(Topic),
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
        {brazier_pubsub, _Topic, _Message} ->
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
    Name = list_to_atom("brazier_pubsub_worker_" ++ integer_to_list(Shard)),
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
    lists:usort([node(P) || P <- pg:get_members(brazier_pubsub_pg, {brazier_pubsub, Shard}),
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
    ok = telemetry:attach(<<"brazier-test-event-counter">>, Atoms,
                          fun ?MODULE:record_event/4, nil),
    nil.

%% The queue_len measurement of each counted event, oldest first.
counted_events() ->
    [maps:get(queue_len, M, -1) || {_, M} <- ets:tab2list(?EVENTS)].

record_event(_Name, Measurements, _Metadata, nil) ->
    true = ets:insert(?EVENTS, {erlang:unique_integer([monotonic]), Measurements}),
    ok.

%% --- Telemetry recording with metadata ---

-define(NAMED, brazier_test_named_events).

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
    ok = telemetry:attach_many(<<"brazier-test-named-events">>, Names,
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

%% What init:get_argument/1 returns for a flag that was not given.
no_argument() -> error.

%% What init:get_argument/1 returns for a flag given once per group, each
%% with these values (as charlists, like the emulator's arguments).
option_groups(Groups) ->
    {ok, [[unicode:characters_to_list(V) || V <- Group] || Group <- Groups]}.

%% Write Contents to a fresh option file and return its absolute path.
write_optfile(Contents) ->
    Name = "opt_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".conf",
    Path = filename:absname(filename:join(?OPTFILE_DIR, Name)),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Contents),
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

%% --- Cluster manager probes (run on a peer) ---

-define(MANAGER, brazier_cluster).

%% Whether Name is an atom already, without making it one.
atom_exists(Name) ->
    try binary_to_existing_atom(Name) of
        _ -> true
    catch
        error:badarg -> false
    end.

%% Whether the manager's raw state holds Needle (a control for status_holds/1).
state_holds(Needle) ->
    holds(sys:get_state(?MANAGER), Needle).

%% Whether the manager's sys:get_status/1 (what gen_server also prints in a
%% crash report) holds Needle: as a term, inside a binary, or in its text.
status_holds(Needle) ->
    Status = sys:get_status(?MANAGER),
    Text = lists:flatten(io_lib:format("~w", [Status])),
    %% <<1,2,3>> printed, without the brackets, so it is found inside a
    %% longer binary too.
    Printed = lists:flatten(io_lib:format("~w", [Needle])),
    Bytes = lists:sublist(Printed, 3, length(Printed) - 4),
    holds(Status, Needle) orelse string:find(Text, Bytes) =/= nomatch.

holds(Needle, Needle) -> true;
holds(Term, Needle) when is_binary(Term) -> binary:match(Term, Needle) =/= nomatch;
holds(Term, Needle) when is_tuple(Term) -> holds(tuple_to_list(Term), Needle);
holds(Term, Needle) when is_map(Term) -> holds(maps:to_list(Term), Needle);
holds([Head | Tail], Needle) -> holds(Head, Needle) orelse holds(Tail, Needle);
holds(_Term, _Needle) -> false.

%% Send the manager hellos and acks that carry Marker where a MAC goes but
%% must be dropped: three malformed ones and a well-formed hello from a
%% node that is not connected. Returns once the manager has handled them.
send_marked_hellos(Marker) ->
    ?MANAGER ! {brazier_cluster_hello, node(), Marker},
    ?MANAGER ! {brazier_cluster_hello, node(), 1, Marker, extra},
    ?MANAGER ! {brazier_cluster_hello_ack, node(), 1, binary_to_list(Marker)},
    ?MANAGER ! {brazier_cluster_hello, 'brazier_nobody@nowhere', 1, Marker},
    manager_barrier().

manager_suspend() ->
    ok = sys:suspend(?MANAGER),
    nil.

manager_resume() ->
    ok = sys:resume(?MANAGER),
    nil.

%% Returns once the manager has handled every message sent to it before.
manager_barrier() ->
    _ = sys:get_state(?MANAGER),
    nil.

%% The timer of the pending peer check of Node, if it is pending.
pending_check(Node) ->
    case sys:get_state(?MANAGER) of
        #{peers := #{Node := {pending, TRef}}} -> {ok, TRef};
        _ -> {error, nil}
    end.

%% Whether a nodeup for Node waits in the manager's mailbox.
nodeup_queued(Node) ->
    {messages, Messages} = process_info(whereis(?MANAGER), messages),
    lists:any(fun({nodeup, N, _Info}) -> N =:= Node;
                 (_) -> false
              end, Messages).

%% The message erlang:start_timer/3 delivers when the check timer TRef fires.
send_check_timeout(TRef, Node) ->
    ?MANAGER ! {timeout, TRef, {peer_check, Node}},
    nil.

%% The manager's record of Node: "verified", "rejected", "pending" or
%% "none" (not connected, or not yet seen).
peer_status(Node) ->
    case sys:get_state(?MANAGER) of
        #{peers := #{Node := verified}} -> <<"verified">>;
        #{peers := #{Node := rejected}} -> <<"rejected">>;
        #{peers := #{Node := {pending, _}}} -> <<"pending">>;
        #{peers := _} -> <<"none">>
    end.

%% Send Node's manager a hello from this node carrying Mac, and return once
%% it has handled it: the hello and the sys call go from one process to
%% one process, so they arrive in order.
send_hello(Node, Mac) ->
    {?MANAGER, Node} ! {brazier_cluster_hello, node(), 1, Mac},
    _ = sys:get_state({?MANAGER, Node}),
    nil.

%% A process that records every nodeup and nodedown this node sees from
%% now on, in order. Returns once it is subscribed.
watch_nodes() ->
    Parent = self(),
    Ready = make_ref(),
    Pid = spawn(fun() ->
                        ok = net_kernel:monitor_nodes(true),
                        Parent ! Ready,
                        watch_loop([])
                end),
    receive Ready -> Pid
    after 5000 -> error({watch_nodes, not_subscribed})
    end.

watch_loop(Acc) ->
    receive
        {nodeup, Node} -> watch_loop([{<<"up">>, Node} | Acc]);
        {nodedown, Node} -> watch_loop([{<<"down">>, Node} | Acc]);
        {get, From, Ref} -> From ! {Ref, lists:reverse(Acc)}, watch_loop(Acc);
        {await_down, From, Ref} ->
            case lists:keymember(<<"down">>, 1, Acc) of
                true ->
                    From ! {Ref, lists:reverse(Acc)},
                    watch_loop(Acc);
                false ->
                    receive
                        {nodedown, Node} ->
                            Acc1 = [{<<"down">>, Node} | Acc],
                            From ! {Ref, lists:reverse(Acc1)},
                            watch_loop(Acc1)
                    after 10000 ->
                        From ! {Ref, lists:reverse(Acc)},
                        watch_loop(Acc)
                    end
            end
    end.

%% What a watch_nodes/0 process has seen so far, oldest first.
node_events(Pid) ->
    ask(Pid, get).

%% The same, once it has seen a nodedown (or after 10s without one).
node_events_after_down(Pid) ->
    ask(Pid, await_down).

%% Send Pid {Tag, From, Ref} and wait for its {Ref, Answer}.
ask(Pid, Tag) ->
    Ref = monitor(process, Pid),
    Pid ! {Tag, self(), Ref},
    receive
        {Ref, Answer} -> true = demonitor(Ref, [flush]), Answer;
        {'DOWN', Ref, process, Pid, Reason} -> error({helper_down, Tag, Reason})
    after 15000 -> error({helper_timeout, Tag})
    end.

%% A process that asks the manager to be told when Node is verified, and
%% keeps whether it was. Returns once the manager has handled the request.
spawn_verified_waiter(Node) ->
    Parent = self(),
    Ready = make_ref(),
    Pid = spawn(fun() ->
                        {ok, nil} = brazier_cluster_ffi:await_verified(Node),
                        _ = sys:get_state(?MANAGER),
                        Parent ! Ready,
                        waiter_loop(Node, 0)
                end),
    receive Ready -> Pid
    after 5000 -> error({spawn_verified_waiter, not_registered})
    end.

%% One notice at most is expected: a second is a failure the next
%% waiter_result/1 reports.
waiter_loop(Node, Told) ->
    receive
        {brazier_cluster_peer_verified, Node} ->
            waiter_loop(Node, Told + 1);
        {now, From, Ref} ->
            From ! {Ref, Told},
            waiter_loop(Node, Told);
        {await, From, Ref} when Told =:= 0 ->
            receive
                {brazier_cluster_peer_verified, Node} -> From ! {Ref, 1}, waiter_loop(Node, 1)
            after 10000 -> From ! {Ref, 0}, waiter_loop(Node, 0)
            end;
        {await, From, Ref} ->
            From ! {Ref, Told},
            waiter_loop(Node, Told)
    end.

%% How many verified notices a spawn_verified_waiter/1 process has had:
%% Await true waits (up to 10s) for the first one, false answers now.
waiter_result(Pid, Await) ->
    ask(Pid, case Await of true -> await; false -> now end).

%% Returns once global on this node has synced with every connected node.
sync_global() ->
    ok = global:sync(),
    nil.

%% Drop the connection to Node, as the cluster manager once did to a
%% rejected peer.
disconnect(Node) ->
    true = erlang:disconnect_node(Node),
    nil.

%% Drop the connection to Node and connect again.
reconnect(Node) ->
    true = erlang:disconnect_node(Node),
    true = net_kernel:connect_node(Node),
    nil.

%% --- Forged peer traffic (membership tests) ---

%% Run on a node that is not a verified member: send Node's shard-0 PubSub
%% worker a forward naming this node, as a peer's broadcast would, and
%% return once the worker has handled it (messages between two processes
%% arrive in order, so the reply to the get_state follows the forward).
forge_forward(Node, Topic, Message) ->
    Worker = {list_to_atom("brazier_pubsub_worker_0"), Node},
    Worker ! {forward_to_local, node(), Topic, Message},
    _ = sys:get_state(Worker),
    nil.

%% Deliver Forged to this node's subscribers of Topic as a PubSub forward
%% delivers it, and return how many there were once each has handled it.
deliver_forged(Topic, Forged) ->
    {ok, Subscribers} = brazier_pubsub_ffi:local_subscribers(Topic),
    [Pid ! {brazier_pubsub, Topic, Forged} || Pid <- Subscribers],
    [_ = sys:get_state(Pid) || Pid <- Subscribers],
    length(Subscribers).

%% A replicated-store peer message whose sender is From.
store_message_from(From) ->
    {brazier_store, sync_request, From}.

%% A presence peer message (pool size 1) whose sender is From.
presence_message_from(From) ->
    {brazier_presence, heartbeat, 1, {From, 1}}.

%% --- PubSub partition churn ---

%% Kill each PubSub partition in turn while processes whose subscriptions
%% live in it subscribe to and unsubscribe from Topic in a loop: PerRound
%% of them already subscribing when it is killed, and PerRound more started
%% right after, racing its restart. Returns {Unexpected, Rows}: how every
%% subscriber that ended other than normally or by its partition's exit
%% ended, and how many rows the partitions' tables still hold once every
%% subscriber has exited and each partition has handled those exits.
partition_churn(Topic, PerRound, Iterations) ->
    #{partitions := P, partition_names := Names, keys := Keys, pids := Pids} =
        persistent_term:get({brazier_pubsub, config}),
    Indexes = lists:seq(1, P),
    Churners = lists:append([churn_round(I, P, element(I, Names), Topic, PerRound, Iterations)
                             || I <- Indexes]),
    Reasons = [await_churner(Churner) || Churner <- Churners],
    [_ = sys:get_state(element(I, Names)) || I <- Indexes],
    Rows = lists:sum([ets:info(element(I, Table), size) || Table <- [Keys, Pids], I <- Indexes]),
    %% Every churner is monitored before it is told to go, so these are the
    %% churners' own exit reasons, never a late monitor's. `noproc` is one
    %% of them: link/1 to a partition that is alive at the call but gone
    %% when the link signal arrives sends the caller an exit signal with
    %% reason noproc, the same death as `killed` a moment later.
    {[unicode:characters_to_binary(io_lib:format("~0p", [R]))
      || R <- Reasons, not lists:member(R, [normal, killed, noproc])],
     Rows}.

churn_round(Index, P, Name, Topic, PerRound, Iterations) ->
    Partition = whereis(Name),
    true = is_pid(Partition),
    Before = churners(Index, P, Topic, PerRound, Iterations, []),
    [receive {churning, Pid} -> ok
     after 5000 -> error({churner_never_subscribed, Pid})
     end || {Pid, _Ref} <- Before],
    true = exit(Partition, kill),
    During = churners(Index, P, Topic, PerRound, Iterations, []),
    ok = await_restart(Name, Partition, erlang:monotonic_time(millisecond) + 5000),
    Before ++ During.

%% Start Count churners whose subscriptions live in partition Index
%% (brazier_pubsub_ffi:partition/2 hashes the pid); processes that hash
%% elsewhere exit at once.
churners(_Index, _P, _Topic, 0, _Iterations, Acc) ->
    Acc;
churners(Index, P, Topic, Count, Iterations, Acc) ->
    Parent = self(),
    Pid = spawn(fun() ->
                    receive
                        go -> churn(Parent, Topic, Iterations, false);
                        skip -> ok
                    end
                end),
    case erlang:phash2(Pid, P) + 1 of
        Index ->
            Ref = erlang:monitor(process, Pid),
            Pid ! go,
            churners(Index, P, Topic, Count - 1, Iterations, [{Pid, Ref} | Acc]);
        _ ->
            Pid ! skip,
            churners(Index, P, Topic, Count, Iterations, Acc)
    end.

%% Any result other than these crashes the churner with a case_clause.
churn(_Parent, _Topic, 0, _Told) ->
    ok;
churn(Parent, Topic, N, Told) ->
    Subscribed = case brazier_pubsub_ffi:subscribe(Topic) of
                     {ok, nil} -> true;
                     {error, not_started} -> false
                 end,
    case Subscribed andalso not Told of
        true -> Parent ! {churning, self()};
        false -> ok
    end,
    case brazier_pubsub_ffi:unsubscribe(Topic) of
        {ok, nil} -> ok;
        {error, not_started} -> ok
    end,
    churn(Parent, Topic, N - 1, Told orelse Subscribed).

await_churner({Pid, Ref}) ->
    receive
        {'DOWN', Ref, process, Pid, Reason} -> Reason
    after 10000 ->
        {churner_still_running, Pid}
    end.

await_restart(Name, Old, Deadline) ->
    case whereis(Name) of
        New when is_pid(New), New =/= Old ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> error({partition_not_restarted, Name});
                false -> erlang:yield(), await_restart(Name, Old, Deadline)
            end
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
