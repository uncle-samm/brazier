-module(beacon_presence_shard).
-behaviour(gen_server).

%% One presence shard, a port of Phoenix.Tracker.Shard.
%%
%% The shard owns one beacon/presence/state CRDT (replica ref {node(), Vsn})
%% and mirrors the entries that are visible (their replica is up) into a
%% protected ordered_set ETS table, so reads never call the shard:
%%
%%   {{Topic, Key, Pid, Tag}, NodeBin, StoredMeta}
%%
%% Replication runs over Beacon PubSub on beacon_presence:<name>:<index>.
%% Every message is {beacon_presence, Kind, PoolSize, FromRef, ...}:
%%
%%   heartbeat         broadcast every broadcast_period: the delta since the
%%                     last one, or `none` every max_silent_periods
%%   transfer_req      direct to a peer whose clock is ahead of ours, sampled
%%                     every clock_sample_periods heartbeats
%%   transfer_ack      the reply: a delta generation or a snapshot
%%   graceful_permdown broadcast when the shard stops normally
%%
%% A peer is down after down_period without a heartbeat (its entries leave)
%% and permanently down after permdown_period (its data is dropped). A new
%% Vsn from a known node means its shard restarted: the old replica is
%% marked down and permanently down at once.
%%
%% Every change is applied to ETS and reported as a diff
%% {beacon_presence_diff, Name, Topic, Joins, Leaves} by local_broadcast on
%% presence:<name>:<topic>, with entries {Key, Pid, NodeBin, StoredMeta}.
%% The shard is the only sender, so each subscriber sees diffs in order.
%%
%% StoredMeta is the Gleam record beacon/presence.StoredMeta:
%% {stored_meta, Json, Ref, RefPrev}.

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(STATE, 'beacon@presence@state').
-define(DG, 'beacon@presence@delta_generation').
-define(CLOCK, 'beacon@presence@clock').

start_link(Index, Config) ->
    #{shard_names := Names} = Config,
    gen_server:start_link({local, element(Index, Names)}, ?MODULE, {Index, Config}, []).

