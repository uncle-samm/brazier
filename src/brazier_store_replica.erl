-module(brazier_store_replica).
-behaviour(gen_server).

%% One replica of a replicated store on this node (brazier/store with mode
%% Replicated). Modelled on Phoenix.Tracker.Shard (see
%% brazier_presence_shard) with the delta-state AWLWWMap of delta_crdt_ex
%% (brazier/store/crdt) as its state.
%%
%% The replica owns its state and mirrors the visible values into a
%% protected named ETS table, so reads never call it:
%%
%%   key-value  set          {Key, Value}            (the last writer's value)
%%   list       ordered_set  {{Key, Ts, Dot}, Value} (every value, HLC order)
%%
%% Writes are calls. A write is applied here, mirrored to ETS, and its delta
%% broadcast at once on brazier_store:<kind>:<name>. Every message is
%% {brazier_store, Kind, FromNode, ...}:
%%
%%   delta     broadcast after every local write: {delta, From, Delta}
%%   digest    broadcast every sync_interval_ms: the state's digest
%%             (brazier/store/crdt.digest, kept up to date by every join,
%%             so a tick never walks the state)
%%   sync_req  "send me your full state": broadcast when the replica starts,
%%             sent directly once a connected node and this node have
%%             verified each other ({brazier_cluster_peer_mutual, Node},
%%             brazier_cluster_ffi:subscribe_mutual/1: a request sent when
%%             only this side had verified the peer would be dropped by the
%%             peer as coming from a non-member) and when a peer's digest
%%             differs
%%   sync      the reply: the sender's full state
%%
%% Only cluster members replicate: PubSub forwards only to and from verified
%% nodes, and a message whose From is not a verified member is dropped and
%% logged here as well.
%%
%% Deltas are fire and forget: one lost during a partition (or dropped by an
%% overloaded PubSub forwarder) is repaired by the digest exchange, which
%% pulls a full state from every peer whose state differs. Joins are
%% idempotent, so a delta that arrives twice, late, or after the full state
%% that contained it changes nothing.
%%
%% Every remote merge runs inside the [brazier, store, sync] span and is
%% refused (logged, not merged) when the payload is malformed (see
%% check_payload/2), larger than max_delta_bytes / max_sync_bytes, or would
%% grow the replica past max_entries. The span's stop metadata says which:
%% `result` is malformed, too_large, too_many_entries or ok, and `reason`
%% the failing field or limit. A refused merge leaves the digests
%% different, so a later exchange retries it (after the backoff below),
%% and logs again.
%%
%% A peer's payload is checked field by field before anything reads it:
%% the CRDT functions assume the shapes brazier/store/crdt builds, so a
%% malformed term from a member (another version, a bug, a hand-sent
%% message) would crash the replica, or worse be joined and break
%% convergence on every node it reaches. Phoenix.Tracker likewise matches
%% the exact shape of every replica message before merging it.
%%
%% Peers and sync. Every replica joins the pg group
%% {brazier_store_replica, Topic} of the brazier_pubsub_pg scope, so its
%% peers are the members of that group on verified cluster members (a node
%% that has not opened the store holds no replica and is not waited for).
%% The last digest each peer sent is kept; the replica is *in sync* when
%% every peer's last digest is its own (synced/1, true with no peer). A
%% local write, a merge or a new peer ends that until the next digests
%% agree. Like Phoenix.Tracker, which keeps each replica's last heard
%% clock, this needs no extra message: the periodic digests are the
%% acknowledgements.
%%
%% Backoff. A merge refused by a limit or a malformed payload leaves the
%% digests different, and the next digest would pull the same state, be
%% refused again, and transfer up to max_sync_bytes every interval. So each
%% refusal from a peer delays the next state request to it: after attempt
%% N (from 0) by a uniformly random delay in [D/2, D] with
%% D = min(Cap, Interval * 2^N), Cap = max(Interval, 60s)
%% (brazier_cluster_manager:backoff_window/3, the cluster's reconnect
%% backoff), logged with the delay. A merge of its state, or equal
%% digests, ends the backoff (logged). The backoff map holds at most one
%% entry per member and is pruned on nodedown.
%%
%% Floors (brazier/store/crdt, "Floors"). A replica started on a node that
%% ran an earlier incarnation of it raises its node's floor to its own
%% incarnation once it is in sync with at least one peer and every peer it
%% has: the clock entries and cloud dots of the earlier incarnations go,
%% everywhere, so the context does not grow with every restart. The raise
%% is a context-only delta, broadcast like a write. Incarnations only grow
%% on a node (next_incarnation/1). A replica that merges a floor of its own
%% node above its own incarnation (a later incarnation of its node exists:
%% a clock that went back across a restart of the node) would have every
%% write it makes covered, so dropped, everywhere: it logs an error and
%% stops, and its restart takes an incarnation above that floor.
%%
%% Remote changes are announced to this node's watchers by local_broadcast
%% of nil on the store topic, plus the extra topics of every added or
%% removed entry and of the delta. Local writes are announced by the writer
%% (brazier/store), as for a node-local store.

-export([start/3, start_link/1, stop/1, call/2,
         put/3, remove/3, append/4, config/1, digest/1, size/1, synced/1,
         context_size/1,
         read_get/2, read_get_all/2, read_count/1, names/2,
         check_payload/2, admit/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(CRDT, 'brazier@store@crdt').
-define(HLC, 'brazier@store@hlc').
%% Bound on a write call. A replica serves calls between merges, so a call
%% that takes longer than this means the replica is stuck.
-define(CALL_TIMEOUT_MS, 5000).
-define(STOP_TIMEOUT_MS, 10000).
%% A remote timestamp this far ahead of the wall clock is logged: its writes
%% win every LWW comparison until the local clocks catch up.
-define(DRIFT_WARNING_MS, 60000).
%% The pg scope (started by brazier_pubsub_sup, which a replica needs to
%% subscribe) and group every replica of a store joins.
-define(PEER_SCOPE, brazier_pubsub_pg).
-define(PEER_GROUP(Topic), {brazier_store_replica, Topic}).
%% The longest delay before a state request to a peer whose merges were
%% refused, unless the sync interval is longer.
-define(MAX_BACKOFF_MS, 60000).

%% --- Names ---

%% {Server, Sup, Table, ReplicationTopic} for a store. Name is validated by
%% brazier/store/replicated ([A-Za-z0-9_-], 1 to 200 bytes), and stores are
%% opened with developer-supplied names, so the atoms are bounded.
names(key_value, Name) ->
    names(<<"brazier_rs_">>, <<"brazier_store_">>, <<"kv">>, Name);
names(list, Name) ->
    names(<<"brazier_rls_">>, <<"brazier_ls_">>, <<"list">>, Name).

names(ServerPrefix, TablePrefix, KindBin, Name) ->
    Server = <<ServerPrefix/binary, Name/binary>>,
    {binary_to_atom(Server, utf8),
     binary_to_atom(<<Server/binary, "_sup">>, utf8),
     binary_to_atom(<<TablePrefix/binary, Name/binary>>, utf8),
     <<"brazier_store:", KindBin/binary, ":", Name/binary>>}.

%% --- Lifecycle ---

%% Start the replica of store Name (unlinked from the caller), or return the
%% running one when it was started with the same configuration.
%% Returns {ok, {Server, Table}} | {error, {invalid_config, Reason}} |
%% {error, {start_failed, Reason}} (brazier/store/replicated.StartError).
start(Kind, Name, Config) ->
    {Server, Sup, Table, Topic} = names(Kind, Name),
    case whereis(Server) of
        undefined ->
            case ets:whereis(Table) of
                undefined ->
                    start_sup(Kind, Name, Config, Server, Sup, Table, Topic);
                _ ->
                    brazier_log_ffi:error(<<"brazier.store">>, "Cannot open ~ts as a replicated store: it is "
                                         "already open in local mode", [Name]),
                    {error, {invalid_config,
                             <<"store ", Name/binary, " is already open in local mode">>}}
            end;
        _Pid ->
            same_config(Kind, Name, Config, Server, Table)
    end.

start_sup(Kind, Name, Config, Server, Sup, Table, Topic) ->
    Args = #{kind => Kind, name => Name, config => Config, server => Server,
             sup => Sup, table => Table, topic => Topic},
    case brazier_store_sup:start_link(Args) of
        {ok, Pid} ->
            true = unlink(Pid),
            {ok, {Server, Table}};
        {error, {already_started, _}} ->
            %% Another process opened the same store concurrently.
            same_config(Kind, Name, Config, Server, Table);
        {error, Reason} ->
            brazier_log_ffi:error(<<"brazier.store">>, "Replicated store ~ts failed to start: ~p",
                                 [Name, Reason]),
            {error, {start_failed, format(Reason)}}
    end.

same_config(_Kind, Name, Config, Server, Table) ->
    case config(Server) of
        {ok, Config} ->
            {ok, {Server, Table}};
        {ok, Other} ->
            brazier_log_ffi:error(<<"brazier.store">>, "Replicated store ~ts is already open with ~p, "
                                 "not ~p", [Name, Other, Config]),
            {error, {invalid_config, <<"store ", Name/binary,
                                       " is already open with a different configuration">>}};
        {error, {unavailable, Reason}} ->
            {error, {start_failed, Reason}}
    end.

start_link(Args = #{server := Server}) ->
    gen_server:start_link({local, Server}, ?MODULE, Args, []).

%% Stop a replica and its supervisor (tests, shutdown).
stop(Server) ->
    case whereis(sup_of(Server)) of
        undefined ->
            {error, <<"not running">>};
        Pid ->
            brazier_log_ffi:info(<<"brazier.store">>, "Stopping ~p", [Server]),
            try proc_lib:stop(Pid, shutdown, ?STOP_TIMEOUT_MS) of
                ok -> {ok, nil}
            catch
                exit:Reason -> {error, format(Reason)}
            end
    end.

sup_of(Server) ->
    binary_to_existing_atom(<<(atom_to_binary(Server, utf8))/binary, "_sup">>, utf8).

%% --- Calls (from brazier/store/replicated) ---

put(Server, Key, Value) -> call(Server, {put, Key, Value}).
remove(Server, Key, Topics) -> call(Server, {remove, Key, Topics}).
append(Server, Key, Values, Topics) -> call(Server, {append, Key, Values, Topics}).
config(Server) -> call(Server, config).
digest(Server) -> call(Server, digest).
size(Server) -> call(Server, size).
synced(Server) -> call(Server, synced).
context_size(Server) -> call(Server, context_size).

call(Server, Request) ->
    try
        gen_server:call(Server, Request, ?CALL_TIMEOUT_MS)
    catch
        exit:{timeout, _} ->
            brazier_log_ffi:error(<<"brazier.store">>, "~p did not answer ~p within ~bms",
                                 [Server, request_name(Request), ?CALL_TIMEOUT_MS]),
            {error, {unavailable, <<"replica timeout">>}};
        exit:{noproc, _} ->
            brazier_log_ffi:error(<<"brazier.store">>, "~p is not running", [Server]),
            {error, {unavailable, <<"replica not running">>}};
        exit:Reason ->
            brazier_log_ffi:error(<<"brazier.store">>, "~p exited during a call: ~p", [Server, Reason]),
            {error, {unavailable, format(Reason)}}
    end.

request_name(Request) when is_tuple(Request) -> element(1, Request);
request_name(Request) -> Request.

%% --- Reads (ETS, no call) ---

%% The table dies with its replica; reads in that window see it missing.
read_get(Table, Key) ->
    read(Table, fun() ->
        case ets:lookup(Table, Key) of
            [{_, Value}] -> {some, Value};
            [] -> none
        end
    end).

read_get_all(Table, Key) ->
    read(Table, fun() ->
        ets:select(Table, [{{{Key, '_', '_'}, '$1'}, [], ['$1']}])
    end).

read_count(Table) ->
    read(Table, fun() ->
        case ets:info(Table, size) of
            undefined -> error(badarg);
            Size -> Size
        end
    end).

read(Table, Run) ->
    case ets:whereis(Table) of
        undefined ->
            missing(Table);
        _ ->
            try
                {ok, Run()}
            catch
                error:badarg -> missing(Table)
            end
    end.

missing(Table) ->
    brazier_log_ffi:error(<<"brazier.store">>, "Table ~p is missing: its replica is not running", [Table]),
    {error, <<"replica not running">>}.

%% --- gen_server ---

init(Args) ->
    process_flag(trap_exit, true),
    #{kind := Kind, name := Name, table := Table, topic := Topic,
      config := {config, Interval, _, _, _, _}} = Args,
    case ets:whereis(Table) of
        undefined ->
            case brazier_pubsub_ffi:subscribe(Topic) of
                {error, Reason} ->
                    brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts cannot subscribe to ~ts: ~p",
                                         [Name, Topic, Reason]),
                    {stop, {pubsub_subscribe_failed, Reason}};
                {ok, nil} ->
                    Type = case Kind of
                        key_value -> set;
                        list -> ordered_set
                    end,
                    Table = ets:new(Table, [Type, protected, named_table,
                                            {read_concurrency, true}]),
                    case brazier_cluster_ffi:subscribe_mutual(self()) of
                        {ok, nil} -> join_peers(Args, Name, Topic, Interval);
                        {error, Reason} ->
                            brazier_log_ffi:error(<<"brazier.store">>,
                                                 "Replica ~ts cannot subscribe to cluster membership: ~p",
                                                 [Name, Reason]),
                            {stop, {membership_subscribe_failed, Reason}}
                    end
            end;
        _ ->
            brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts cannot start: table ~p exists",
                                 [Name, Table]),
            {stop, {table_exists, Table}}
    end.

