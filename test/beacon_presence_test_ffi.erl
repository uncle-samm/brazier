-module(beacon_presence_test_ffi).

%% Helpers for the presence tests: fake replication messages from a peer
%% that does not exist, built with the real CRDT, and delivery straight to a
%% shard. The shard cannot tell them from PubSub deliveries, so single-node
%% tests can drive replica up, down, permdown, restarts and the limits.

-export([fake_ref/2, heartbeat/2, transfer_ack/4, graceful_permdown/2,
         send_peer/3, receive_diff/1, flush_diffs/0, unique_positive/0, shard_has_delta/1,
         malformed_messages/0]).

-define(STATE, 'beacon@presence@state').

%% A replica ref {Node, Vsn} for a node that need not exist.
fake_ref(NodeName, Vsn) ->
    {binary_to_atom(NodeName, utf8), {Vsn, 0}}.

%% An empty heartbeat from Ref.
heartbeat(Ref, PoolSize) ->
    {beacon_presence, heartbeat, PoolSize, Ref, none, ?STATE:clocks(?STATE:new(Ref))}.

%% A transfer_ack from Ref holding Entries ([{Key, Json}]) on Topic, tracked
%% by a pid of the calling node.
transfer_ack(Ref, PoolSize, Topic, Entries) ->
    State = lists:foldl(fun({Key, Json}, Acc) ->
        Meta = {stored_meta, Json, <<"fake-", Key/binary>>, none},
        {ok, {Next, _}} = ?STATE:join(Acc, self(), Topic, Key, Meta),
        Next
    end, ?STATE:new(Ref), Entries),
    {beacon_presence, transfer_ack, PoolSize, Ref, {delta_transfer, ?STATE:delta(State)}}.

graceful_permdown(Ref, PoolSize) ->
    {beacon_presence, graceful_permdown, PoolSize, Ref}.

%% Deliver Message to Shard as if PubSub had, on the shard's own topic.
send_peer(Shard, ShardTopic, Message) ->
    Shard ! {beacon_pubsub, ShardTopic, Message},
    nil.

%% The next PubSub delivery's message: {ok, Message} or {error, nil}.
receive_diff(TimeoutMs) ->
    receive
        {beacon_pubsub, _Topic, Message} -> {ok, Message}
    after TimeoutMs ->
        {error, nil}
    end.

%% Drop every PubSub delivery already in the mailbox; returns how many.
flush_diffs() ->
    flush_diffs(0).

flush_diffs(N) ->
    receive
        {beacon_pubsub, _Topic, _Message} -> flush_diffs(N + 1)
    after 0 ->
        N
    end.

unique_positive() ->
    erlang:unique_integer([positive]).

%% Replication messages a shard must log and ignore: not a tuple, a tuple
%% without a replica ref, an unknown kind, and known kinds with bad shapes.
malformed_messages() ->
    Ref = fake_ref(<<"fake@host">>, 1),
    [garbage,
     {beacon_presence, heartbeat, 1, not_a_ref, none, nil},
     {beacon_presence, bogus, 1, Ref},
     {beacon_presence, heartbeat, 1, Ref, not_a_delta, nil},
     {beacon_presence, transfer_ack, 1, Ref, not_a_transfer}].

%% Whether Shard holds changes its next heartbeat will broadcast.
shard_has_delta(Shard) ->
    #{pres := Pres} = sys:get_state(Shard),
    ?STATE:has_delta(Pres).
