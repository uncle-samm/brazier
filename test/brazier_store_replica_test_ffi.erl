-module(brazier_store_replica_test_ffi).

%% Malformed replication payloads for store_replica_payload_test and
%% cluster/store_replica_validation_test, and a way to hand one to a
%% replica as if a cluster member had sent it.

-export([malformed_payloads/0, inject/4]).

-define(CRDT, 'brazier@store@crdt').

%% [{Label, What, Payload, ReasonFragment}]: each Payload is a real delta
%% (or full state) with one field broken, and ReasonFragment is part of the
%% reason brazier_store_replica:check_payload/2 must give.
malformed_payloads() ->
    Replica = {replica, <<"a@host">>, 1},
    Ts = {timestamp, 10, 0, <<"a@host">>},
    {_State, Delta, _Changes} =
        ?CRDT:put(?CRDT:new(), Replica, <<"k">>, <<"v">>, Ts, [<<"room:1">>]),
    {delta, Entries, Context, Topics} = Delta,
    #{<<"k">> := Dots} = Entries,
    [{Dot, Entry}] = maps:to_list(Dots),
    {entry, Value, _, EntryTopics} = Entry,
    {context, Clock, Cloud, Floors} = Context,
    WithDot = fun(BadDot) ->
        {delta, #{<<"k">> => #{BadDot => Entry}}, Context, Topics}
    end,
    WithEntry = fun(BadEntry) ->
        {delta, #{<<"k">> => #{Dot => BadEntry}}, Context, Topics}
    end,
    WithContext = fun(BadContext) -> {delta, Entries, BadContext, Topics} end,
    [
     {<<"not a tuple">>, delta, nope, <<"not a {delta">>},
     {<<"wrong tag">>, delta, {state, Entries, Context, Topics}, <<"not a {delta">>},
     {<<"entries not a map">>, delta, {delta, [], Context, Topics}, <<"not a {delta">>},
     {<<"key not a string">>, delta, {delta, #{42 => Dots}, Context, Topics},
      <<"a key is not a string">>},
     {<<"key not UTF-8">>, delta, {delta, #{<<255>> => Dots}, Context, Topics},
      <<"a key is not UTF-8">>},
     {<<"dots not a map">>, delta, {delta, #{<<"k">> => [Entry]}, Context, Topics},
      <<"not a map of dots">>},
     {<<"dot counter 0">>, delta, WithDot({dot, Replica, 0}), <<"an entry dot is not">>},
     {<<"dot counter not an integer">>, delta, WithDot({dot, Replica, <<"1">>}),
      <<"an entry dot is not">>},
     {<<"dot replica not a replica">>, delta, WithDot({dot, a_node, 1}),
      <<"an entry dot is not {replica">>},
     {<<"dot replica negative incarnation">>, delta,
      WithDot({dot, {replica, <<"a@host">>, -1}, 1}), <<"an entry dot is not {replica">>},
     {<<"dot replica empty node">>, delta, WithDot({dot, {replica, <<>>, 1}, 1}),
      <<"empty node name">>},
     {<<"entry not a tuple">>, delta, WithEntry(Value), <<"an entry is not">>},
     {<<"timestamp negative wall">>, delta,
      WithEntry({entry, Value, {timestamp, -1, 0, <<"a@host">>}, EntryTopics}),
      <<"a timestamp is not">>},
     {<<"timestamp node not a string">>, delta,
      WithEntry({entry, Value, {timestamp, 10, 0, 'a@host'}, EntryTopics}),
      <<"a timestamp node is not a string">>},
     {<<"entry topics not a list">>, delta, WithEntry({entry, Value, Ts, <<"t">>}),
      <<"the topics of an entry are not a list">>},
     {<<"entry topic not a string">>, delta, WithEntry({entry, Value, Ts, [topic]}),
      <<"an entry topic is not a string">>},
     {<<"delta topics not a list">>, delta, {delta, Entries, Context, nil},
      <<"the delta topics are not a list">>},
     {<<"delta topic not UTF-8">>, delta, {delta, Entries, Context, [<<16#C0>>]},
      <<"a delta topic is not UTF-8">>},
     {<<"context not a tuple">>, delta, WithContext(Clock), <<"the context is not">>},
     {<<"cloud not a set">>, delta, WithContext({context, Clock, [], Floors}),
      <<"the context is not">>},
     {<<"clock counter 0">>, delta, WithContext({context, #{Replica => 0}, Cloud, Floors}),
      <<"a clock counter is not">>},
     {<<"clock replica malformed">>, delta, WithContext({context, #{nope => 1}, Cloud, Floors}),
      <<"a clock replica is not">>},
     {<<"cloud dot malformed">>, delta,
      WithContext({context, Clock, {set, #{{dot, Replica, -3} => []}}, Floors}),
      <<"a cloud dot is not">>},
     {<<"cloud token not a set token">>, delta,
      WithContext({context, Clock, {set, #{{dot, Replica, 3} => true}}, Floors}),
      <<"the cloud is not a set">>},
     {<<"context without floors">>, delta, WithContext({context, Clock, Cloud}),
      <<"the context is not">>},
     {<<"floors not a map">>, delta, WithContext({context, Clock, Cloud, []}),
      <<"the context is not">>},
     {<<"floor 0">>, delta, WithContext({context, Clock, Cloud, #{<<"a@host">> => 0}}),
      <<"a floor is not an integer >= 1">>},
     {<<"floor node not a string">>, delta,
      WithContext({context, Clock, Cloud, #{'a@host' => 2}}),
      <<"a floor node is not a string">>},
     {<<"floor node empty">>, delta, WithContext({context, Clock, Cloud, #{<<>> => 2}}),
      <<"a floor node is empty">>},
     %% The context covers counter 1 only.
     {<<"live dot outside its context">>, delta, WithDot({dot, Replica, 5}),
      <<"its own context does not cover">>},
     {<<"full state with delta topics">>, sync, {delta, Entries, Context, [<<"t">>]},
      <<"carries delta topics">>},
     {<<"full state with an empty key">>, sync, {delta, #{<<"k">> => #{}}, Context, []},
      <<"a key with no values">>}
    ].

%% Deliver {brazier_store, What, From, Payload} to this node's key-value
%% replica of store Name, as PubSub delivers a member's message, and wait
%% until the replica has handled it (a call queued behind it).
inject(Name, From, What, Payload) ->
    {Server, _Sup, _Table, Topic} = brazier_store_replica:names(key_value, Name),
    Server ! {brazier_pubsub, Topic, {brazier_store, What, From, Payload}},
    {ok, _Digest} = brazier_store_replica:digest(Server),
    nil.