init({Index, Config}) ->
    process_flag(trap_exit, true),
    #{name := Name, shard_names := Names, shard_topics := Topics,
      broadcast_period := Period, clock_sample_periods := Samples,
      max_silent_periods := MaxSilent} = Config,
    Table = element(Index, Names),
    Topic = element(Index, Topics),
    case beacon_pubsub_ffi:subscribe(Topic) of
        {error, Reason} ->
            logger:error("[beacon.presence] Shard ~ts/~b cannot subscribe to ~ts: ~p",
                         [Name, Index, Topic, Reason]),
            {stop, {pubsub_subscribe_failed, Reason}};
        {ok, nil} ->
            Table = ets:new(Table, [ordered_set, protected, named_table,
                                    {read_concurrency, true}]),
            Vsn = {erlang:system_time(microsecond),
                   erlang:unique_integer([positive, monotonic])},
            Ref = {node(), Vsn},
            %% Up to 25% initial jitter so shards started together do not
            %% heartbeat in lockstep.
            schedule_heartbeat(rand:uniform(max(1, Period div 4))),
            logger:info("[beacon.presence] Shard ~ts/~b started as ~p", [Name, Index, Ref]),
            {ok, #{index => Index,
                   name => Name,
                   config => Config,
                   table => Table,
                   topic => Topic,
                   ref => Ref,
                   pres => ?STATE:new(Ref),
                   deltas => [],
                   pending => [],
                   replicas => #{},
                   silent => MaxSilent,
                   samples => Samples,
                   monitors => #{},
                   mismatched => #{}}}
    end.

%% --- Local tracking ---

handle_call({track, Pid, Topic, Key, Meta}, _From, S) ->
    #{pres := Pres, config := #{max_topics_per_pid := MaxPerPid,
                                max_entries_per_shard := MaxEntries}} = S,
    case ?STATE:get_by_pid_key(Pres, Pid, Topic, Key) of
        {ok, _} ->
            {reply, {error, already_tracked}, S};
        {error, nil} ->
            Count = ?STATE:pid_entry_count(Pres, Pid),
            Size = ?STATE:size(Pres),
            if
                Count >= MaxPerPid ->
                    {reply, limit(S, <<"max_topics_per_pid">>, Pid, Count), S};
                Size >= MaxEntries ->
                    {reply, limit(S, <<"max_entries_per_shard">>, Pid, Size), S};
                true ->
                    %% Not tracked (checked above), so join succeeds.
                    {ok, {Pres1, Element}} = ?STATE:join(Pres, Pid, Topic, Key, Meta),
                    S1 = report(ensure_monitor(S#{pres := Pres1}, Pid), [Element], []),
                    event(S1, track, 1),
                    {reply, {ok, nil}, S1}
            end
    end;
handle_call({update, Pid, Topic, Key, Json, NewRef}, _From, S = #{pres := Pres}) ->
    case ?STATE:get_by_pid_key(Pres, Pid, Topic, Key) of
        {error, nil} ->
            {reply, {error, not_tracked}, S};
        {ok, {element, _, {stored_meta, _, OldRef, _}, _}} ->
            Meta = {stored_meta, Json, NewRef, {some, OldRef}},
            %% Tracked (looked up above), so leave_join succeeds.
            {ok, {Pres1, Previous, New}} = ?STATE:leave_join(Pres, Pid, Topic, Key, Meta),
            {reply, {ok, nil}, report(S#{pres := Pres1}, [New], [Previous])}
    end;
handle_call({untrack, Pid, Topic, Key}, _From, S = #{pres := Pres}) ->
    case ?STATE:leave(Pres, Pid, Topic, Key) of
        {error, nil} ->
            {reply, {error, not_tracked}, S};
        {ok, {Pres1, Element}} ->
            S1 = release_monitor(report(S#{pres := Pres1}, [], [Element]), Pid),
            event(S1, untrack, 1),
            {reply, {ok, nil}, S1}
    end;
handle_call({untrack_all, Pid}, _From, S) ->
    {reply, {ok, nil}, release_monitor(leave_pid(S, Pid), Pid)};
handle_call(replicas, _From, S = #{replicas := Replicas}) ->
    Rows = [{atom_to_binary(Node, utf8), Status}
            || {Node, #{status := Status}} <- lists:sort(maps:to_list(Replicas))],
    {reply, {ok, Rows}, S};
handle_call(Request, From, S) ->
    logger:warning("[beacon.presence] Shard ~ts received unexpected call ~p from ~p",
                   [label(S), Request, From]),
    {reply, {error, unexpected_call}, S}.

handle_cast(Request, S) ->
    logger:warning("[beacon.presence] Shard ~ts received unexpected cast ~p",
                   [label(S), Request]),
    {noreply, S}.

%% --- Messages ---

handle_info(heartbeat, S = #{config := #{broadcast_period := Period}}) ->
    S1 = detect_downs(request_transfers(broadcast_delta_heartbeat(S))),
    schedule_heartbeat(Period),
    {noreply, S1};
handle_info({beacon_pubsub, Topic, Message}, S = #{topic := Topic}) ->
    {noreply, peer_message(Message, S)};
handle_info({'DOWN', MRef, process, Pid, Reason}, S = #{monitors := Monitors}) ->
    case maps:find(Pid, Monitors) of
        {ok, MRef} ->
            logger:debug("[beacon.presence] Shard ~ts: tracked ~p exited (~p)",
                         [label(S), Pid, Reason]),
            {noreply, leave_pid(S#{monitors := maps:remove(Pid, Monitors)}, Pid)};
        _ ->
            logger:warning("[beacon.presence] Shard ~ts received an unknown DOWN for ~p",
                           [label(S), Pid]),
            {noreply, S}
    end;
handle_info({'EXIT', Pid, Reason}, S) ->
    %% The only link besides the parent (handled by gen_server) is the
    %% PubSub partition this shard subscribed through. Without it the shard
    %% no longer hears its peers, so it stops and is restarted.
    logger:error("[beacon.presence] Shard ~ts: linked ~p exited (~p); stopping",
                 [label(S), Pid, Reason]),
    {stop, {linked_exit, Reason}, S};
handle_info(Message, S) ->
    logger:warning("[beacon.presence] Shard ~ts received unexpected message ~p",
                   [label(S), Message]),
    {noreply, S}.

terminate(Reason, S = #{ref := Ref, config := #{pool_size := PoolSize}}) ->
    case graceful(Reason) of
        true ->
            %% Peers drop this replica at once instead of after
            %% permdown_period.
            case publish(S, {beacon_presence, graceful_permdown, PoolSize, Ref}) of
                ok -> ok;
                %% Logged by publish/2; peers then find out after down_period.
                error -> ok
            end;
        false ->
            ok
    end,
    logger:info("[beacon.presence] Shard ~ts stopping: ~p", [label(S), Reason]),
    ok.

graceful(normal) -> true;
graceful(shutdown) -> true;
graceful({shutdown, _}) -> true;
graceful(_) -> false.

%% --- Heartbeats (Phoenix.Tracker.Shard handle_info(:heartbeat)) ---

schedule_heartbeat(Ms) ->
    _TimerRef = erlang:send_after(Ms, self(), heartbeat),
    ok.

broadcast_delta_heartbeat(S) ->
    #{pres := Pres, ref := Ref, silent := Silent,
      config := #{pool_size := PoolSize, max_silent_periods := MaxSilent}} = S,
    case ?STATE:has_delta(Pres) of
        true ->
            Delta = ?STATE:delta(Pres),
            Message = {beacon_presence, heartbeat, PoolSize, Ref, Delta, ?STATE:clocks(Pres)},
            case publish(S, Message) of
                ok ->
                    Pres1 = ?STATE:compact(?STATE:reset_delta(Pres)),
                    push_delta(S#{pres := Pres1, silent := 0}, Delta);
                error ->
                    %% The delta is kept and goes out with the next heartbeat.
                    S
            end;
        false when Silent >= MaxSilent ->
            Message = {beacon_presence, heartbeat, PoolSize, Ref, none, ?STATE:clocks(Pres)},
            case publish(S, Message) of
                ok -> S#{silent := 0};
                error -> S
            end;
        false ->
            S#{silent := Silent + 1}
    end.

%% Ask every peer whose clock this shard has not caught up with for a
%% transfer, once every clock_sample_periods heartbeats.
request_transfers(S = #{samples := 1}) ->
    #{pres := Pres, ref := Ref, pending := Pending,
      config := #{clock_sample_periods := Samples}} = S,
    Clockset = ?CLOCK:append_clock(Pending, ?STATE:clocks(Pres)),
    Targets = [R || R <- gleam@set:to_list(?CLOCK:clockset_replicas(Clockset)), R =/= Ref],
    lists:foreach(fun(Target) -> request_transfer(S, Target) end, Targets),
    S#{pending := [], samples := Samples};
request_transfers(S = #{samples := N}) ->
    S#{samples := N - 1}.

request_transfer(S, {Node, _Vsn} = Target) ->
    #{pres := Pres, ref := Ref, topic := Topic, config := #{pool_size := PoolSize}} = S,
    logger:debug("[beacon.presence] Shard ~ts requests a transfer from ~p",
                 [label(S), Target]),
    Message = {beacon_presence, transfer_req, PoolSize, Ref, ?STATE:clocks(Pres)},
    send_direct(S, Node, Topic, Message).

%% Phoenix.Tracker.Shard detect_downs/1. Strictly longer than the period.
detect_downs(S = #{replicas := Replicas}) ->
    #{config := #{down_period := DownPeriod, permdown_period := PermPeriod}} = S,
    Now = now_ms(),
    maps:fold(fun(Node, #{ref := Ref, last := Last, status := Status}, Acc) ->
        Downtime = Now - Last,
        if
            Downtime > PermPeriod ->
                Acc1 = case Status of
                    up -> down(Acc, Node);
                    down -> Acc
                end,
                forget(permdown(Acc1, Ref), Node);
            Downtime > DownPeriod andalso Status =:= up ->
                down(Acc, Node);
            true ->
                Acc
        end
    end, S, Replicas).

%% --- Peer messages ---

peer_message(Message, S) when is_tuple(Message), tuple_size(Message) >= 4,
                              element(1, Message) =:= beacon_presence ->
    case element(4, Message) of
        {Node, _Vsn} when is_atom(Node) ->
            checked_peer_message(Message, Node, element(3, Message), S);
        _ ->
            unexpected_peer_message(Message, S)
    end;
peer_message(Message, S) ->
    unexpected_peer_message(Message, S).

checked_peer_message(_Message, Node, _PoolSize, S) when Node =:= node() ->
    %% Broadcasts are also delivered to this node, so to this shard.
    S;
checked_peer_message(Message, Node, PoolSize, S = #{config := #{pool_size := PoolSize}}) ->
    handle_peer(Message, Node, S);
checked_peer_message(_Message, Node, PoolSize, S) ->
    #{mismatched := Mismatched, config := #{pool_size := Own}} = S,
    case maps:is_key(Node, Mismatched) of
        true ->
            S;
        false ->
            logger:error("[beacon.presence] Shard ~ts ignores ~p: its pool size is ~p, "
                         "this node's is ~b. Every node must use the same pool size.",
                         [label(S), Node, PoolSize, Own]),
            S#{mismatched := Mismatched#{Node => true}}
    end.

handle_peer({beacon_presence, heartbeat, _, From, none, Clocks}, _Node, S) ->
    handle_heartbeat(put_pending_clock(S, Clocks), From);
handle_peer({beacon_presence, heartbeat, _, From, Delta, Clocks}, _Node, S)
  when element(1, Delta) =:= delta ->
    S1 = merge(handle_heartbeat(S, From), {delta_transfer, Delta}),
    push_delta(put_pending_clock(S1, Clocks), Delta);
handle_peer({beacon_presence, transfer_req, _, From, {_, RemoteContext}}, Node, S) ->
    #{pres := Pres, deltas := Deltas, ref := Ref, topic := Topic,
      config := #{pool_size := PoolSize}} = S,
    Transfer = ?DG:extract(Pres, Deltas, From, RemoteContext),
    logger:debug("[beacon.presence] Shard ~ts sends ~p a ~p of ~b entries",
                 [label(S), From, element(1, Transfer), ?STATE:transfer_size(Transfer)]),
    send_direct(S, Node, Topic, {beacon_presence, transfer_ack, PoolSize, Ref, Transfer}),
    S;
handle_peer({beacon_presence, transfer_ack, _, From, Transfer}, Node, S)
  when element(1, Transfer) =:= delta_transfer; element(1, Transfer) =:= snapshot_transfer ->
    #{name := Name, config := #{max_transfer_entries := Max}} = S,
    Entries = ?STATE:transfer_size(Transfer),
    case Entries > Max of
        true ->
            %% Not merged. The peer's clock stays ahead of ours, so the next
            %% clock sample requests a transfer again.
            logger:error("[beacon.presence] Shard ~ts rejected a transfer of ~b entries "
                         "from ~p (max_transfer_entries ~b)", [label(S), Entries, From, Max]),
            event(S, limit_exceeded, 1),
            S;
        false ->
            S1 = handle_heartbeat(S, From),
            beacon_telemetry_ffi:presence_transfer_span(
                Name, atom_to_binary(Node, utf8),
                fun() -> {merge(S1, Transfer), Entries, erlang:external_size(Transfer)} end)
    end;
handle_peer({beacon_presence, graceful_permdown, _, From}, Node, S = #{replicas := Replicas}) ->
    case maps:find(Node, Replicas) of
        {ok, #{ref := From, status := Status}} ->
            logger:info("[beacon.presence] Shard ~ts: ~p shut down gracefully",
                        [label(S), From]),
            S1 = case Status of
                up -> down(S, Node);
                down -> S
            end,
            forget(permdown(S1, From), Node);
        _ ->
            logger:debug("[beacon.presence] Shard ~ts ignores graceful_permdown of "
                         "unknown replica ~p", [label(S), From]),
            S
    end;
handle_peer(Message, _Node, S) ->
    unexpected_peer_message(Message, S).

unexpected_peer_message(Message, S) ->
    logger:warning("[beacon.presence] Shard ~ts received an unexpected replication "
                   "message ~P", [label(S), Message, 20]),
    S.

put_pending_clock(S = #{pending := Pending}, Clocks) ->
    S#{pending := ?CLOCK:append_clock(Pending, Clocks)}.

push_delta(S = #{pres := Pres, deltas := Deltas, config := #{max_delta_sizes := Sizes}}, Delta) ->
    S#{deltas := ?DG:push(Pres, Deltas, Delta, Sizes)}.

%% --- Replicas (Phoenix.Tracker.Shard handle_heartbeat/up/down/permdown) ---

handle_heartbeat(S = #{replicas := Replicas}, {Node, _Vsn} = From) ->
    Now = now_ms(),
    case maps:find(Node, Replicas) of
        error ->
            up(put_replica(S, Node, From, Now), From);
        {ok, #{ref := From, status := up}} ->
            put_replica(S, Node, From, Now);
        {ok, #{ref := From, status := down}} ->
            up(put_replica(S, Node, From, Now), From);
        {ok, #{ref := Old, status := up}} ->
            %% The node's shard restarted: its old replica is gone for good.
            logger:info("[beacon.presence] Shard ~ts: ~p restarted as ~p",
                        [label(S), Old, From]),
            up(put_replica(permdown(down(S, Node), Old), Node, From, Now), From);
        {ok, #{ref := Old, status := down}} ->
            logger:info("[beacon.presence] Shard ~ts: ~p restarted as ~p",
                        [label(S), Old, From]),
            up(put_replica(permdown(S, Old), Node, From, Now), From)
    end.

put_replica(S = #{replicas := Replicas}, Node, Ref, Now) ->
    S#{replicas := Replicas#{Node => #{ref => Ref, last => Now, status => up}}}.

forget(S = #{replicas := Replicas}, Node) ->
    S#{replicas := maps:remove(Node, Replicas)}.

up(S = #{pres := Pres, name := Name}, Ref) ->
    {Pres1, Joins, Leaves} = ?STATE:replica_up(Pres, Ref),
    logger:info("[beacon.presence] Shard ~ts: replica ~p is up (~b entries)",
                [label(S), Ref, length(Joins)]),
    beacon_telemetry_ffi:presence_replica(replica_up, ref_binary(Ref), Name),
    report(S#{pres := Pres1}, Joins, Leaves).

down(S = #{pres := Pres, name := Name, replicas := Replicas}, Node) ->
    #{Node := Replica = #{ref := Ref}} = Replicas,
    {Pres1, Joins, Leaves} = ?STATE:replica_down(Pres, Ref),
    logger:warning("[beacon.presence] Shard ~ts: replica ~p is down (~b entries hidden)",
                   [label(S), Ref, length(Leaves)]),
    beacon_telemetry_ffi:presence_replica(replica_down, ref_binary(Ref), Name),
    report(S#{pres := Pres1, replicas := Replicas#{Node := Replica#{status := down}}},
           Joins, Leaves).

%% Drop a replica's data. Its entries already left when it went down.
permdown(S = #{pres := Pres, deltas := Deltas, name := Name}, Ref) ->
    logger:info("[beacon.presence] Shard ~ts: replica ~p is permanently down",
                [label(S), Ref]),
    beacon_telemetry_ffi:presence_replica(replica_permdown, ref_binary(Ref), Name),
    S#{pres := ?STATE:remove_down_replicas(Pres, Ref),
       deltas := ?DG:remove_down_replicas(Deltas, Ref)}.

%% Merge a peer's delta or snapshot. Entries of replicas that are not up
%% stay hidden: they are reported when their replica comes up.
merge(S = #{pres := Pres}, Transfer) ->
    {Pres1, Joins, Leaves} = ?STATE:merge(Pres, Transfer),
    Visible = fun({element, _, _, {tag, Ref, _}}) ->
        ?STATE:replica_status(Pres1, Ref) =:= {ok, up}
    end,
    report(S#{pres := Pres1}, lists:filter(Visible, Joins), lists:filter(Visible, Leaves)).

%% --- Local pids ---

leave_pid(S = #{pres := Pres}, Pid) ->
    case ?STATE:leave_pid(Pres, Pid) of
        {_, []} ->
            S;
        {Pres1, Leaves} ->
            S1 = report(S#{pres := Pres1}, [], Leaves),
            event(S1, untrack, length(Leaves)),
            S1
    end.

ensure_monitor(S = #{monitors := Monitors}, Pid) ->
    case maps:is_key(Pid, Monitors) of
        true -> S;
        false -> S#{monitors := Monitors#{Pid => erlang:monitor(process, Pid)}}
    end.

%% Stop monitoring a pid once it tracks nothing on this shard.
release_monitor(S = #{monitors := Monitors, pres := Pres}, Pid) ->
    case maps:find(Pid, Monitors) of
        error ->
            S;
        {ok, MRef} ->
            case ?STATE:pid_entry_count(Pres, Pid) of
                0 ->
                    true = erlang:demonitor(MRef, [flush]),
                    S#{monitors := maps:remove(Pid, Monitors)};
                _ ->
                    S
            end
    end.

limit(S, Limit, Pid, Value) ->
    logger:warning("[beacon.presence] Shard ~ts refused a track by ~p: ~ts reached (~b)",
                   [label(S), Pid, Limit, Value]),
    event(S, limit_exceeded, 1),
    {error, {presence_limit_exceeded, Limit}}.

%% --- ETS and diffs ---

report(S, [], []) ->
    S;
report(S = #{table := Table, name := Name}, Joins, Leaves) ->
    [true = ets:delete(Table, row_key(E)) || E <- Leaves],
    true = ets:insert(Table, [row(E) || E <- Joins]),
    ByTopic = lists:foldl(fun(E, Acc) -> group(E, 2, Acc) end,
                          lists:foldl(fun(E, Acc) -> group(E, 1, Acc) end, #{}, Joins),
                          Leaves),
    maps:foreach(fun(Topic, {TopicJoins, TopicLeaves}) ->
        Diff = {beacon_presence_diff, Name, Topic,
                lists:reverse(TopicJoins), lists:reverse(TopicLeaves)},
        DiffTopic = <<"presence:", Name/binary, ":", Topic/binary>>,
        case beacon_pubsub_ffi:local_broadcast(DiffTopic, Diff) of
            {ok, nil} ->
                ok;
            {error, Reason} ->
                logger:error("[beacon.presence] Shard ~ts could not deliver a diff for "
                             "~ts: ~p", [label(S), Topic, Reason])
        end
    end, ByTopic),
    S.

group(Element = {element, {key, Topic, _, _}, _, _}, Side, Acc) ->
    {J, L} = maps:get(Topic, Acc, {[], []}),
    Entry = diff_entry(Element),
    case Side of
        1 -> Acc#{Topic => {[Entry | J], L}};
        2 -> Acc#{Topic => {J, [Entry | L]}}
    end.

row_key({element, {key, Topic, Pid, Key}, _Meta, Tag}) ->
    {Topic, Key, Pid, Tag}.

row(Element = {element, _, Meta, {tag, Ref, _}}) ->
    {row_key(Element), ref_node(Ref), Meta}.

diff_entry({element, {key, _Topic, Pid, Key}, Meta, {tag, Ref, _}}) ->
    {Key, Pid, ref_node(Ref), Meta}.

ref_node({Node, _Vsn}) -> atom_to_binary(Node, utf8).

ref_binary(Ref) -> unicode:characters_to_binary(io_lib:format("~p", [Ref])).

%% --- Helpers ---

publish(S = #{topic := Topic}, Message) ->
    case beacon_pubsub_ffi:broadcast(Topic, Message) of
        {ok, nil} ->
            ok;
        {error, Reason} ->
            logger:error("[beacon.presence] Shard ~ts could not broadcast ~p: ~p",
                         [label(S), element(2, Message), Reason]),
            error
    end.

send_direct(S, Node, Topic, Message) ->
    case beacon_pubsub_ffi:direct_broadcast(Node, Topic, Message) of
        {ok, nil} ->
            ok;
        {error, {node_not_connected, _}} ->
            logger:warning("[beacon.presence] Shard ~ts could not send ~p to ~p: not "
                           "connected", [label(S), element(2, Message), Node]),
            ok;
        {error, Reason} ->
            logger:error("[beacon.presence] Shard ~ts could not send ~p to ~p: ~p",
                         [label(S), element(2, Message), Node, Reason]),
            ok
    end.

event(#{name := Name, index := Index}, Kind, Count) ->
    beacon_telemetry_ffi:presence_event(Kind, Count, Name, Index).

label(#{name := Name, index := Index}) ->
    io_lib:format("~ts/~b", [Name, Index]).

now_ms() -> erlang:monotonic_time(millisecond).
