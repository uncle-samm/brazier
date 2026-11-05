-module(brazier_membership_window_ffi).

%% Helpers for test/brazier/cluster/membership_window_test.gleam: the
%% windows in which the membership could disagree with the connection it
%% is about (a row outliving its connection, a manager restart with
%% waiters in flight, a check that only one side has passed).

-export([member_row/1, verified/1, disconnect/1, connect/1,
         kill_manager/0, wait_rows/1, insert_wait/3, dead_pid/0, connection_id/1,
         spawn_mutual_recorder/0, spawn_row_waiter/2, mutual_count/3, verified_count/3, subscriber_row/1, live_subscribers/0,
         await_without_manager/1, node_named/1]).

-define(MEMBERS, brazier_cluster_members).
-define(WAITERS, brazier_cluster_waiters).
-define(MANAGER, brazier_cluster).
-define(WAIT_MS, 5000).

%% Whether the manager's member table holds a row for Node, whatever its
%% connection.
member_row(Node) ->
    ets:member(?MEMBERS, Node).

verified(Node) ->
    brazier_cluster_ffi:verified(Node).

%% Drop the connection to Node; returns once this node no longer lists it.
disconnect(Node) ->
    true = erlang:disconnect_node(Node),
    false = lists:member(Node, nodes()),
    nil.

%% Connect to Node; returns once the connection is up.
connect(Node) ->
    true = net_kernel:connect_node(Node),
    true = lists:member(Node, nodes()),
    nil.

%% Kill the cluster manager (no terminate runs, as in a crash); returns once
%% it is gone and its name is free.
kill_manager() ->
    Pid = whereis(?MANAGER),
    true = is_pid(Pid),
    Ref = monitor(process, Pid),
    true = exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, killed} -> nil
    after ?WAIT_MS -> error({kill_manager, still_running})
    end.

%% How many processes wait for Node in the waiters table, on any connection.
wait_rows(Node) ->
    length(ets:match_object(?WAITERS, {{await, Node, '_'}, '_'})).

%% A wait row as brazier_cluster_ffi:await_verified/1 writes it, for a
%% process or connection the test chose.
insert_wait(Node, Pid, ConnectionId) ->
    true = ets:insert(?WAITERS, {{await, Node, Pid}, ConnectionId}),
    nil.

%% The pid of a process that has exited.
dead_pid() ->
    {Pid, Ref} = spawn_monitor(fun() -> ok end),
    receive
        {'DOWN', Ref, process, Pid, normal} -> Pid
    after ?WAIT_MS -> error({dead_pid, still_running})
    end.

connection_id(Node) ->
    {ok, Id} = brazier_cluster_ffi:connection_id(Node),
    Id.

%% A process subscribed to the mutual notices
%% (brazier_cluster_ffi:subscribe_mutual/1) that counts them per node.
%% Returns once it is subscribed.
spawn_mutual_recorder() ->
    spawn_recorder(fun() -> {ok, nil} = brazier_cluster_ffi:subscribe_mutual(self()) end).

%% A process with a wait row for Node on connection ConnectionId, written
%% by itself as await_verified/1 would (which needs a running manager),
%% that counts its verified notices. Returns once the row is written.
spawn_row_waiter(Node, ConnectionId) ->
    spawn_recorder(fun() -> nil = insert_wait(Node, self(), ConnectionId) end).

spawn_recorder(Setup) ->
    Parent = self(),
    Ready = make_ref(),
    Pid = spawn(fun() ->
                        _ = Setup(),
                        Parent ! Ready,
                        recorder_loop(#{})
                end),
    receive Ready -> Pid
    after ?WAIT_MS -> error({spawn_recorder, not_ready})
    end.

%% Counts every {Tag, Node} notice, so a second one shows in the next
%% count.
recorder_loop(Counts) ->
    receive
        {Tag, Node} when Tag =:= brazier_cluster_peer_mutual; Tag =:= brazier_cluster_peer_verified ->
            Key = {Tag, Node},
            recorder_loop(Counts#{Key => maps:get(Key, Counts, 0) + 1});
        {count, Key, From, Ref} ->
            From ! {Ref, maps:get(Key, Counts, 0)},
            recorder_loop(Counts);
        {await, Key = {Tag, Node}, From, Ref} ->
            case maps:get(Key, Counts, 0) of
                0 ->
                    receive
                        {Tag, Node} ->
                            From ! {Ref, 1},
                            recorder_loop(Counts#{Key => 1})
                    after ?WAIT_MS ->
                        From ! {Ref, 0},
                        recorder_loop(Counts)
                    end;
                Told ->
                    From ! {Ref, Told},
                    recorder_loop(Counts)
            end
    end.

%% How many mutual (or verified) notices for Node a recorder has had:
%% Await true waits (up to 5s, inside peer.on's 10s) for the first one, false answers now.
mutual_count(Pid, Node, Await) ->
    count(Pid, {brazier_cluster_peer_mutual, Node}, Await).

verified_count(Pid, Node, Await) ->
    count(Pid, {brazier_cluster_peer_verified, Node}, Await).

count(Pid, Key, Await) ->
    Tag = case Await of true -> await; false -> count end,
    Ref = monitor(process, Pid),
    Pid ! {Tag, Key, self(), Ref},
    receive
        {Ref, Count} -> true = demonitor(Ref, [flush]), Count;
        {'DOWN', Ref, process, Pid, Reason} -> error({recorder_down, Reason})
    after 2 * ?WAIT_MS -> error({recorder_timeout, Tag})
    end.

%% Whether the waiters table holds a subscription row for Pid.
subscriber_row(Pid) ->
    ets:member(?WAITERS, {subscriber, Pid}).

live_subscribers() ->
    brazier_cluster_ffi:live_subscribers().

%% await_verified/1 with no manager running on this node.
await_without_manager(Node) ->
    undefined = whereis(?MANAGER),
    brazier_cluster_ffi:await_verified(Node).

%% The node name Name, for a node that is never connected.
node_named(Name) ->
    binary_to_atom(Name, utf8).
