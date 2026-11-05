-module(brazier_presence_test_ffi).

%% Helpers for the presence tests: fake replication messages from a peer
%% that does not exist, built with the real CRDT, and delivery straight to a
%% shard. The shard cannot tell them from PubSub deliveries, so tests can
%% drive replica up, down, permdown, restarts and the limits from one node
%% (with_verified_peer runs them on a member naming the other member).

-export([fake_ref/2, heartbeat/2, transfer_ack/4, odd_transfer_ack/4, graceful_permdown/2,
         send_peer/3, receive_diff/1, parent/1, unique_positive/0, shard_has_delta/1,
         malformed_messages/1, malformed_diffs/1, with_fingerprint/2, fingerprint_of/1,
         with_verified_peer/1]).

-define(STATE, 'brazier@presence@state').
%% How long a test body may run on the peer.
-define(PEER_CALL_MS, 30000).

%% Run Fun(Ghost) on a cluster member, where Ghost is the name of the
%% other member of a two-node cluster: a shard only takes replication
%% messages from verified members, and a member is verified only while it
%% is connected over the connection its peer check passed on
%% (brazier_cluster_ffi:verified/1), so the fake peer messages a test sends
%% must name a real, connected, verified node. Ghost runs no presence of
%% the test's name, so only the messages the test sends come from it. The
%% peers stop before this returns, also when Fun crashes.
with_verified_peer(Fun) ->
    brazier_peer_ffi:with_members(2, <<"presence">>, fun([Member, Other]) ->
        Ghost = atom_to_binary(brazier_peer_ffi:node_of(Other)),
        case brazier_peer_ffi:rpc(Member, fun() -> Fun(Ghost) end, ?PEER_CALL_MS) of
            {ok, _Result} -> nil;
            {error, Reason} -> erlang:error({test_failed_on_peer, Reason})
        end
    end).

%% A replica ref {Node, Vsn} for a node that need not exist.
fake_ref(NodeName, Vsn) ->
    {binary_to_atom(NodeName, utf8), {Vsn, 0}}.

%% An empty heartbeat from Ref.
heartbeat(Ref, PoolSize) ->
    {brazier_presence, heartbeat, PoolSize, Ref, none, ?STATE:clocks(?STATE:new(Ref))}.

%% A transfer_ack from Ref holding Entries ([{Key, Json}]) on Topic, tracked
%% by a pid of the calling node.
transfer_ack(Ref, PoolSize, Topic, Entries) ->
    raw_transfer_ack(Ref, PoolSize, Topic,
                     [{Key, {stored_meta, Json, <<"fake-", Key/binary>>, none}}
                      || {Key, Json} <- Entries]).

%% transfer_ack/4 with three more entries whose metas a peer running this
%% code never sends: odd_json (JSON that is not a binary), odd_prev (a
%% previous ref that is not an Option(String)) and odd_shape (not a stored
%% meta at all).
odd_transfer_ack(Ref, PoolSize, Topic, Entries) ->
    raw_transfer_ack(Ref, PoolSize, Topic,
                     [{Key, {stored_meta, Json, <<"fake-", Key/binary>>, none}}
                      || {Key, Json} <- Entries]
                     ++ [{<<"odd_json">>, {stored_meta, 42, <<"fake-odd_json">>, none}},
                         {<<"odd_prev">>, {stored_meta, <<"\"x\"">>, <<"fake-odd_prev">>, {some, 7}}},
                         {<<"odd_shape">>, not_a_stored_meta}]).

raw_transfer_ack(Ref, PoolSize, Topic, Entries) ->
    State = lists:foldl(fun({Key, Meta}, Acc) ->
        {ok, {Next, _}} = ?STATE:join(Acc, self(), Topic, Key, Meta),
        Next
    end, ?STATE:new(Ref), Entries),
    {brazier_presence, transfer_ack, PoolSize, Ref, {delta_transfer, ?STATE:delta(State)}}.

graceful_permdown(Ref, PoolSize) ->
    {brazier_presence, graceful_permdown, PoolSize, Ref}.

%% Deliver Message to Shard as if PubSub had, on the shard's own topic.
send_peer(Shard, ShardTopic, Message) ->
    Shard ! {brazier_pubsub, ShardTopic, Message},
    nil.

%% The next PubSub delivery's message: {ok, Message} or {error, nil}.
receive_diff(TimeoutMs) ->
    receive
        {brazier_pubsub, _Topic, Message} -> {ok, Message}
    after TimeoutMs ->
        {error, nil}
    end.

%% The process that started Pid (proc_lib's parent: a shard's supervisor).
parent(Pid) ->
    {parent, Parent} = erlang:process_info(Pid, parent),
    true = is_pid(Parent),
    Parent.

unique_positive() ->
    erlang:unique_integer([positive]).

%% Replication messages a shard must log and ignore: not a tuple, a tuple
%% without a replica ref, an unknown kind, and known kinds with bad shapes,
%% from a replica of NodeName.
malformed_messages(NodeName) ->
    Ref = fake_ref(NodeName, 1),
    [garbage,
     {brazier_presence, heartbeat, 1, not_a_ref, none, nil},
     {brazier_presence, bogus, 1, Ref},
     {brazier_presence, heartbeat, 1, Ref, not_a_delta, nil},
     {brazier_presence, transfer_ack, 1, Ref, not_a_transfer}].

%% Variants of a real diff message, {brazier_presence_diff, Name,
%% Fingerprint, Topic, Joins, Leaves}, that decode_diff must refuse as not a
%% diff: a meta of another shape, a key that is not a binary, a pid that is
%% not a pid, an entry of another size, sides that are not lists, a topic
%% that is not a binary and a tuple of another size.
malformed_diffs({brazier_presence_diff, Name, Fp, Topic, [{Key, Pid, Meta} | _], _Leaves}) ->
    Diff = fun(Joins) -> {brazier_presence_diff, Name, Fp, Topic, Joins, []} end,
    [Diff([{Key, Pid, garbage}]),
     Diff([{Key, Pid, setelement(3, Meta, 7)}]),
     Diff([{Key, Pid, {undecodable, <<"n@h">>, 7}}]),
     Diff([{binary_to_list(Key), Pid, Meta}]),
     Diff([{Key, not_a_pid, Meta}]),
     Diff([{Key, Pid}]),
     Diff([{Key, Pid, Meta} | not_a_list]),
     {brazier_presence_diff, Name, Fp, Topic, not_a_list, []},
     {brazier_presence_diff, Name, Fp, binary_to_list(Topic), [{Key, Pid, Meta}], []},
     {brazier_presence_diff, Name, Topic, [{Key, Pid, Meta}], []}].

%% The diff message with another decoder fingerprint.
with_fingerprint({brazier_presence_diff, Name, _Fp, Topic, Joins, Leaves}, Fingerprint) ->
    {brazier_presence_diff, Name, Fingerprint, Topic, Joins, Leaves}.

%% The decoder fingerprint a diff message carries.
fingerprint_of({brazier_presence_diff, _Name, Fp, _Topic, _Joins, _Leaves}) ->
    Fp.

%% Whether Shard holds changes its next heartbeat will broadcast.
shard_has_delta(Shard) ->
    #{pres := Pres} = sys:get_state(Shard),
    ?STATE:has_delta(Pres).
