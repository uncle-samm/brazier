-module(beacon_ws8c_presence_sync_ffi).

%% Helpers for the shard sync waiter tests (beacon_presence_shard, Sync
%% waiters): heartbeats from a fake peer that claim a clock, the raw
%% await_sync request and its answer, and raw messages for the unhappy
%% paths.

-export([heartbeat_at/3, await_sync/2, send_raw/2, receive_synced/2, receive_any/1]).

%% A heartbeat from Ref (see beacon_presence_test_ffi:fake_ref/2) saying it
%% has issued Clock events, with no delta.
heartbeat_at(Ref, PoolSize, Clock) ->
    {beacon_presence, heartbeat, PoolSize, Ref, none, {Ref, #{Ref => Clock}}}.

%% Ask Shard to answer the calling process once it has synced with Nodes.
await_sync(Shard, Nodes) ->
    Shard ! {beacon_presence_await_sync, self(), Nodes},
    nil.

send_raw(Pid, Term) ->
    Pid ! Term,
    nil.

%% The next answer of Shard: {ok, {NodeBin, StatusBin}} or {error, nil}.
receive_synced(Shard, TimeoutMs) ->
    receive
        {beacon_presence_synced, Shard, NodeBin, Status} ->
            {ok, {NodeBin, atom_to_binary(Status, utf8)}}
    after TimeoutMs ->
        {error, nil}
    end.

%% The next message of any kind, as a tag: <<"diff">> for a PubSub
%% delivery, <<"synced">> for a sync answer, or {error, nil}.
receive_any(TimeoutMs) ->
    receive
        {beacon_pubsub, _Topic, _Message} -> {ok, <<"diff">>};
        {beacon_presence_synced, _Shard, _NodeBin, _Status} -> {ok, <<"synced">>}
    after TimeoutMs ->
        {error, nil}
    end.
