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
%%   digest    broadcast every sync_interval_ms: a hash of the state
%%   sync_req  "send me your full state": broadcast when the replica starts,
%%             sent directly once a connected node passes the cluster peer
%%             check (brazier_cluster_ffi:await_verified/1) and when a
%%             peer's digest differs
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
%% grow the replica past max_entries. A refused merge leaves the digests
%% different, so the next exchange retries it, and logs again.
%%
%% A peer's payload is checked field by field before anything reads it:
%% the CRDT functions assume the shapes brazier/store/crdt builds, so a
%% malformed term from a member (another version, a bug, a hand-sent
%% message) would crash the replica, or worse be joined and break
%% convergence on every node it reaches. Phoenix.Tracker likewise matches
%% the exact shape of every replica message before merging it.
%%
%% Remote changes are announced to this node's watchers by local_broadcast
%% of nil on the store topic, plus the extra topics of every added or
%% removed entry and of the delta. Local writes are announced by the writer
%% (brazier/store), as for a node-local store.

-export([start/3, start_link/1, stop/1, call/2,
         put/3, remove/3, append/4, config/1, digest/1, size/1,
         read_get/2, read_get_all/2, read_count/1, names/2,
         check_payload/2]).
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
                    ok = net_kernel:monitor_nodes(true),
                    NodeBin = atom_to_binary(node(), utf8),
                    Replica = {replica, NodeBin, erlang:system_time(microsecond)},
                    S = Args#{replica => Replica,
                              node_bin => NodeBin,
                              crdt => ?CRDT:new(),
                              hlc => ?HLC:zero(NodeBin),
                              digest => undefined},
                    %% Up to one interval of initial jitter so replicas
                    %% started together do not exchange digests in lockstep.
                    schedule_sync(rand:uniform(max(1, Interval))),
                    brazier_log_ffi:info(<<"brazier.store">>, "Replica ~ts started as ~ts",
                                        [Name, ?CRDT:replica_to_string(Replica)]),
                    %% Ask every running replica for its state.
                    publish(S, {brazier_store, sync_req, node()}),
                    {ok, S}
            end;
        _ ->
            brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts cannot start: table ~p exists",
                                 [Name, Table]),
            {stop, {table_exists, Table}}
    end.

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
    {Digest, S1} = state_digest(S),
    {reply, {ok, Digest}, S1};