%% Join the peer group, so the other replicas count this one among their
%% peers. The scope runs under the PubSub supervisor this replica just
%% subscribed through; a scope that is gone stops the start.
join_peers(Args, Name, Topic, Interval) ->
    try pg:join(?PEER_SCOPE, ?PEER_GROUP(Topic), self()) of
        ok -> init_replica(Args, Name, Interval)
    catch
        exit:Reason ->
            brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts cannot join its peer group: ~p",
                                 [Name, Reason]),
            {stop, {peer_group_join_failed, Reason}}
    end.

init_replica(Args = #{server := Server}, Name, Interval) ->
    ok = net_kernel:monitor_nodes(true),
    NodeBin = atom_to_binary(node(), utf8),
    Replica = {replica, NodeBin, next_incarnation(Server)},
    S = Args#{replica => Replica,
              node_bin => NodeBin,
              crdt => ?CRDT:new(),
              hlc => ?HLC:zero(NodeBin),
              %% Node => {Pid, Digest}: each peer's last digest.
              peer_digests => #{},
              %% Node => {Attempt, RetryAtMs (monotonic)}.
              backoff => #{},
              in_sync => false,
              floor_raised => false},
    %% Up to one interval of initial jitter so replicas
    %% started together do not exchange digests in lockstep.
    schedule_sync(rand:uniform(max(1, Interval))),
    brazier_log_ffi:info(<<"brazier.store">>, "Replica ~ts started as ~ts",
                        [Name, ?CRDT:replica_to_string(Replica)]),
    %% Ask every running replica for its state.
    publish(S, {brazier_store, sync_req, node()}),
    {ok, S}.

