-module(brazier_pubsub_ffi).

%% Brazier PubSub, a port of Phoenix.PubSub with its pg adapter.
%%
%% Local delivery reads the partitioned registry (brazier_pubsub_partition)
%% directly from the caller's process. Cross-node delivery sends ONE
%% {forward_to_local, Topic, Message} to the forwarding worker of the
%% caller's shard on each remote node (brazier_pubsub_worker), so a topic
%% with 10k subscribers on a node costs one cross-node message, not 10k.
%%
%% Subscribers receive {brazier_pubsub, Topic, Message}. brazier_subscription_ffi
%% and the runtime listener depend on that exact shape.

-export([
    start/1,
    ensure_started/1,
    start_link/1,
    stop/0,
    running_config/0,
    subscribe/1,
    unsubscribe/1,
    broadcast/2,
    local_broadcast/2,
    direct_broadcast/3,
    deliver_local/2,
    local_subscribers/1,
    local_subscriber_count/1,
    partition_for/1,
    max_topic_bytes/0,
    schedulers_online/0
]).

-define(SUP, brazier_pubsub_sup).
-define(SCOPE, brazier_pubsub_pg).
-define(CONFIG_KEY, {brazier_pubsub, config}).
-define(MAX_TOPIC_BYTES, 255).
%% Bound on stop/0: the supervisor's own shutdown of its children is
%% bounded by their shutdown timeouts, so this is only reached on a hang.
-define(STOP_TIMEOUT_MS, 15000).

max_topic_bytes() -> ?MAX_TOPIC_BYTES.

schedulers_online() -> erlang:system_info(schedulers_online).

%% --- Lifecycle ---

%% Start PubSub unlinked from the caller (the brazier.start / pubsub.start
%% path, where nothing supervises it yet). Fails if PubSub is already
%% running with a different configuration.
start(ConfigRecord) ->
    Config = config_map(ConfigRecord),
    case start_unlinked(Config) of
        {ok, _Pid} -> {ok, nil};
        {error, {already_started, Pid}} -> compare_running(Pid, Config);
        {error, Reason} -> {error, Reason}
    end.

%% Start PubSub unless it is already running, whatever its configuration.
%% This is the legacy pubsub.start() contract: "make sure it runs".
ensure_started(ConfigRecord) ->
    case start_unlinked(config_map(ConfigRecord)) of
        {ok, _Pid} -> {ok, nil};
        {error, {already_started, _Pid}} -> {ok, nil};
        {error, Reason} -> {error, Reason}
    end.

%% Start PubSub linked to the caller, for a supervisor to own (WS8b's root
%% supervisor). Returns {ok, Pid}.
start_link(ConfigRecord) ->
    case brazier_pubsub_sup:start_link(config_map(ConfigRecord)) of
        {ok, Pid} ->
            {ok, Pid};
        {error, {already_started, Pid}} ->
            brazier_log_ffi:error(<<"brazier.pubsub">>, "start_link: PubSub is already running as ~p", [Pid]),
            {error, {start_failed, <<"PubSub is already running under another owner">>}};
        {error, Reason} ->
            brazier_log_ffi:error(<<"brazier.pubsub">>, "start_link failed: ~p", [Reason]),
            {error, {start_failed, format(Reason)}}
    end.

start_unlinked(Config) ->
    case brazier_pubsub_sup:start_link(Config) of
        {ok, Pid} ->
            true = unlink(Pid),
            {ok, Pid};
        {error, {already_started, Pid}} ->
            {error, {already_started, Pid}};
        {error, Reason} ->
            brazier_log_ffi:error(<<"brazier.pubsub">>, "Start failed: ~p", [Reason]),
            {error, {start_failed, format(Reason)}}
    end.

compare_running(Pid, Config) ->
    %% A call to the supervisor is served only after its init/1 returned,
    %% and init/1 writes the config first, so after this call it is present
    %% even when another process is starting PubSub concurrently.
    [_ | _] = supervisor:count_children(Pid),
    Running = maps:with(config_keys(), persistent_term:get(?CONFIG_KEY)),
    case Running =:= Config of
        true ->
            {ok, nil};
        false ->
            brazier_log_ffi:error(<<"brazier.pubsub">>, "Already running with ~p; refusing ~p", [Running, Config]),
            {error, {invalid_config, format_already_running(Running)}}
    end.