handle_call(size, _From, S = #{crdt := Crdt}) ->
    {reply, {ok, ?CRDT:size(Crdt)}, S};
handle_call(Request, From, S) ->
    brazier_log_ffi:warning(<<"brazier.store">>, "Replica ~ts received unexpected call ~p from ~p",
                           [label(S), Request, From]),
    {reply, {error, {unavailable, <<"unexpected request">>}}, S}.

handle_cast(Request, S) ->
    brazier_log_ffi:warning(<<"brazier.store">>, "Replica ~ts received unexpected cast ~p",
                           [label(S), Request]),
    {noreply, S}.

handle_info(sync_tick, S = #{config := {config, Interval, _, _, _, _}}) ->
    {Digest, S1} = state_digest(S),
    publish(S1, {brazier_store, digest, node(), Digest}),
    schedule_sync(Interval),
    {noreply, S1};
handle_info({brazier_pubsub, Topic, Message}, S = #{topic := Topic}) ->
    {noreply, peer_message(Message, S)};
handle_info({nodeup, Node}, S) ->
    %% A connected node is not yet a cluster member: the state is requested
    %% once the cluster manager has verified it (brazier_cluster_peer_verified).
    case brazier_cluster_ffi:await_verified(Node) of
        {ok, nil} ->
            brazier_log_ffi:info(<<"brazier.store">>, "Replica ~ts: ~p connected, awaiting its peer check",
                                [label(S), Node]);
        {error, not_started} ->
            brazier_log_ffi:warning(<<"brazier.store">>, "Replica ~ts: ~p connected, but no cluster manager "
                                   "runs here, so it is not replicated to", [label(S), Node])
    end,
    {noreply, S};
handle_info({brazier_cluster_peer_verified, Node}, S) ->
    brazier_log_ffi:info(<<"brazier.store">>, "Replica ~ts: ~p is a verified cluster member, requesting "
                        "its state", [label(S), Node]),
    send_direct(S, Node, {brazier_store, sync_req, node()}),
    {noreply, S};
handle_info({nodedown, Node}, S) ->
    brazier_log_ffi:info(<<"brazier.store">>, "Replica ~ts: ~p disconnected", [label(S), Node]),
    {noreply, S};
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
                    {reply, {ok, nil}, S#{crdt := Crdt1, hlc := Hlc1, digest := undefined}}
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
    merge(S, From, delta, Delta, MaxDelta, fun ?CRDT:join/2);
member_message({brazier_store, sync, From, Full}, S) when is_atom(From) ->
    #{config := {config, _, _, _, _, MaxSync}} = S,
    brazier_log_ffi:debug(<<"brazier.store">>, "Replica ~ts received the state of ~p", [label(S), From]),
    merge(S, From, sync, Full, MaxSync, fun ?CRDT:join_full/2);
member_message({brazier_store, digest, From, Digest}, S)
  when is_atom(From), is_binary(Digest) ->
    case state_digest(S) of
        {Digest, S1} ->
            S1;
        {_Other, S1} ->
            brazier_log_ffi:debug(<<"brazier.store">>, "Replica ~ts differs from ~p, requesting its state",
                                 [label(S1), From]),
            send_direct(S1, From, {brazier_store, sync_req, node()}),
            S1
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

%% Merge a delta or a full state from From inside the sync span. A
%% malformed payload is refused before anything reads it: its entries are
%% reported as 0, since they cannot be counted.
merge(S = #{name := Name}, From, What, Payload, MaxBytes, Join) ->
    Bytes = erlang:external_size(Payload),
    Peer = atom_to_binary(From, utf8),
    case check_payload(What, Payload) of
        {error, Reason} ->
            brazier_telemetry_ffi:store_sync_span(Name, Peer, fun() ->
                brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts refused a malformed ~p of ~b "
                                     "bytes from ~p: ~ts", [label(S), What, Bytes, From, Reason]),
                {S, 0, Bytes}
            end);
        {ok, nil} ->
            Entries = ?CRDT:delta_size(Payload),
            brazier_telemetry_ffi:store_sync_span(Name, Peer, fun() ->
                {checked_merge(S, From, What, Payload, Bytes, MaxBytes, Join), Entries, Bytes}
            end)
    end.

checked_merge(S, From, What, _Payload, Bytes, MaxBytes, _Join) when Bytes > MaxBytes ->
    brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts refused a ~p of ~b bytes from ~p "
                         "(limit ~b bytes)", [label(S), What, Bytes, From, MaxBytes]),
    S;
checked_merge(S, From, What, Payload, _Bytes, _MaxBytes, Join) ->
    #{crdt := Crdt, config := {config, _, MaxEntries, _, _, _}} = S,
    {Crdt1, Changes} = Join(Crdt, Payload),
    Size = ?CRDT:size(Crdt1),
    case Size > MaxEntries andalso Size > ?CRDT:size(Crdt) of
        true ->
            brazier_log_ffi:error(<<"brazier.store">>, "Replica ~ts refused a ~p from ~p: ~b entries would "
                                 "exceed max_entries ~b", [label(S), What, From, Size, MaxEntries]),
            S;
        false ->
            S1 = S#{crdt := Crdt1, digest := undefined, hlc := advance_clock(S, From, Payload)},
            case Changes of
                [] ->
                    S1;
                _ ->
                    mirror(S1, Crdt1, Changes),
                    announce(S1, Changes, element(4, Payload)),
                    S1
            end
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
%%   Context  {context, #{Replica => Max}, Cloud} Max >= 1, Cloud a set of Dot
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

validate_context({context, Clock, {set, Cloud}}) when is_map(Clock), is_map(Cloud) ->
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
    malformed(<<"the context is not {context, Clock, Cloud}">>).

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

state_digest(S = #{digest := Digest}) when is_binary(Digest) ->
    {Digest, S};
state_digest(S = #{crdt := Crdt}) ->
    Canonical = term_to_binary(?CRDT:fingerprint(Crdt), [deterministic, {minor_version, 2}]),
    Digest = crypto:hash(sha256, Canonical),
    {Digest, S#{digest := Digest}}.

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
