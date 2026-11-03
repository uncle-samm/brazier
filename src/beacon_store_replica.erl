-module(beacon_store_replica).
-behaviour(gen_server).

%% One replica of a replicated store on this node (beacon/store with mode
%% Replicated). Modelled on Phoenix.Tracker.Shard (see
%% beacon_presence_shard) with the delta-state AWLWWMap of delta_crdt_ex
%% (beacon/store/crdt) as its state.
%%
%% The replica owns its state and mirrors the visible values into a
%% protected named ETS table, so reads never call it:
%%
%%   key-value  set          {Key, Value}            (the last writer's value)
%%   list       ordered_set  {{Key, Ts, Dot}, Value} (every value, HLC order)
%%
%% Writes are calls. A write is applied here, mirrored to ETS, and its delta
%% broadcast at once on beacon_store:<kind>:<name>. Every message is
%% {beacon_store, Kind, FromNode, ...}:
%%
%%   delta     broadcast after every local write: {delta, From, Delta}
%%   digest    broadcast every sync_interval_ms: a hash of the state
%%   sync_req  "send me your full state": broadcast when the replica starts,
%%             sent directly on nodeup and when a peer's digest differs
%%   sync      the reply: the sender's full state
%%
%% Deltas are fire and forget: one lost during a partition (or dropped by an
%% overloaded PubSub forwarder) is repaired by the digest exchange, which
%% pulls a full state from every peer whose state differs. Joins are
%% idempotent, so a delta that arrives twice, late, or after the full state
%% that contained it changes nothing.
%%
%% Every remote merge runs inside the [beacon, store, sync] span and is
%% refused (logged, not merged) when the payload is larger than
%% max_delta_bytes / max_sync_bytes or would grow the replica past
%% max_entries. A refused merge leaves the digests different, so the next
%% exchange retries it, and logs again.
%%
%% Remote changes are announced to this node's watchers by local_broadcast
%% of nil on the store topic, plus the extra topics of every added or
%% removed entry and of the delta. Local writes are announced by the writer
%% (beacon/store), as for a node-local store.

-export([start/3, start_link/1, stop/1, call/2,
         put/3, remove/3, append/4, config/1, digest/1, size/1,
         read_get/2, read_get_all/2, read_count/1, names/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(CRDT, 'beacon@store@crdt').
-define(HLC, 'beacon@store@hlc').
%% Bound on a write call. A replica serves calls between merges, so a call
%% that takes longer than this means the replica is stuck.
-define(CALL_TIMEOUT_MS, 5000).
-define(STOP_TIMEOUT_MS, 10000).
%% A remote timestamp this far ahead of the wall clock is logged: its writes
%% win every LWW comparison until the local clocks catch up.
-define(DRIFT_WARNING_MS, 60000).

%% --- Names ---

%% {Server, Sup, Table, ReplicationTopic} for a store. Name is validated by
%% beacon/store/replicated ([A-Za-z0-9_-], 1 to 200 bytes), and stores are
%% opened with developer-supplied names, so the atoms are bounded.
names(key_value, Name) ->
    names(<<"beacon_rs_">>, <<"beacon_store_">>, <<"kv">>, Name);
names(list, Name) ->
    names(<<"beacon_rls_">>, <<"beacon_ls_">>, <<"list">>, Name).

names(ServerPrefix, TablePrefix, KindBin, Name) ->
    Server = <<ServerPrefix/binary, Name/binary>>,
    {binary_to_atom(Server, utf8),
     binary_to_atom(<<Server/binary, "_sup">>, utf8),
     binary_to_atom(<<TablePrefix/binary, Name/binary>>, utf8),
     <<"beacon_store:", KindBin/binary, ":", Name/binary>>}.

%% --- Lifecycle ---

%% Start the replica of store Name (unlinked from the caller), or return the
%% running one when it was started with the same configuration.
%% Returns {ok, {Server, Table}} | {error, {invalid_config, Reason}} |
%% {error, {start_failed, Reason}} (beacon/store/replicated.StartError).
start(Kind, Name, Config) ->
    {Server, Sup, Table, Topic} = names(Kind, Name),
    case whereis(Server) of
        undefined ->
            case ets:whereis(Table) of
                undefined ->
                    start_sup(Kind, Name, Config, Server, Sup, Table, Topic);
                _ ->
                    beacon_log_ffi:error(<<"beacon.store">>, "Cannot open ~ts as a replicated store: it is "
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
    case beacon_store_sup:start_link(Args) of
        {ok, Pid} ->
            true = unlink(Pid),
            {ok, {Server, Table}};
        {error, {already_started, _}} ->
            %% Another process opened the same store concurrently.
            same_config(Kind, Name, Config, Server, Table);
        {error, Reason} ->
            beacon_log_ffi:error(<<"beacon.store">>, "Replicated store ~ts failed to start: ~p",
                                 [Name, Reason]),
            {error, {start_failed, format(Reason)}}
    end.

same_config(_Kind, Name, Config, Server, Table) ->
    case config(Server) of
        {ok, Config} ->
            {ok, {Server, Table}};
        {ok, Other} ->
            beacon_log_ffi:error(<<"beacon.store">>, "Replicated store ~ts is already open with ~p, "
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
            beacon_log_ffi:info(<<"beacon.store">>, "Stopping ~p", [Server]),
            try proc_lib:stop(Pid, shutdown, ?STOP_TIMEOUT_MS) of
                ok -> {ok, nil}
            catch
                exit:Reason -> {error, format(Reason)}
            end
    end.

sup_of(Server) ->
    binary_to_existing_atom(<<(atom_to_binary(Server, utf8))/binary, "_sup">>, utf8).

%% --- Calls (from beacon/store/replicated) ---

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
            beacon_log_ffi:error(<<"beacon.store">>, "~p did not answer ~p within ~bms",
                                 [Server, request_name(Request), ?CALL_TIMEOUT_MS]),
            {error, {unavailable, <<"replica timeout">>}};
        exit:{noproc, _} ->
            beacon_log_ffi:error(<<"beacon.store">>, "~p is not running", [Server]),
            {error, {unavailable, <<"replica not running">>}};
        exit:Reason ->
            beacon_log_ffi:error(<<"beacon.store">>, "~p exited during a call: ~p", [Server, Reason]),
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
    beacon_log_ffi:error(<<"beacon.store">>, "Table ~p is missing: its replica is not running", [Table]),
    {error, <<"replica not running">>}.

%% --- gen_server ---

init(Args) ->
    process_flag(trap_exit, true),
    #{kind := Kind, name := Name, table := Table, topic := Topic,
      config := {config, Interval, _, _, _, _}} = Args,
    case ets:whereis(Table) of
        undefined ->
            case beacon_pubsub_ffi:subscribe(Topic) of
                {error, Reason} ->
                    beacon_log_ffi:error(<<"beacon.store">>, "Replica ~ts cannot subscribe to ~ts: ~p",
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
                    beacon_log_ffi:info(<<"beacon.store">>, "Replica ~ts started as ~ts",
                                        [Name, ?CRDT:replica_to_string(Replica)]),
                    %% Ask every running replica for its state.
                    publish(S, {beacon_store, sync_req, node()}),
                    {ok, S}
            end;
        _ ->
            beacon_log_ffi:error(<<"beacon.store">>, "Replica ~ts cannot start: table ~p exists",
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
    beacon_log_ffi:warning(<<"beacon.store">>, "Replica ~ts received unexpected call ~p from ~p",
                           [label(S), Request, From]),
    {reply, {error, {unavailable, <<"unexpected request">>}}, S}.

handle_cast(Request, S) ->
    beacon_log_ffi:warning(<<"beacon.store">>, "Replica ~ts received unexpected cast ~p",
                           [label(S), Request]),
    {noreply, S}.

handle_info(sync_tick, S = #{config := {config, Interval, _, _, _, _}}) ->
    {Digest, S1} = state_digest(S),
    publish(S1, {beacon_store, digest, node(), Digest}),
    schedule_sync(Interval),
    {noreply, S1};
handle_info({beacon_pubsub, Topic, Message}, S = #{topic := Topic}) ->
    {noreply, peer_message(Message, S)};
handle_info({nodeup, Node}, S) ->
    beacon_log_ffi:info(<<"beacon.store">>, "Replica ~ts: ~p connected, requesting its state",
                        [label(S), Node]),
    send_direct(S, Node, {beacon_store, sync_req, node()}),
    {noreply, S};
handle_info({nodedown, Node}, S) ->
    beacon_log_ffi:info(<<"beacon.store">>, "Replica ~ts: ~p disconnected", [label(S), Node]),
    {noreply, S};
handle_info({'EXIT', Pid, Reason}, S) ->
    %% The only link besides the parent (handled by gen_server) is the
    %% PubSub partition this replica subscribed through. Without it the
    %% replica no longer hears its peers, so it stops and is restarted.
    beacon_log_ffi:error(<<"beacon.store">>, "Replica ~ts: linked ~p exited (~p); stopping",
                         [label(S), Pid, Reason]),
    {stop, {linked_exit, Reason}, S};
handle_info(Message, S) ->
    beacon_log_ffi:warning(<<"beacon.store">>, "Replica ~ts received unexpected message ~p",
                           [label(S), Message]),
    {noreply, S}.

terminate(Reason, S) ->
    beacon_log_ffi:info(<<"beacon.store">>, "Replica ~ts stopping: ~p", [label(S), Reason]),
    ok.

%% --- Local writes ---

%% Check the values, apply Op, check the delta and the new size, then
%% mirror and broadcast. Nothing changes when a check fails.
local_write(S, OpName, Values, Op) ->
    #{crdt := Crdt, replica := Replica, hlc := Hlc,
      config := {config, _, MaxEntries, MaxValue, MaxDelta, _}} = S,
    case oversized_value(Values, MaxValue) of
        {error, Bytes} ->
            beacon_log_ffi:error(<<"beacon.store">>, "Replica ~ts refused a ~p: a value of ~b bytes "
                                 "exceeds max_value_bytes ~b", [label(S), OpName, Bytes, MaxValue]),
            {reply, {error, {value_too_large, Bytes, MaxValue}}, S};
        ok ->
            {{Crdt1, Delta, Changes}, Hlc1} = Op(Crdt, Replica, Hlc),
            Message = {beacon_store, delta, node(), Delta},
            Bytes = erlang:external_size(Message),
            Size = ?CRDT:size(Crdt1),
            Grows = Size > ?CRDT:size(Crdt),
            if
                Bytes > MaxDelta ->
                    beacon_log_ffi:error(<<"beacon.store">>, "Replica ~ts refused a ~p: its delta of ~b "
                                         "bytes exceeds max_delta_bytes ~b",
                                         [label(S), OpName, Bytes, MaxDelta]),
                    {reply, {error, {delta_too_large, Bytes, MaxDelta}}, S};
                Size > MaxEntries andalso Grows ->
                    beacon_log_ffi:error(<<"beacon.store">>, "Replica ~ts refused a ~p: ~b entries would "
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

peer_message({beacon_store, _Kind, From}, S) when From =:= node() ->
    %% Broadcasts are also delivered to this node, so to this replica.
    S;
peer_message({beacon_store, _Kind, From, _}, S) when From =:= node() ->
    S;
peer_message({beacon_store, delta, From, Delta}, S)
  when is_atom(From), element(1, Delta) =:= delta ->
    #{config := {config, _, _, _, MaxDelta, _}} = S,
    merge(S, From, delta, Delta, MaxDelta, fun ?CRDT:join/2);
peer_message({beacon_store, sync, From, Full}, S)
  when is_atom(From), element(1, Full) =:= delta ->
    #{config := {config, _, _, _, _, MaxSync}} = S,
    beacon_log_ffi:debug(<<"beacon.store">>, "Replica ~ts received the state of ~p", [label(S), From]),
    merge(S, From, sync, Full, MaxSync, fun ?CRDT:join_full/2);
peer_message({beacon_store, digest, From, Digest}, S)
  when is_atom(From), is_binary(Digest) ->
    case state_digest(S) of
        {Digest, S1} ->
            S1;
        {_Other, S1} ->
            beacon_log_ffi:debug(<<"beacon.store">>, "Replica ~ts differs from ~p, requesting its state",
                                 [label(S1), From]),
            send_direct(S1, From, {beacon_store, sync_req, node()}),
            S1
    end;
peer_message({beacon_store, sync_req, From}, S) when is_atom(From) ->
    #{crdt := Crdt, config := {config, _, _, _, _, MaxSync}} = S,
    Message = {beacon_store, sync, node(), ?CRDT:to_delta(Crdt)},
    case erlang:external_size(Message) of
        Bytes when Bytes > MaxSync ->
            beacon_log_ffi:error(<<"beacon.store">>, "Replica ~ts refuses to send its state to ~p: ~b "
                                 "bytes exceed max_sync_bytes ~b", [label(S), From, Bytes, MaxSync]),
            S;
        _ ->
            send_direct(S, From, Message),
            S
    end;
peer_message(Message, S) ->
    beacon_log_ffi:warning(<<"beacon.store">>, "Replica ~ts received an unexpected replication "
                           "message ~P", [label(S), Message, 20]),
    S.

%% Merge a delta or a full state from From inside the sync span.
merge(S = #{name := Name}, From, What, Payload, MaxBytes, Join) ->
    Bytes = erlang:external_size(Payload),
    Entries = ?CRDT:delta_size(Payload),
    beacon_telemetry_ffi:store_sync_span(Name, atom_to_binary(From, utf8), fun() ->
        {checked_merge(S, From, What, Payload, Bytes, MaxBytes, Join), Entries, Bytes}
    end).

checked_merge(S, From, What, _Payload, Bytes, MaxBytes, _Join) when Bytes > MaxBytes ->
    beacon_log_ffi:error(<<"beacon.store">>, "Replica ~ts refused a ~p of ~b bytes from ~p "
                         "(limit ~b bytes)", [label(S), What, Bytes, From, MaxBytes]),
    S;
checked_merge(S, From, What, Payload, _Bytes, _MaxBytes, Join) ->
    #{crdt := Crdt, config := {config, _, MaxEntries, _, _, _}} = S,
    {Crdt1, Changes} = Join(Crdt, Payload),
    Size = ?CRDT:size(Crdt1),
    case Size > MaxEntries andalso Size > ?CRDT:size(Crdt) of
        true ->
            beacon_log_ffi:error(<<"beacon.store">>, "Replica ~ts refused a ~p from ~p: ~b entries would "
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
                    beacon_log_ffi:warning(<<"beacon.store">>, "Replica ~ts: ~p sent a timestamp ~bms ahead "
                                           "of this node's clock; check clock synchronisation",
                                           [label(S), From, Drift]);
                _ ->
                    ok
            end,
            ?HLC:observe(Hlc, Remote, Now)
    end.

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
        case beacon_pubsub_ffi:local_broadcast(Topic, nil) of
            {ok, nil} ->
                ok;
            {error, Reason} ->
                beacon_log_ffi:error(<<"beacon.store">>, "Replica ~ts could not announce a remote change "
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
    case beacon_pubsub_ffi:broadcast(Topic, Message) of
        {ok, nil} ->
            ok;
        {error, Reason} ->
            %% The digest exchange delivers the change later.
            beacon_log_ffi:error(<<"beacon.store">>, "Replica ~ts could not broadcast a ~p: ~p",
                                 [label(S), element(2, Message), Reason]),
            error
    end.

send_direct(S = #{topic := Topic}, Node, Message) ->
    case beacon_pubsub_ffi:direct_broadcast(Node, Topic, Message) of
        {ok, nil} ->
            ok;
        {error, {node_not_connected, _}} ->
            %% Retried by the next digest exchange.
            beacon_log_ffi:warning(<<"beacon.store">>, "Replica ~ts could not send a ~p to ~p: not "
                                   "connected", [label(S), element(2, Message), Node]),
            ok;
        {error, Reason} ->
            beacon_log_ffi:error(<<"beacon.store">>, "Replica ~ts could not send a ~p to ~p: ~p",
                                 [label(S), element(2, Message), Node, Reason]),
            ok
    end.

label(#{name := Name, kind := Kind}) ->
    io_lib:format("~ts (~p)", [Name, Kind]).

format(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

now_ms() -> erlang:system_time(millisecond).