%% Stop the PubSub supervisor. Every subscriber is linked to its partition,
%% so subscribers are stopped too (reason shutdown).
stop() ->
    case whereis(?SUP) of
        undefined ->
            {error, not_started};
        Pid ->
            brazier_log_ffi:info(<<"brazier.pubsub">>, "Stopping PubSub"),
            %% proc_lib:stop/3 rather than exit/2: a supervisor ignores a
            %% shutdown signal from any process but its parent, and stop/0
            %% may run in any process.
            try proc_lib:stop(Pid, shutdown, ?STOP_TIMEOUT_MS) of
                ok ->
                    brazier_log_ffi:info(<<"brazier.pubsub">>, "PubSub stopped"),
                    {ok, nil}
            catch
                exit:noproc ->
                    %% It stopped between whereis/1 and the stop request.
                    brazier_log_ffi:warning(<<"brazier.pubsub">>, "PubSub was already stopping"),
                    {error, not_started};
                exit:Reason ->
                    brazier_log_ffi:error(<<"brazier.pubsub">>, "PubSub did not stop: ~p", [Reason]),
                    {error, {stop_failed, format(Reason)}}
            end
    end.

%% The configuration PubSub is running with, as the Gleam record.
running_config() ->
    case config() of
        {error, not_started} -> {error, not_started};
        {ok, #{partitions := P, pool_size := S, max_forward_queue := Q,
               max_topics_per_subscriber := T}} ->
            {ok, {pub_sub_config, P, S, Q, T}}
    end.

%% --- Subscriptions (Registry.register / Registry.unregister) ---

subscribe(Topic) ->
    with_topic(Topic, fun(Config) -> subscribe(Topic, Config) end).

subscribe(Topic, Config) ->
    Self = self(),
    case partition(Self, Config) of
        {error, Reason} ->
            {error, Reason};
        {ok, PartitionPid, Name, Keys, Pids} ->
            #{max_topics_per_subscriber := Max} = Config,
            case lookup_own(Pids, Self) of
                {error, not_started} ->
                    restarting(PartitionPid, Self, Topic);
                {ok, Existing} ->
                    case lists:keymember(Topic, 2, Existing) of
                        true ->
                            {ok, nil};
                        false when length(Existing) >= Max ->
                            brazier_log_ffi:warning(<<"brazier.pubsub">>, "~p refused a subscription to ~ts: it "
                                                   "already has ~b topics (limit ~b)",
                                                   [Self, Topic, length(Existing), Max]),
                            {error, {too_many_subscriptions, Max}};
                        false ->
                            insert_subscription({PartitionPid, Name}, Keys, Pids, Self, Topic, Existing)
                    end
            end
    end.

%% Link before inserting (Registry.register/3 order) so the partition always
%% sees the subscriber exit. The partition registers its name only after
%% its tables exist, and the name goes when it dies, so:
%%   - after the link, the name still naming PartitionPid means the link is
%%     to the live partition that owns the tables;
%%   - after the inserts, it still naming PartitionPid means the rows went
%%     into that partition's tables, not into those of a successor that
%%     took the same table names after PartitionPid died (they would be
%%     orphans: no partition linked to this process would remove them).
insert_subscription({PartitionPid, Name}, Keys, Pids, Self, Topic, Existing) ->
    case link_partition(PartitionPid) of
        dead ->
            restarting(PartitionPid, Self, Topic);
        linked ->
            insert_linked({PartitionPid, Name}, Keys, Pids, Self, Topic, Existing)
    end.

%% link/1 to a process that is gone fails with noproc in a caller that does
%% not trap exits (one that does gets {'EXIT', Pid, noproc} and the name
%% check below sees the partition is gone).
link_partition(PartitionPid) ->
    try link(PartitionPid) of
        true -> linked
    catch
        error:noproc -> dead
    end.

insert_linked({PartitionPid, Name}, Keys, Pids, Self, Topic, Existing) ->
    case whereis(Name) =:= PartitionPid of
        false ->
            unlink_unless_subscribed(PartitionPid, Existing),
            restarting(PartitionPid, Self, Topic);
        true ->
            Inserted = try
                           true = ets:insert(Pids, {Self, Topic}),
                           true = ets:insert(Keys, {Topic, Self}),
                           inserted
                       catch
                           %% PartitionPid died between the check and the
                           %% inserts, and no successor has made the tables.
                           error:badarg -> no_table
                       end,
            case Inserted =:= inserted andalso whereis(Name) =:= PartitionPid of
                true ->
                    {ok, nil};
                false ->
                    ok = remove_rows(Keys, Pids, Self, Topic),
                    unlink_unless_subscribed(PartitionPid, Existing),
                    restarting(PartitionPid, Self, Topic)
            end
    end.

restarting(PartitionPid, Self, Topic) ->
    brazier_log_ffi:warning(<<"brazier.pubsub">>, "Partition ~p is restarting; ~p did not subscribe to ~ts",
                           [PartitionPid, Self, Topic]),
    {error, not_started}.

%% The subscriber's rows in its partition; the table is missing while the
%% partition restarts.
lookup_own(Pids, Self) ->
    try ets:lookup(Pids, Self) of
        Rows -> {ok, Rows}
    catch
        error:badarg -> {error, not_started}
    end.