handle_call({put, Key, Value}, _From, S = #{kind := key_value}) ->
    local_write(S, put, [Value], fun(Crdt, Replica, Hlc) ->
        Ts = ?HLC:tick(Hlc, now_ms()),
        {?CRDT:put(Crdt, Replica, Key, Value, Ts, []), Ts}
    end);
handle_call({append, Key, Values, Topics}, _From, S = #{kind := list}) ->
    local_write(S, append, Values, fun(Crdt, Replica, Hlc) ->
        {Items, Last} = lists:mapfoldl(fun(Value, Clock) ->
            Ts = ?HLC:tick(Clock, now_ms()),
            {{Value, Ts}, Ts}
        end, Hlc, Values),
        {?CRDT:append(Crdt, Replica, Key, Items, Topics), Last}
    end);
handle_call({remove, Key, Topics}, _From, S) ->
    local_write(S, remove, [], fun(Crdt, _Replica, Hlc) ->
        {?CRDT:remove(Crdt, Key, Topics), Hlc}
    end);
handle_call(config, _From, S = #{config := Config}) ->
    {reply, {ok, Config}, S};
handle_call(digest, _From, S) ->
    {reply, {ok, state_digest(S)}, S};
handle_call(size, _From, S = #{crdt := Crdt}) ->
    {reply, {ok, ?CRDT:size(Crdt)}, S};
handle_call(synced, _From, S) ->
    {reply, {ok, synced_with(peers(S), S)}, S};
handle_call(context_size, _From, S = #{crdt := Crdt}) ->
    {reply, {ok, ?CRDT:context_size(Crdt)}, S};
handle_call(Request, From, S) ->
    brazier_log_ffi:warning(<<"brazier.store">>, "Replica ~ts received unexpected call ~p from ~p",
                           [label(S), Request, From]),
    {reply, {error, {unavailable, <<"unexpected request">>}}, S}.

handle_cast(Request, S) ->
    brazier_log_ffi:warning(<<"brazier.store">>, "Replica ~ts received unexpected cast ~p",
                           [label(S), Request]),
    {noreply, S}.

handle_info(sync_tick, S = #{config := {config, Interval, _, _, _, _}}) ->
    publish(S, {brazier_store, digest, node(), state_digest(S)}),
    schedule_sync(Interval),
    {noreply, S};
handle_info({brazier_pubsub, Topic, Message}, S = #{topic := Topic}) ->
    S1 = peer_message(Message, S),
    case stale_incarnation(S1) of
        ok ->
            {noreply, note_sync(S1)};
        {stale, Floor} ->
            {stop, {stale_incarnation, Floor}, S1}
    end;
handle_info({nodeup, Node}, S) ->
    %% A connected node is not yet a cluster member: the state is requested
    %% once it and this node have verified each other
    %% (brazier_cluster_peer_mutual).
    case whereis(brazier_cluster) of
        undefined ->
            brazier_log_ffi:warning(<<"brazier.store">>, "Replica ~ts: ~p connected, but no cluster manager "
                                   "runs here, so it is not replicated to", [label(S), Node]);
        _Manager ->
            brazier_log_ffi:info(<<"brazier.store">>, "Replica ~ts: ~p connected, awaiting the peer checks",
                                [label(S), Node])
    end,
    {noreply, S};
handle_info({brazier_cluster_peer_mutual, Node}, S) ->
    brazier_log_ffi:info(<<"brazier.store">>, "Replica ~ts: ~p and this node have verified each other, "
                        "requesting its state", [label(S), Node]),
    send_direct(S, Node, {brazier_store, sync_req, node()}),
    {noreply, note_sync(S)};
handle_info({nodedown, Node}, S = #{peer_digests := Digests, backoff := Backoff}) ->
    brazier_log_ffi:info(<<"brazier.store">>, "Replica ~ts: ~p disconnected", [label(S), Node]),
    S1 = S#{peer_digests := maps:remove(Node, Digests), backoff := maps:remove(Node, Backoff)},
    {noreply, note_sync(S1)};
handle_info({'EXIT', Pid, Reason}, S) ->
    %% The only link besides the parent (handled by gen_server) is the
    %% PubSub partition this replica subscribed through. Without it the
    %% replica no longer hears its peers, so it stops and is restarted.
    brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts: linked ~p exited (~p); stopping",
                         [label(S), Pid, Reason]),
    {stop, {linked_exit, Reason}, S};
handle_info(Message, S) ->
    brazier_log_ffi:warning(<<"brazier.store">>, "Replica ~ts received unexpected message ~p",
                           [label(S), Message]),
    {noreply, S}.

terminate(Reason, S) ->
    brazier_log_ffi:info(<<"brazier.store">>, "Replica ~ts stopping: ~p", [label(S), Reason]),
    nil = brazier_cluster_ffi:unsubscribe_mutual(self()),
    ok.

%% --- Local writes ---

%% Check the values, apply Op, check the delta and the new size, then
%% mirror and broadcast. Nothing changes when a check fails.
local_write(S, OpName, Values, Op) ->
    #{crdt := Crdt, replica := Replica, hlc := Hlc,
      config := {config, _, MaxEntries, MaxValue, MaxDelta, _}} = S,
    case oversized_value(Values, MaxValue) of
        {error, Bytes} ->
            brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts refused a ~p: a value of ~b bytes "
                                 "exceeds max_value_bytes ~b", [label(S), OpName, Bytes, MaxValue]),
            {reply, {error, {value_too_large, Bytes, MaxValue}}, S};
        ok ->
            {{Crdt1, Delta, Changes}, Hlc1} = Op(Crdt, Replica, Hlc),
            Message = {brazier_store, delta, node(), Delta},
            Bytes = erlang:external_size(Message),
            Size = ?CRDT:size(Crdt1),
            Grows = Size > ?CRDT:size(Crdt),
            if
                Bytes > MaxDelta ->
                    brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts refused a ~p: its delta of ~b "
                                         "bytes exceeds max_delta_bytes ~b",
                                         [label(S), OpName, Bytes, MaxDelta]),
                    {reply, {error, {delta_too_large, Bytes, MaxDelta}}, S};
                Size > MaxEntries andalso Grows ->
                    brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts refused a ~p: ~b entries would "
                                         "exceed max_entries ~b", [label(S), OpName, Size, MaxEntries]),
                    {reply, {error, {too_many_entries, MaxEntries}}, S};
                Changes =:= [] ->
                    %% Nothing observed to remove: no delta to send.
                    {reply, {ok, nil}, S#{hlc := Hlc1}};
                true ->
                    mirror(S, Crdt1, Changes),
                    publish(S, Message),
                    {reply, {ok, nil}, note_sync(S#{crdt := Crdt1, hlc := Hlc1})}
            end
    end.

oversized_value([], _Max) ->
    ok;
oversized_value([Value | Rest], Max) ->
    case erlang:external_size(Value) of
        Bytes when Bytes > Max -> {error, Bytes};
        _ -> oversized_value(Rest, Max)
    end.

%% --- Peer messages ---

peer_message({brazier_store, _Kind, From}, S) when From =:= node() ->
    %% Broadcasts are also delivered to this node, so to this replica.
    S;
peer_message({brazier_store, _Kind, From, _}, S) when From =:= node() ->
    S;
peer_message(Message, S) when is_tuple(Message), tuple_size(Message) >= 3,
                              element(1, Message) =:= brazier_store ->
    From = element(3, Message),
    case is_atom(From) andalso brazier_cluster_ffi:verified(From) of
        true ->
            member_message(Message, S);
        false ->
            %% PubSub already drops forwards from unverified nodes; this
            %% check also covers the From a member could put in a message.
            brazier_log_ffi:warning(<<"brazier.store">>, "Replica ~ts dropped a ~0P from ~0P: not a "
                                   "verified cluster member", [label(S), element(2, Message), 5, From, 5]),
            S
    end;
peer_message(Message, S) ->
    unexpected_message(Message, S).

%% Delta and Full are checked by merge/6 (check_payload/2), so a malformed
%% one is refused there with an error and its sync span.
member_message({brazier_store, delta, From, Delta}, S) when is_atom(From) ->
    #{config := {config, _, _, _, MaxDelta, _}} = S,
    {S1, Result} = merge(S, From, delta, Delta, MaxDelta, fun ?CRDT:join/2),
    merged(S1, From, delta, Result);
member_message({brazier_store, sync, From, Full}, S) when is_atom(From) ->
    #{config := {config, _, _, _, _, MaxSync}} = S,
    brazier_log_ffi:debug(<<"brazier.store">>, "Replica ~ts received the state of ~p", [label(S), From]),
    {S1, Result} = merge(S, From, sync, Full, MaxSync, fun ?CRDT:join_full/2),
    merged(S1, From, sync, Result);
member_message({brazier_store, digest, From, Digest}, S)
  when is_atom(From), is_binary(Digest) ->
    S1 = record_digest(S, From, Digest),
    case state_digest(S1) of
        Digest -> end_backoff(S1, From, <<"its digest matches">>);
        _Other -> request_state(S1, From)
    end;
member_message({brazier_store, sync_req, From}, S) when is_atom(From) ->
    #{crdt := Crdt, config := {config, _, _, _, _, MaxSync}} = S,
    Message = {brazier_store, sync, node(), ?CRDT:to_delta(Crdt)},
    case erlang:external_size(Message) of
        Bytes when Bytes > MaxSync ->
            brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts refuses to send its state to ~p: ~b "
                                 "bytes exceed max_sync_bytes ~b", [label(S), From, Bytes, MaxSync]),
            S;
        _ ->
            send_direct(S, From, Message),
            S
    end;
member_message(Message, S) ->
    unexpected_message(Message, S).

unexpected_message(Message, S) ->
    brazier_log_ffi:warning(<<"brazier.store">>, "Replica ~ts received an unexpected replication "
                           "message ~P", [label(S), Message, 20]),
    S.

%% Merge a delta or a full state from From inside the sync span. The span's
%% stop event says how the merge ended: `result` is ok, malformed,
%% too_large or too_many_entries, and `reason` names the malformed field
%% (check_payload/2), the limit that refused it, or is none. A malformed
%% payload is refused before anything reads it, so its entries are 0.
%% Returns {State, Result}.
merge(S = #{name := Name}, From, What, Payload, MaxBytes, Join) ->
    Peer = atom_to_binary(From, utf8),
    brazier_telemetry_ffi:store_sync_span(Name, Peer, fun() ->
        Bytes = erlang:external_size(Payload),
        case admit(What, Payload, Bytes, MaxBytes) of
            {refused, Entries, <<"malformed">> = Result, Reason} ->
                brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts refused a malformed ~p of ~b "
                                     "bytes from ~p: ~ts", [label(S), What, Bytes, From, Reason]),
                {{S, Result}, Entries, Bytes, Result, Reason};
            {refused, Entries, <<"too_large">> = Result, Limit} ->
                brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts refused a ~p of ~b bytes from ~p: "
                                     "over ~ts ~b", [label(S), What, Bytes, From, Limit, MaxBytes]),
                {{S, Result}, Entries, Bytes, Result, Limit};
            {admitted, Entries} ->
                {S1, Result, Reason} = checked_merge(S, From, What, Payload, Join),
                {{S1, Result}, Entries, Bytes, Result, Reason}
        end
    end).

%% Whether a payload of Bytes may be joined, before anything reads it:
%% {admitted, Entries}, or {refused, Entries, Result, Reason} with the
%% span's result and reason. Entries is the number of dots it carries, 0
%% for a malformed payload (it cannot be counted).
admit(What, Payload, Bytes, MaxBytes) ->
    case check_payload(What, Payload) of
        {error, Reason} ->
            {refused, 0, <<"malformed">>, Reason};
        {ok, nil} ->
            Entries = ?CRDT:delta_size(Payload),
            case Bytes > MaxBytes of
                true -> {refused, Entries, <<"too_large">>, byte_limit(What)};
                false -> {admitted, Entries}
            end
    end.

byte_limit(delta) -> <<"max_delta_bytes">>;
byte_limit(sync) -> <<"max_sync_bytes">>.

%% Join an admitted payload unless it would grow the replica past
%% max_entries. Returns {State, Result, Reason} for the sync span.
checked_merge(S, From, What, Payload, Join) ->
    #{crdt := Crdt, config := {config, _, MaxEntries, _, _, _}} = S,
    {Crdt1, Changes} = Join(Crdt, Payload),
    Size = ?CRDT:size(Crdt1),
    case Size > MaxEntries andalso Size > ?CRDT:size(Crdt) of
        true ->
            brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts refused a ~p from ~p: ~b entries would "
                                 "exceed max_entries ~b", [label(S), What, From, Size, MaxEntries]),
            {S, <<"too_many_entries">>, <<"max_entries">>};
        false ->
            S1 = S#{crdt := Crdt1, hlc := advance_clock(S, From, Payload)},
            case Changes of
                [] ->
                    ok;
                _ ->
                    mirror(S1, Crdt1, Changes),
                    announce(S1, Changes, element(4, Payload))
            end,
            {S1, <<"ok">>, <<"none">>}
    end.

%% The HLC after a merge is ahead of every timestamp merged.
advance_clock(S = #{hlc := Hlc}, From, Payload) ->
    case ?CRDT:max_timestamp(Payload) of
        {error, nil} ->
            Hlc;
        {ok, Remote} ->
            Now = now_ms(),
            case ?HLC:drift_ms(Remote, Now) of
                Drift when Drift > ?DRIFT_WARNING_MS ->
                    brazier_log_ffi:warning(<<"brazier.store">>, "Replica ~ts: ~p sent a timestamp ~bms ahead "
                                           "of this node's clock; check clock synchronisation",
                                           [label(S), From, Drift]);
                _ ->
                    ok
            end,
            ?HLC:observe(Hlc, Remote, Now)
    end.

%% --- Sync, backoff and floors ---

%% After a merge from From: a merged full state ends a backoff on From, a
%% refused merge (of either kind) starts or lengthens it.
merged(S, From, sync, <<"ok">>) ->
    end_backoff(S, From, <<"its state merged">>);
merged(S, _From, delta, <<"ok">>) ->
    S;
merged(S, From, What, Result) ->
    back_off(S, From, What, Result).

back_off(S = #{backoff := Backoff, config := {config, Interval, _, _, _, _}}, From, What, Result) ->
    Attempt = case maps:find(From, Backoff) of
        {ok, {Previous, _RetryAt}} -> Previous + 1;
        error -> 0
    end,
    {Low, High} = brazier_cluster_manager:backoff_window(Attempt, Interval,
                                                         max(Interval, ?MAX_BACKOFF_MS)),
    Delay = Low + rand:uniform(High - Low + 1) - 1,
    brazier_log_ffi:warning(<<"brazier.store">>, "Replica ~ts: a ~p from ~p was refused (~ts, refusal ~b "
                           "in a row); its state is requested again in ~bms at the earliest",
                           [label(S), What, From, Result, Attempt + 1, Delay]),
    S#{backoff := Backoff#{From => {Attempt, now_mono_ms() + Delay}}}.

end_backoff(S = #{backoff := Backoff}, From, Why) ->
    case maps:take(From, Backoff) of
        {{Attempt, _RetryAt}, Rest} ->
            brazier_log_ffi:info(<<"brazier.store">>, "Replica ~ts: ~ts after ~b refused merges from ~p; "
                                "its state is requested on every differing digest again",
                                [label(S), Why, Attempt + 1, From]),
            S#{backoff := Rest};
        error ->
            S
    end.

%% A digest from From differs from this replica's: pull From's state,
%% unless a refused merge put From in backoff and its delay has not passed.
request_state(S = #{backoff := Backoff}, From) ->
    case maps:find(From, Backoff) of
        {ok, {Attempt, RetryAt}} ->
            Now = now_mono_ms(),
            case Now >= RetryAt of
                true ->
                    brazier_log_ffi:info(<<"brazier.store">>, "Replica ~ts differs from ~p, requesting its "
                                        "state again after ~b refused merges",
                                        [label(S), From, Attempt + 1]),
                    send_direct(S, From, {brazier_store, sync_req, node()});
                false ->
                    brazier_log_ffi:debug(<<"brazier.store">>, "Replica ~ts differs from ~p, but holds its "
                                         "state request back for ~bms after ~b refused merges",
                                         [label(S), From, RetryAt - Now, Attempt + 1])
            end;
        error ->
            brazier_log_ffi:debug(<<"brazier.store">>, "Replica ~ts differs from ~p, requesting its state",
                                 [label(S), From]),
            send_direct(S, From, {brazier_store, sync_req, node()})
    end,
    S.

%% The replicas of this store on verified cluster members, not this one.
peers(#{topic := Topic}) ->
    [Pid || Pid <- pg:get_members(?PEER_SCOPE, ?PEER_GROUP(Topic)),
            node(Pid) =/= node(),
            brazier_cluster_ffi:verified(node(Pid))].

%% Keep From's digest against the one replica From runs. While pg has not
%% yet shown it (or still shows a stopped one beside it), the digest is not
%% kept: the peer is not in sync until a later digest is.
record_digest(S = #{topic := Topic, peer_digests := Digests}, From, Digest) ->
    case [Pid || Pid <- pg:get_members(?PEER_SCOPE, ?PEER_GROUP(Topic)), node(Pid) =:= From] of
        [Pid] ->
            S#{peer_digests := Digests#{From => {Pid, Digest}}};
        Pids ->
            brazier_log_ffi:debug(<<"brazier.store">>, "Replica ~ts: ~p sent a digest while its peer group "
                                 "shows ~b replicas there; not counted towards sync",
                                 [label(S), From, length(Pids)]),
            S#{peer_digests := maps:remove(From, Digests)}
    end.

%% Whether every peer's last digest is this replica's digest (true with no
%% peer).
synced_with(Peers, S = #{peer_digests := Digests}) ->
    Digest = state_digest(S),
    lists:all(fun(Pid) -> maps:get(node(Pid), Digests, none) =:= {Pid, Digest} end, Peers).

%% Log a change of the in-sync state; on reaching it with at least one
%% peer, raise this node's floor if an earlier incarnation needs it.
note_sync(S = #{in_sync := Was}) ->
    Peers = peers(S),
    case {Was, synced_with(Peers, S)} of
        {false, true} ->
            brazier_log_ffi:debug(<<"brazier.store">>, "Replica ~ts is in sync with its ~b peers",
                                 [label(S), length(Peers)]),
            maybe_raise_floor(S#{in_sync := true}, length(Peers));
        {true, false} ->
            brazier_log_ffi:debug(<<"brazier.store">>, "Replica ~ts is no longer in sync with its ~b peers",
                                 [label(S), length(Peers)]),
            S#{in_sync := false};
        {Same, Same} ->
            S
    end.

maybe_raise_floor(S, 0) ->
    S;
maybe_raise_floor(S = #{floor_raised := true}, _Peers) ->
    S;
maybe_raise_floor(S = #{crdt := Crdt, replica := Replica}, Peers) ->
    case ?CRDT:has_older_incarnation(Crdt, Replica) of
        false ->
            S;
        true ->
            %% INVARIANT: an older incarnation of this node outside the
            %% floor means the floor is below it, so below this
            %% incarnation, and raise_floor/2 raises it.
            {ok, {Crdt1, Delta}} = ?CRDT:raise_floor(Crdt, Replica),
            brazier_log_ffi:info(<<"brazier.store">>, "Replica ~ts is in sync with its ~b peers and raised "
                                "the floor of its node to its incarnation: its causal context went from "
                                "~b to ~b elements",
                                [label(S), Peers, ?CRDT:context_size(Crdt), ?CRDT:context_size(Crdt1)]),
            publish(S, {brazier_store, delta, node(), Delta}),
            S#{crdt := Crdt1, floor_raised := true, in_sync := false}
    end.

%% ok, or {stale, Floor} when the state holds a floor of this node above
%% this incarnation (see the module doc). The floor is recorded first, so
%% the restart's incarnation is above it.
stale_incarnation(S = #{crdt := Crdt, node_bin := NodeBin, server := Server,
                        replica := {replica, _, Incarnation}}) ->
    case ?CRDT:floor(Crdt, NodeBin) of
        Floor when Floor > Incarnation ->
            ok = persistent_term:put(incarnation_key(Server), Floor),
            brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts merged a floor of its own node (~b) above "
                                 "its incarnation ~b: a later incarnation of this node exists, so every "
                                 "write of this one would be dropped; stopping to restart above it",
                                 [label(S), Floor, Incarnation]),
            {stale, Floor};
        _AtOrBelow ->
            ok
    end.

%% A new incarnation for Server: the wall clock in microseconds, or one
%% above the last incarnation (or stale floor) of Server on this VM when
%% the clock has not moved past it, so incarnations only grow on a node.
%% persistent_term holds one integer per replicated store name; it is
%% written once per replica start.
next_incarnation(Server) ->
    Key = incarnation_key(Server),
    Last = persistent_term:get(Key, 0),
    Incarnation = max(erlang:system_time(microsecond), Last + 1),
    ok = persistent_term:put(Key, Incarnation),
    Incarnation.

incarnation_key(Server) ->
    {?MODULE, incarnation, Server}.

now_mono_ms() ->
    erlang:monotonic_time(millisecond).

%% --- Payload validation ---

%% {ok, nil} when Payload has exactly the shape brazier/store/crdt gives a Delta
%% (What = delta) or a full state from to_delta (What = sync), else
%% {error, Reason} naming the first malformed field. Values are any term.
%%
%%   Delta    {delta, #{Key => #{Dot => Entry}}, Context, [Topic]}
%%   Dot      {dot, Replica, Counter}            Counter >= 1
%%   Replica  {replica, Node, Incarnation}       Node non-empty, Incarnation >= 0
%%   Entry    {entry, Value, Timestamp, [Topic]}
%%   Timestamp {timestamp, WallMs, Logical, Node} both >= 0
%%   Context  {context, #{Replica => Max}, Cloud, #{Node => Floor}}
%%            Max >= 1, Cloud a set of Dot, Node non-empty, Floor >= 1
%%
%% Keys, topics and node names are UTF-8 binaries (Gleam strings). Beyond
%% the shapes, every live dot must be covered by the payload's own context
%% (a dot the sender never observed cannot be live there, and joining it
%% would leave a live dot outside the receiver's context). A full state
%% carries no delta topics and no key without dots (join never keeps one).
%% Cloud is a gleam/set, {set, #{Dot => []}} on Erlang; the round trip
%% test of a real delta (store_replica_payload_test) catches a change of
%% that representation.
check_payload(What, Payload) when What =:= delta; What =:= sync ->
    try validate_payload(What, Payload) of
        ok -> {ok, nil}
    catch
        throw:{brazier_malformed_payload, Reason} -> {error, Reason}
    end.

validate_payload(What, {delta, Entries, Context, Topics}) when is_map(Entries) ->
    validate_context(Context),
    validate_topics(Topics, <<"the delta topics">>, <<"a delta topic">>),
    case What =:= sync andalso Topics =/= [] of
        true -> malformed(<<"a full state carries delta topics">>);
        false -> ok
    end,
    maps:foreach(fun(Key, Dots) -> validate_key(What, Key, Dots, Context) end, Entries);
validate_payload(_What, _Payload) ->
    malformed(<<"not a {delta, Entries, Context, Topics} tuple with a map of entries">>).

validate_key(What, Key, Dots, Context) ->
    validate_string(Key, <<"a key">>),
    case Dots of
        #{} when What =:= sync, map_size(Dots) =:= 0 ->
            malformed(<<"a full state names a key with no values">>);
        #{} ->
            maps:foreach(fun(Dot, Entry) ->
                validate_dot(Dot, <<"an entry dot">>),
                validate_entry(Entry),
                case ?CRDT:covers(Context, Dot) of
                    true -> ok;
                    false -> malformed(<<"a live dot its own context does not cover">>)
                end
            end, Dots);
        _ ->
            malformed(<<"the values of a key are not a map of dots">>)
    end.

validate_entry({entry, _Value, Ts, Topics}) ->
    validate_timestamp(Ts),
    validate_topics(Topics, <<"the topics of an entry">>, <<"an entry topic">>);
validate_entry(_) ->
    malformed(<<"an entry is not {entry, Value, Timestamp, Topics}">>).

validate_timestamp({timestamp, Wall, Logical, Node})
  when is_integer(Wall), Wall >= 0, is_integer(Logical), Logical >= 0 ->
    validate_string(Node, <<"a timestamp node">>);
validate_timestamp(_) ->
    malformed(<<"a timestamp is not {timestamp, WallMs >= 0, Logical >= 0, Node}">>).

validate_context({context, Clock, {set, Cloud}, Floors})
  when is_map(Clock), is_map(Cloud), is_map(Floors) ->
    maps:foreach(fun(Node, Floor) ->
        validate_string(Node, <<"a floor node">>),
        case Node of
            <<>> -> malformed(<<"a floor node is empty">>);
            _NonEmpty -> ok
        end,
        case is_integer(Floor) andalso Floor >= 1 of
            true -> ok;
            false -> malformed(<<"a floor is not an integer >= 1">>)
        end
    end, Floors),
    maps:foreach(fun(Replica, Max) ->
        validate_replica(Replica, <<"a clock replica">>),
        case is_integer(Max) andalso Max >= 1 of
            true -> ok;
            false -> malformed(<<"a clock counter is not an integer >= 1">>)
        end
    end, Clock),
    maps:foreach(fun(Dot, Token) ->
        validate_dot(Dot, <<"a cloud dot">>),
        case Token of
            [] -> ok;
            _ -> malformed(<<"the cloud is not a set">>)
        end
    end, Cloud);
validate_context(_) ->
    malformed(<<"the context is not {context, Clock, Cloud, Floors}">>).

validate_dot({dot, Replica, Counter}, What) when is_integer(Counter), Counter >= 1 ->
    validate_replica(Replica, What);
validate_dot(_, What) ->
    malformed(<<What/binary, " is not {dot, Replica, Counter >= 1}">>).

validate_replica({replica, Node, Incarnation}, What) when is_integer(Incarnation), Incarnation >= 0 ->
    validate_string(Node, What),
    case Node of
        <<>> -> malformed(<<What/binary, " has an empty node name">>);
        _ -> ok
    end;
validate_replica(_, What) ->
    malformed(<<What/binary, " is not {replica, Node, Incarnation >= 0}">>).

validate_topics(Topics, _ListWhat, What) when is_list(Topics) ->
    lists:foreach(fun(Topic) -> validate_string(Topic, What) end, Topics);
validate_topics(_, ListWhat, _What) ->
    malformed(<<ListWhat/binary, " are not a list">>).

validate_string(Value, What) when is_binary(Value) ->
    case unicode:characters_to_binary(Value) of
        Value -> ok;
        _ -> malformed(<<What/binary, " is not UTF-8">>)
    end;
validate_string(_, What) ->
    malformed(<<What/binary, " is not a string">>).

malformed(Reason) ->
    throw({brazier_malformed_payload, Reason}).

%% --- ETS mirror ---

mirror(#{kind := key_value, table := Table}, Crdt, Changes) ->
    Keys = lists:usort([element(2, Change) || Change <- Changes]),
    lists:foreach(fun(Key) ->
        case ?CRDT:value(Crdt, Key) of
            {ok, Value} -> true = ets:insert(Table, {Key, Value});
            {error, nil} -> true = ets:delete(Table, Key)
        end
    end, Keys);
mirror(#{kind := list, table := Table}, _Crdt, Changes) ->
    lists:foreach(fun
        ({added, Key, Dot, {entry, Value, Ts, _Topics}}) ->
            true = ets:insert(Table, {{Key, Ts, Dot}, Value});
        ({removed, Key, Dot, {entry, _Value, Ts, _Topics}}) ->
            true = ets:delete(Table, {Key, Ts, Dot})
    end, Changes).

%% Tell this node's watchers about remote changes.
announce(S = #{name := Name}, Changes, DeltaTopics) ->
    EntryTopics = [T || {_, _, _, {entry, _, _, Topics}} <- Changes, T <- Topics],
    Topics = lists:usort([<<"store:", Name/binary>> | DeltaTopics ++ EntryTopics]),
    lists:foreach(fun(Topic) ->
        case brazier_pubsub_ffi:local_broadcast(Topic, nil) of
            {ok, nil} ->
                ok;
            {error, Reason} ->
                brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts could not announce a remote change "
                                     "on ~ts: ~p", [label(S), Topic, Reason])
        end
    end, Topics).

%% --- Anti-entropy ---

%% The digest as the 32 bytes a digest message carries. The CRDT keeps it
%% up to date on every join, so this costs O(1) whatever the state's size.
state_digest(#{crdt := Crdt}) ->
    <<(?CRDT:digest(Crdt)):256>>.

schedule_sync(Ms) ->
    _TimerRef = erlang:send_after(Ms, self(), sync_tick),
    ok.

%% --- Helpers ---

publish(S = #{topic := Topic}, Message) ->
    case brazier_pubsub_ffi:broadcast(Topic, Message) of
        {ok, nil} ->
            ok;
        {error, Reason} ->
            %% The digest exchange delivers the change later.
            brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts could not broadcast a ~p: ~p",
                                 [label(S), element(2, Message), Reason]),
            error
    end.

send_direct(S = #{topic := Topic}, Node, Message) ->
    case brazier_pubsub_ffi:direct_broadcast(Node, Topic, Message) of
        {ok, nil} ->
            ok;
        {error, {node_not_connected, _}} ->
            %% Retried by the next digest exchange.
            brazier_log_ffi:warning(<<"brazier.store">>, "Replica ~ts could not send a ~p to ~p: not "
                                   "connected", [label(S), element(2, Message), Node]),
            ok;
        {error, {node_not_verified, _}} ->
            %% The peer lost its membership after its message arrived;
            %% brazier_pubsub_ffi logged the refusal.
            brazier_log_ffi:warning(<<"brazier.store">>, "Replica ~ts did not send a ~p to ~p: not a "
                                   "verified cluster member", [label(S), element(2, Message), Node]),
            ok;
        {error, Reason} ->
            brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts could not send a ~p to ~p: ~p",
                                 [label(S), element(2, Message), Node, Reason]),
            ok
    end.

label(#{name := Name, kind := Kind}) ->
    io_lib:format("~ts (~p)", [Name, Kind]).

format(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

now_ms() -> erlang:system_time(millisecond).
