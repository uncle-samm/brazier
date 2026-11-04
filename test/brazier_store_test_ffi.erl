-module(brazier_store_test_ffi).

%% Test helpers for replicated stores (store_replicated_test,
%% cluster/store_cluster_test, brazier_store_bench).

-export([replica_pid/1, kill_replica/1, record_syncs/0, recorded_syncs/0,
         now_us/0]).

-define(SYNCS, brazier_test_store_syncs).

%% The pid of this node's key-value replica of store Name.
replica_pid(Name) ->
    {Server, _Sup, _Table, _Topic} = brazier_store_replica:names(key_value, Name),
    case whereis(Server) of
        undefined -> {error, nil};
        Pid -> {ok, Pid}
    end.

%% Kill this node's key-value replica of Name and wait until it is gone, so
%% the caller observes its supervisor restarting it. Returns the old pid.
kill_replica(Name) ->
    {ok, Pid} = replica_pid(Name),
    Ref = erlang:monitor(process, Pid),
    true = exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, killed} -> Pid
    after 5000 ->
        erlang:error({replica_not_killed, Pid})
    end.

%% Record every [brazier, store, sync, stop] event on this node, in a table
%% owned by a process that outlives the rpc call that started it.
record_syncs() ->
    Parent = self(),
    Ref = make_ref(),
    spawn(fun() ->
        ?SYNCS = ets:new(?SYNCS, [ordered_set, public, named_table]),
        Parent ! {Ref, ready},
        receive stop -> ok end
    end),
    receive {Ref, ready} -> ok after 5000 -> erlang:error(sync_table_not_ready) end,
    ok = telemetry:attach(<<"brazier-test-store-syncs">>, [brazier, store, sync, stop],
                          fun record_sync/4, nil),
    nil.

record_sync(_Name, Measurements, Metadata, nil) ->
    #{entries := Entries, bytes := Bytes, duration := Duration} = Measurements,
    #{store := Store, peer := Peer} = Metadata,
    true = ets:insert(?SYNCS, {erlang:unique_integer([monotonic]),
                               {Store, Peer, Entries, Bytes, Duration}}),
    ok.

%% Recorded syncs, oldest first, as {Store, Peer, Entries, Bytes, Duration}.
recorded_syncs() ->
    [Sync || {_, Sync} <- ets:tab2list(?SYNCS)].

now_us() ->
    erlang:monotonic_time(microsecond).