%% Undo inserts that may have landed in a successor's tables, or half of
%% them; a missing table holds nothing to remove.
remove_rows(Keys, Pids, Self, Topic) ->
    [try true = ets:delete_object(Table, Row)
     catch error:badarg -> true
     end || {Table, Row} <- [{Pids, {Self, Topic}}, {Keys, {Topic, Self}}]],
    ok.

%% The link is shared by every topic the process holds in this partition.
unlink_unless_subscribed(PartitionPid, []) ->
    true = unlink(PartitionPid),
    ok;
unlink_unless_subscribed(_PartitionPid, [_ | _]) ->
    ok.

unsubscribe(Topic) ->
    with_topic(Topic, fun(Config) -> unsubscribe(Topic, Config) end).

unsubscribe(Topic, Config) ->
    Self = self(),
    case partition(Self, Config) of
        {error, Reason} ->
            {error, Reason};
        {ok, PartitionPid, _Name, Keys, Pids} ->
            ok = remove_rows(Keys, Pids, Self, Topic),
            case lookup_own(Pids, Self) of
                {ok, [_ | _]} ->
                    {ok, nil};
                {ok, []} ->
                    true = unlink(PartitionPid),
                    {ok, nil};
                {error, not_started} ->
                    %% PartitionPid died after the lookup: its tables, and
                    %% the rows in them, went with it.
                    restarting(PartitionPid, Self, Topic)
            end
    end.

%% The partition that owns Pid's subscriptions:
%% {ok, PartitionPid, Name, Keys, Pids}.
partition(Pid, Config) ->
    #{partitions := P, partition_names := Names, keys := KeysTables, pids := PidsTables} = Config,
    Index = erlang:phash2(Pid, P) + 1,
    case whereis(element(Index, Names)) of
        undefined ->
            brazier_log_ffi:warning(<<"brazier.pubsub">>, "Partition ~b is restarting; ~p cannot change its "
                                   "subscriptions until it is back", [Index, Pid]),
            {error, not_started};
        PartitionPid ->
            {ok, PartitionPid, element(Index, Names), element(Index, KeysTables), element(Index, PidsTables)}
    end.

%% The partition process Pid's subscriptions live in. A subscriber can
%% monitor it to learn the registry died (it is also linked to it).
partition_for(Pid) ->
    case config() of
        {error, not_started} -> {error, not_started};
        {ok, Config} ->
            case partition(Pid, Config) of
                {ok, PartitionPid, _Name, _Keys, _Pids} -> {ok, PartitionPid};
                {error, Reason} -> {error, Reason}
            end
    end.

%% --- Broadcasts ---

%% Deliver on this node and forward once to every connected remote node.
broadcast(Topic, Message) ->
    with_topic(Topic, fun(Config) ->
        case remote_workers(Config) of
            {error, Reason} ->
                {error, Reason};
            {ok, Workers} ->
                Local = deliver(Topic, Message, Config),
                Forwarded = forward(Workers, Topic, Message),
                brazier_telemetry_ffi:pubsub_broadcast(Local, Forwarded, <<"cluster">>),
                {ok, nil}
        end
    end).

%% Deliver on this node only.
local_broadcast(Topic, Message) ->
    with_topic(Topic, fun(Config) ->
        Local = deliver(Topic, Message, Config),
        brazier_telemetry_ffi:pubsub_broadcast(Local, 0, <<"local">>),
        {ok, nil}
    end).

%% Deliver on one node only: Node's local subscribers.
direct_broadcast(Node, Topic, Message) ->
    with_topic(Topic, fun(Config) -> direct_broadcast(Node, Topic, Message, Config) end).

direct_broadcast(Node, Topic, Message, _Config) when Node =:= node() ->
    case local_broadcast(Topic, Message) of
        {ok, nil} -> {ok, nil};
        {error, Reason} -> {error, Reason}
    end;
direct_broadcast(Node, Topic, Message, Config) ->
    NotConnected = {error, {node_not_connected, atom_to_binary(Node, utf8)}},
    case shard_members(Config) of
        {error, Reason} ->
            {error, Reason};
        {ok, Members} ->
            case [W || W <- Members, node(W) =:= Node] of
                [] ->
                    NotConnected;
                [Worker | _] ->
                    case erlang:send(Worker, {forward_to_local, Topic, Message}, [noconnect]) of
                        noconnect ->
                            NotConnected;
                        ok ->
                            brazier_telemetry_ffi:pubsub_broadcast(0, 1, <<"direct">>),
                            {ok, nil}
                    end
            end
    end.

%% Used by the forwarding worker: deliver a forwarded message locally.
deliver_local(Topic, Message) ->
    case config() of
        {error, not_started} -> {error, not_started};
        {ok, Config} -> {ok, deliver(Topic, Message, Config)}
    end.

deliver(Topic, Message, Config) ->
    Pids = subscribers(Topic, Config),
    [Pid ! {brazier_pubsub, Topic, Message} || Pid <- Pids],
    length(Pids).

subscribers(Topic, #{keys := KeysTables}) ->
    lists:append([lookup_partition(Table, Topic) || Table <- tuple_to_list(KeysTables)]).

%% A missing table means its partition is restarting. Its subscribers were
%% linked to it and have been stopped with it, so it has none to deliver to.
lookup_partition(Table, Topic) ->
    try
        [Pid || {_, Pid} <- ets:lookup(Table, Topic)]
    catch
        error:badarg ->
            brazier_log_ffi:warning(<<"brazier.pubsub">>, "Registry table ~p is missing (partition "
                                   "restarting); it has no live subscribers for ~ts", [Table, Topic]),
            []
    end.

%% Forwarding workers of the caller's shard on remote nodes. The shard is
%% picked from the caller's pid, so one sender's broadcasts keep their order.
remote_workers(Config) ->
    case shard_members(Config) of
        {error, Reason} -> {error, Reason};
        {ok, Members} -> {ok, [W || W <- Members, node(W) =/= node()]}
    end.

shard_members(#{pool_size := PoolSize}) ->
    Shard = erlang:phash2(self(), PoolSize),
    try
        {ok, pg:get_members(?SCOPE, {brazier_pubsub, Shard})}
    catch
        error:badarg ->
            %% The pg scope is restarting; nothing is delivered so the
            %% caller sees the failure instead of a half-delivered message.
            brazier_log_ffi:error(<<"brazier.pubsub">>, "The pg scope ~p is not running; broadcast refused",
                                 [?SCOPE]),
            {error, not_started}
    end.

%% Sends one forward per remote worker. Returns the number sent. A node that
%% pg still lists but distribution already dropped returns noconnect: that
%% node is going down and pg will remove it.
forward(Workers, Topic, Message) ->
    lists:foldl(fun(Worker, Sent) ->
        case erlang:send(Worker, {forward_to_local, Topic, Message}, [noconnect]) of
            ok ->
                Sent + 1;
            noconnect ->
                brazier_log_ffi:warning(<<"brazier.pubsub">>, "Forward of ~ts to ~p not sent: node ~p is "
                                       "disconnected", [Topic, Worker, node(Worker)]),
                Sent
        end
    end, 0, Workers).

%% --- Introspection ---

local_subscribers(Topic) ->
    case config() of
        {error, not_started} -> {error, not_started};
        {ok, Config} -> {ok, lists:usort(subscribers(Topic, Config))}
    end.

%% No running registry has no subscribers.
local_subscriber_count(Topic) ->
    case local_subscribers(Topic) of
        {ok, Pids} -> length(Pids);
        {error, not_started} -> 0
    end.

%% --- Helpers ---

with_topic(Topic, Fun) ->
    case valid_topic(Topic) of
        false ->
            {error, {invalid_topic, Topic}};
        true ->
            case config() of
                {error, not_started} -> {error, not_started};
                {ok, Config} -> Fun(Config)
            end
    end.

valid_topic(Topic) when is_binary(Topic) ->
    Size = byte_size(Topic),
    Size >= 1 andalso Size =< ?MAX_TOPIC_BYTES;
valid_topic(_) ->
    false.

config() ->
    case whereis(?SUP) of
        undefined ->
            {error, not_started};
        _Pid ->
            %% The supervisor registers its name just before its init/1
            %% writes the config, so a caller racing the very first start
            %% can see the name without the config: PubSub is not started
            %% yet from that caller's point of view.
            case persistent_term:get(?CONFIG_KEY, undefined) of
                undefined -> {error, not_started};
                Config -> {ok, Config}
            end
    end.

config_keys() -> [partitions, pool_size, max_forward_queue, max_topics_per_subscriber].

config_map({pub_sub_config, Partitions, PoolSize, MaxForwardQueue, MaxTopics}) ->
    #{partitions => Partitions, pool_size => PoolSize, max_forward_queue => MaxForwardQueue,
      max_topics_per_subscriber => MaxTopics}.

format_already_running(#{partitions := P, pool_size := S, max_forward_queue := Q,
                         max_topics_per_subscriber := T}) ->
    iolist_to_binary(io_lib:format(
        "PubSub is already running with a different configuration (partitions ~b, "
        "pool_size ~b, max_forward_queue ~b, max_topics_per_subscriber ~b)", [P, S, Q, T])).

format(Term) ->
    unicode:characters_to_binary(io_lib:format("~p", [Term])).
