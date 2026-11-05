-module(brazier_presence_shard).
-behaviour(gen_server).

%% One presence shard, a port of Phoenix.Tracker.Shard.
%%
%% The shard owns one brazier/presence/state CRDT (replica ref {node(), Vsn})
%% and mirrors the entries that are visible (their replica is up) into a
%% protected ordered_set ETS table, so reads never call the shard:
%%
%%   {{Topic, Key, Pid, Tag}, Meta}
%%
%% Meta is the meta as readers return it, the Gleam record
%% brazier/presence/sync.Meta {meta, Value, Ref, RefPrev, NodeBin}, as
%% Phoenix.Tracker.State keeps the meta term in its values table. A local
%% track brings its value, decoded by the caller when it checked the meta;
%% an entry from a peer is decoded here once, when it becomes visible. A
%% meta that does not decode is stored as {undecodable, NodeBin, Reason}
%% (logged here) and fails every read that would return it. The table's
%% one other row, {{brazier_presence_decoder, Fingerprint}}, tells readers
%% which decoder made the values (brazier_presence_ffi:fingerprint/1).
%%
%% The CRDT and replication keep the meta as JSON
%% (brazier/presence.StoredMeta {stored_meta, Json, Ref, RefPrev}), so what
%% crosses nodes does not depend on how a node stores its values.
%%
%% Replication runs over Brazier PubSub on brazier_presence:<name>:<index>,
%% between cluster members only: PubSub forwards only to and from nodes that
%% passed the cluster peer check, and a message whose replica ref names a
%% node that is not a verified member is dropped and logged here as well.
%% Every message is {brazier_presence, Kind, PoolSize, FromRef, ...}:
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
%% {brazier_presence_diff, Name, Fingerprint, Topic, Joins, Leaves} by
%% local_broadcast on presence:<name>:<topic>, with entries {Key, Pid, Meta}
%% holding the Meta of the entry's row. The shard is the only sender, so
%% each subscriber sees diffs in order.
%%
%% Sync waiters. A shard that restarts starts empty and learns every other
%% node's entries from that node (its heartbeat marks it up, the transfer
%% at the next clock sample carries its entries). A process that read this
%% shard can ask when that is done for some nodes by sending
%%
%%   {brazier_presence_await_sync, Pid, [NodeBin]}
%%
%% and gets {brazier_presence_synced, ShardPid, NodeBin, Status} once per
%% node, after the diffs of everything the shard learnt before:
%%
%%   synced   the node is up and this shard holds every entry the node had
%%            issued when it last heartbeat (its own clock is covered)
%%   down     the node's replica is down: its entries are hidden
%%   absent   the shard has not heard from the node for down_period since
%%            it started, the rule that marks a known node down
%%   timeout  none of these within down_period of the request (logged)
%%
%% Session presence watchers use it so that entries of other nodes do not
%% leave and join again while a restarted shard catches up (Phoenix's
%% replica up and state transfer, with the reader told when they are done).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(STATE, 'brazier@presence@state').
-define(DG, 'brazier@presence@delta_generation').
-define(CLOCK, 'brazier@presence@clock').

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
    case brazier_pubsub_ffi:subscribe(Topic) of
        {error, Reason} ->
            brazier_log_ffi:error(<<"brazier.presence">>, "Shard ~ts/~b cannot subscribe to ~ts: ~p",
                                 [Name, Index, Topic, Reason]),
            {stop, {pubsub_subscribe_failed, Reason}};
        {ok, nil} ->
            Table = ets:new(Table, [ordered_set, protected, named_table,
                                    {read_concurrency, true}]),
            true = ets:insert(Table, maps:get(fingerprint_row, Config)),
            Vsn = {erlang:system_time(microsecond),
                   erlang:unique_integer([positive, monotonic])},
            Ref = {node(), Vsn},
            %% Up to 25% initial jitter so shards started together do not
            %% heartbeat in lockstep.
            schedule_heartbeat(rand:uniform(max(1, Period div 4))),
            brazier_log_ffi:info(<<"brazier.presence">>, "Shard ~ts/~b started as ~p", [Name, Index, Ref]),
            {ok, #{index => Index,
                   name => Name,
                   config => Config,
                   %% Of the decoder the table's values are decoded with.
                   fingerprint => maps:get(fingerprint, Config),
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
                   mismatched => #{},
                   started => now_ms(),
                   %% Replica ref => its own clock value in its last heartbeat.
                   heard => #{},
                   %% NodeBin => [{Pid, DeadlineMs}] (see Sync waiters).
                   waiters => #{}}}
    end.

%% --- Local tracking ---

handle_call({track, _Pid, _Topic, _Key, _Stored, _Value, Fingerprint}, {Caller, _}, S = #{fingerprint := Own})
  when Fingerprint =/= Own ->
    {reply, fingerprint_mismatch(S, Caller), S};
handle_call({track, Pid, Topic, Key, Stored, Value, _Fingerprint}, _From, S) ->
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
                    {ok, {Pres1, Element}} = ?STATE:join(Pres, Pid, Topic, Key, Stored),
                    S1 = report(ensure_monitor(S#{pres := Pres1}, Pid),
                                [{Element, local_meta(Stored, Value)}], []),
                    event(S1, track, 1),
                    {reply, {ok, nil}, S1}
            end
    end;
handle_call({update, _Pid, _Topic, _Key, _Json, _NewRef, _Value, Fingerprint}, {Caller, _},
            S = #{fingerprint := Own}) when Fingerprint =/= Own ->
    {reply, fingerprint_mismatch(S, Caller), S};
handle_call({update, Pid, Topic, Key, Json, NewRef, Value, _Fingerprint}, _From,
            S = #{pres := Pres}) ->
    case ?STATE:get_by_pid_key(Pres, Pid, Topic, Key) of
        {error, nil} ->
            {reply, {error, not_tracked}, S};
        {ok, {element, _, {stored_meta, _, OldRef, _}, _}} ->
            Stored = {stored_meta, Json, NewRef, {some, OldRef}},
            %% Tracked (looked up above), so leave_join succeeds.
            {ok, {Pres1, Previous, New}} = ?STATE:leave_join(Pres, Pid, Topic, Key, Stored),
            {reply, {ok, nil}, report(S#{pres := Pres1},
                                      [{New, local_meta(Stored, Value)}], [Previous])}
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
    brazier_log_ffi:warning(<<"brazier.presence">>, "Shard ~ts received unexpected call ~p from ~p",
                           [label(S), Request, From]),
    {reply, {error, unexpected_call}, S}.

handle_cast(Request, S) ->
    brazier_log_ffi:warning(<<"brazier.presence">>, "Shard ~ts received unexpected cast ~p",
                           [label(S), Request]),
    {noreply, S}.

%% --- Messages ---

handle_info(heartbeat, S = #{config := #{broadcast_period := Period}}) ->
    S1 = detect_downs(request_transfers(broadcast_delta_heartbeat(S))),
    schedule_heartbeat(Period),
    {noreply, notify_waiters(S1)};
handle_info({brazier_pubsub, Topic, Message}, S = #{topic := Topic}) ->
    {noreply, notify_waiters(peer_message(Message, S))};
handle_info({brazier_presence_await_sync, Pid, Nodes}, S) when is_pid(Pid), is_list(Nodes) ->
    case lists:all(fun is_binary/1, Nodes) of
        true ->
            {noreply, await_sync(S, Pid, lists:usort(Nodes))};
        false ->
            brazier_log_ffi:warning(<<"brazier.presence">>, "Shard ~ts received an await_sync from ~p "
                                   "with non-binary nodes ~p", [label(S), Pid, Nodes]),
            {noreply, S}
    end;
handle_info({'DOWN', MRef, process, Pid, Reason}, S = #{monitors := Monitors}) ->
    case maps:find(Pid, Monitors) of
        {ok, MRef} ->
            brazier_log_ffi:debug(<<"brazier.presence">>, "Shard ~ts: tracked ~p exited (~p)",
                                 [label(S), Pid, Reason]),
            {noreply, leave_pid(S#{monitors := maps:remove(Pid, Monitors)}, Pid)};
        _ ->
            brazier_log_ffi:warning(<<"brazier.presence">>, "Shard ~ts received an unknown DOWN for ~p",
                                   [label(S), Pid]),
            {noreply, S}
    end;
handle_info({'EXIT', Pid, Reason}, S) ->
    %% The only link besides the parent (handled by gen_server) is the
    %% PubSub partition this shard subscribed through. Without it the shard
    %% no longer hears its peers, so it stops and is restarted.
    brazier_log_ffi:error(<<"brazier.presence">>, "Shard ~ts: linked ~p exited (~p); stopping",
                         [label(S), Pid, Reason]),
    {stop, {linked_exit, Reason}, S};
handle_info(Message, S) ->
    brazier_log_ffi:warning(<<"brazier.presence">>, "Shard ~ts received unexpected message ~p",
                           [label(S), Message]),
    {noreply, S}.

terminate(Reason, S = #{ref := Ref, config := #{pool_size := PoolSize}}) ->
    case graceful(Reason) of
        true ->
            %% Peers drop this replica at once instead of after
            %% permdown_period.
            case publish(S, {brazier_presence, graceful_permdown, PoolSize, Ref}) of
                ok -> ok;
                %% Logged by publish/2; peers then find out after down_period.
                error -> ok
            end;
        false ->
            ok
    end,
    brazier_log_ffi:info(<<"brazier.presence">>, "Shard ~ts stopping: ~p", [label(S), Reason]),
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
            Message = {brazier_presence, heartbeat, PoolSize, Ref, Delta, ?STATE:clocks(Pres)},
            case publish(S, Message) of
                ok ->
                    Pres1 = ?STATE:compact(?STATE:reset_delta(Pres)),
                    push_delta(S#{pres := Pres1, silent := 0}, Delta);
                error ->
                    %% The delta is kept and goes out with the next heartbeat.
                    S
            end;
        false when Silent >= MaxSilent ->
            Message = {brazier_presence, heartbeat, PoolSize, Ref, none, ?STATE:clocks(Pres)},
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
    brazier_log_ffi:debug(<<"brazier.presence">>, "Shard ~ts requests a transfer from ~p",
                         [label(S), Target]),
    Message = {brazier_presence, transfer_req, PoolSize, Ref, ?STATE:clocks(Pres)},
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
                              element(1, Message) =:= brazier_presence ->
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
checked_peer_message(Message, Node, PoolSize, S) ->
    case brazier_cluster_ffi:verified(Node) of
        true ->
            member_peer_message(Message, Node, PoolSize, S);
        false ->
            %% PubSub already drops forwards from unverified nodes; this
            %% check also covers the replica ref a member could put in one.
            brazier_log_ffi:warning(<<"brazier.presence">>, "Shard ~ts dropped a ~0P from ~p: not a verified "
                                   "cluster member", [label(S), element(2, Message), 5, Node]),
            S
    end.

member_peer_message(Message, Node, PoolSize, S = #{config := #{pool_size := PoolSize}}) ->
    handle_peer(Message, Node, S);
member_peer_message(_Message, Node, PoolSize, S) ->
    #{mismatched := Mismatched, config := #{pool_size := Own}} = S,
    case maps:is_key(Node, Mismatched) of
        true ->
            S;
        false ->
            brazier_log_ffi:error(<<"brazier.presence">>, "Shard ~ts ignores ~p: its pool size is ~p, "
                                 "this node's is ~b. Every node must use the same pool size.",
                                 [label(S), Node, PoolSize, Own]),
            S#{mismatched := Mismatched#{Node => true}}
    end.

handle_peer({brazier_presence, heartbeat, _, From, none, Clocks}, _Node, S) ->
    put_heard(handle_heartbeat(put_pending_clock(S, Clocks), From), From, Clocks);
handle_peer({brazier_presence, heartbeat, _, From, Delta, Clocks}, _Node, S)
  when element(1, Delta) =:= delta ->
    S1 = merge(handle_heartbeat(S, From), {delta_transfer, Delta}),
    put_heard(push_delta(put_pending_clock(S1, Clocks), Delta), From, Clocks);
handle_peer({brazier_presence, transfer_req, _, From, {_, RemoteContext}}, Node, S) ->
    #{pres := Pres, deltas := Deltas, ref := Ref, topic := Topic,
      config := #{pool_size := PoolSize}} = S,
    Transfer = ?DG:extract(Pres, Deltas, From, RemoteContext),
    brazier_log_ffi:debug(<<"brazier.presence">>, "Shard ~ts sends ~p a ~p of ~b entries",
                         [label(S), From, element(1, Transfer), ?STATE:transfer_size(Transfer)]),
    send_direct(S, Node, Topic, {brazier_presence, transfer_ack, PoolSize, Ref, Transfer}),
    S;
handle_peer({brazier_presence, transfer_ack, _, From, Transfer}, Node, S)
  when element(1, Transfer) =:= delta_transfer; element(1, Transfer) =:= snapshot_transfer ->
    #{name := Name, config := #{max_transfer_entries := Max}} = S,
    Entries = ?STATE:transfer_size(Transfer),
    case Entries > Max of
        true ->
            %% Not merged. The peer's clock stays ahead of ours, so the next
            %% clock sample requests a transfer again.
            brazier_log_ffi:error(<<"brazier.presence">>, "Shard ~ts rejected a transfer of ~b entries "
                                 "from ~p (max_transfer_entries ~b)", [label(S), Entries, From, Max]),
            event(S, limit_exceeded, 1),
            S;
        false ->
            S1 = handle_heartbeat(S, From),
            brazier_telemetry_ffi:presence_transfer_span(
                Name, atom_to_binary(Node, utf8),
                fun() -> {merge(S1, Transfer), Entries, erlang:external_size(Transfer)} end)
    end;
handle_peer({brazier_presence, graceful_permdown, _, From}, Node, S = #{replicas := Replicas}) ->
    case maps:find(Node, Replicas) of
        {ok, #{ref := From, status := Status}} ->
            brazier_log_ffi:info(<<"brazier.presence">>, "Shard ~ts: ~p shut down gracefully",
                                [label(S), From]),
            S1 = case Status of
                up -> down(S, Node);
                down -> S
            end,
            forget(permdown(S1, From), Node);
        _ ->
            brazier_log_ffi:debug(<<"brazier.presence">>, "Shard ~ts ignores graceful_permdown of "
                                 "unknown replica ~p", [label(S), From]),
            S
    end;
handle_peer(Message, _Node, S) ->
    unexpected_peer_message(Message, S).

unexpected_peer_message(Message, S) ->
    brazier_log_ffi:warning(<<"brazier.presence">>, "Shard ~ts received an unexpected replication "
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
            brazier_log_ffi:info(<<"brazier.presence">>, "Shard ~ts: ~p restarted as ~p",
                                [label(S), Old, From]),
            up(put_replica(permdown(down(S, Node), Old), Node, From, Now), From);
        {ok, #{ref := Old, status := down}} ->
            brazier_log_ffi:info(<<"brazier.presence">>, "Shard ~ts: ~p restarted as ~p",
                                [label(S), Old, From]),
            up(put_replica(permdown(S, Old), Node, From, Now), From)
    end.

put_replica(S = #{replicas := Replicas}, Node, Ref, Now) ->
    S#{replicas := Replicas#{Node => #{ref => Ref, last => Now, status => up}}}.

forget(S = #{replicas := Replicas}, Node) ->
    S#{replicas := maps:remove(Node, Replicas)}.

up(S = #{pres := Pres, name := Name}, Ref) ->
    {Pres1, Joins, Leaves} = ?STATE:replica_up(Pres, Ref),
    brazier_log_ffi:info(<<"brazier.presence">>, "Shard ~ts: replica ~p is up (~b entries)",
                        [label(S), Ref, length(Joins)]),
    brazier_telemetry_ffi:presence_replica(replica_up, ref_binary(Ref), Name),
    report(S#{pres := Pres1}, decoded(S, Joins), Leaves).

down(S = #{pres := Pres, name := Name, replicas := Replicas}, Node) ->
    #{Node := Replica = #{ref := Ref}} = Replicas,
    {Pres1, Joins, Leaves} = ?STATE:replica_down(Pres, Ref),
    brazier_log_ffi:warning(<<"brazier.presence">>, "Shard ~ts: replica ~p is down (~b entries hidden)",
                           [label(S), Ref, length(Leaves)]),
    brazier_telemetry_ffi:presence_replica(replica_down, ref_binary(Ref), Name),
    report(S#{pres := Pres1, replicas := Replicas#{Node := Replica#{status := down}}},
           decoded(S, Joins), Leaves).

%% Drop a replica's data. Its entries already left when it went down.
permdown(S = #{pres := Pres, deltas := Deltas, name := Name, heard := Heard}, Ref) ->
    brazier_log_ffi:info(<<"brazier.presence">>, "Shard ~ts: replica ~p is permanently down",
                        [label(S), Ref]),
    brazier_telemetry_ffi:presence_replica(replica_permdown, ref_binary(Ref), Name),
    S#{pres := ?STATE:remove_down_replicas(Pres, Ref),
       deltas := ?DG:remove_down_replicas(Deltas, Ref),
       heard := maps:remove(Ref, Heard)}.

%% Merge a peer's delta or snapshot. Entries of replicas that are not up
%% stay hidden: they are reported when their replica comes up.
merge(S = #{pres := Pres}, Transfer) ->
    {Pres1, Joins, Leaves} = ?STATE:merge(Pres, Transfer),
    Visible = fun({element, _, _, {tag, Ref, _}}) ->
        ?STATE:replica_status(Pres1, Ref) =:= {ok, up}
    end,
    report(S#{pres := Pres1}, decoded(S, lists:filter(Visible, Joins)),
           lists:filter(Visible, Leaves)).

%% --- Sync waiters (see the module doc) ---

%% Remember the sender's own clock value from its heartbeat clocks.
put_heard(S = #{heard := Heard}, From, {From, Context}) when is_map(Context) ->
    S#{heard := Heard#{From => maps:get(From, Context, 0)}};
put_heard(S, From, Clocks) ->
    %% ?STATE:clocks/1 is {OwnRef, Context}, so a peer running this module
    %% never sends this. Nothing is recorded: waiters for the node time out.
    brazier_log_ffi:error(<<"brazier.presence">>, "Shard ~ts: heartbeat of ~p carries clocks ~P "
                         "that are not its own; not recording them", [label(S), From, Clocks, 10]),
    S.

await_sync(S, Pid, Nodes) ->
    #{waiters := Waiters, config := #{down_period := DownPeriod}} = S,
    Now = now_ms(),
    Deadline = Now + DownPeriod,
    Waiters1 = lists:foldl(fun(NodeBin, Acc) ->
        case resolution(S, NodeBin, Now) of
            waiting ->
                Acc#{NodeBin => [{Pid, Deadline} | maps:get(NodeBin, Acc, [])]};
            Status ->
                synced(S, Pid, NodeBin, Status),
                Acc
        end
    end, Waiters, Nodes),
    brazier_log_ffi:debug(<<"brazier.presence">>, "Shard ~ts: ~p waits for sync with ~p",
                         [label(S), Pid, Nodes]),
    S#{waiters := Waiters1}.

%% Answer every waiter whose node is resolved or whose deadline passed.
notify_waiters(S = #{waiters := Waiters}) when map_size(Waiters) =:= 0 ->
    S;
notify_waiters(S = #{waiters := Waiters}) ->
    Now = now_ms(),
    Waiters1 = maps:fold(fun(NodeBin, Pids, Acc) ->
        case resolution(S, NodeBin, Now) of
            waiting ->
                {Expired, Kept} = lists:partition(fun({_, Deadline}) -> Now > Deadline end, Pids),
                [timed_out(S, Pid, NodeBin) || {Pid, _} <- Expired],
                case Kept of
                    [] -> Acc;
                    _ -> Acc#{NodeBin => Kept}
                end;
            Status ->
                brazier_log_ffi:info(<<"brazier.presence">>, "Shard ~ts: sync with ~ts is ~p, "
                                    "telling ~b waiters", [label(S), NodeBin, Status, length(Pids)]),
                [synced(S, Pid, NodeBin, Status) || {Pid, _} <- Pids],
                Acc
        end
    end, #{}, Waiters),
    S#{waiters := Waiters1}.

timed_out(S, Pid, NodeBin) ->
    brazier_log_ffi:warning(<<"brazier.presence">>, "Shard ~ts did not sync with ~ts within "
                           "down_period; telling ~p its entries are not here", [label(S), NodeBin, Pid]),
    synced(S, Pid, NodeBin, timeout).

synced(_S, Pid, NodeBin, Status) ->
    Pid ! {brazier_presence_synced, self(), NodeBin, Status},
    ok.

%% Where this shard stands with the node named NodeBin.
resolution(S, NodeBin, Now) ->
    #{replicas := Replicas, pres := Pres, heard := Heard, started := Started,
      config := #{down_period := DownPeriod}} = S,
    Found = [Replica || {Node, Replica} <- maps:to_list(Replicas),
                        atom_to_binary(Node, utf8) =:= NodeBin],
    case Found of
        [#{status := down}] ->
            down;
        [#{status := up, ref := Ref}] ->
            Issued = maps:get(Ref, Heard, 0),
            Held = maps:get(Ref, ?STATE:context(Pres), 0),
            case Held >= Issued of
                true -> synced;
                false -> waiting
            end;
        [] when Now - Started > DownPeriod ->
            absent;
        [] ->
            waiting
    end.

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
    brazier_log_ffi:warning(<<"brazier.presence">>, "Shard ~ts refused a track by ~p: ~ts reached (~b)",
                           [label(S), Pid, Limit, Value]),
    event(S, limit_exceeded, 1),
    {error, {presence_limit_exceeded, Limit}}.

%% --- ETS and diffs ---

%% Joins are {Element, Meta}: the meta its row holds (local_meta/2 or
%% decoded/2). Leaves are elements: their rows are taken, so a leave
%% reports the meta its join stored.
report(S, [], []) ->
    S;
report(S = #{table := Table, name := Name, fingerprint := Fingerprint}, Joins, Leaves) ->
    Left = [take_row(S, E) || E <- Leaves],
    true = ets:insert(Table, [{row_key(E), Meta} || {E, Meta} <- Joins]),
    ByTopic = lists:foldl(fun(Row, Acc) -> group(Row, 2, Acc) end,
                          lists:foldl(fun(Row, Acc) -> group(Row, 1, Acc) end, #{}, Joins),
                          Left),
    maps:foreach(fun(Topic, {TopicJoins, TopicLeaves}) ->
        Diff = {brazier_presence_diff, Name, Fingerprint, Topic,
                lists:reverse(TopicJoins), lists:reverse(TopicLeaves)},
        DiffTopic = <<"presence:", Name/binary, ":", Topic/binary>>,
        case brazier_pubsub_ffi:local_broadcast(DiffTopic, Diff) of
            {ok, nil} ->
                ok;
            {error, Reason} ->
                brazier_log_ffi:error(<<"brazier.presence">>, "Shard ~ts could not deliver a diff for "
                                     "~ts: ~p", [label(S), Topic, Reason])
        end
    end, ByTopic),
    S.

group({{element, {key, Topic, Pid, Key}, _, _}, Meta}, Side, Acc) ->
    {J, L} = maps:get(Topic, Acc, {[], []}),
    Entry = {Key, Pid, Meta},
    case Side of
        1 -> Acc#{Topic => {[Entry | J], L}};
        2 -> Acc#{Topic => {J, [Entry | L]}}
    end.

%% Remove the row of an element that leaves and return it with its meta.
%% The table mirrors the visible entries of the CRDT, and the CRDT reports
%% a leave only for an entry it reported joining, so the row is there. If it
%% is not, the table no longer mirrors the CRDT: crash, and the supervisor
%% restarts the shard with an empty table that peers fill again.
take_row(S = #{table := Table}, Element = {element, {key, Topic, Pid, Key}, _, _}) ->
    RowKey = row_key(Element),
    case ets:take(Table, RowKey) of
        [{RowKey, Meta}] ->
            {Element, Meta};
        Found ->
            brazier_log_ffi:error(<<"brazier.presence">>, "Shard ~ts: the entry ~ts of ~p on ~ts "
                                 "leaves but its table row is ~P", [label(S), Key, Pid, Topic, Found, 10]),
            erlang:error({presence_table_out_of_sync, RowKey})
    end.

row_key({element, {key, Topic, Pid, Key}, _Meta, Tag}) ->
    {Topic, Key, Pid, Tag}.

%% The meta of a local track or update: the caller decoded its JSON with
%% the tracker's decoder when it checked it (presence.encode_meta), and the
%% request's fingerprint says it used this shard's decoder.
local_meta({stored_meta, _Json, Ref, RefPrev}, Value) ->
    {meta, Value, Ref, RefPrev, atom_to_binary(node(), utf8)}.

%% Entries that became visible from a peer, decoded once for their rows.
decoded(S, Elements) ->
    [{E, decode_meta(S, E)} || E <- Elements].

decode_meta(S = #{config := #{decoder := Decoder}},
            {element, {key, Topic, _Pid, Key}, Stored, {tag, Ref, _}}) ->
    Node = ref_node(Ref),
    case Stored of
        {stored_meta, Json, MetaRef, RefPrev} when is_binary(Json), is_binary(MetaRef) ->
            case valid_ref_prev(RefPrev) of
                true ->
                    parse_meta(S, Topic, Key, Node, Decoder, Json, MetaRef, RefPrev);
                false ->
                    undecodable(S, Topic, Key, Node,
                                format("its previous ref ~P is not an Option(String)", [RefPrev, 10]))
            end;
        _ ->
            undecodable(S, Topic, Key, Node, format("~P is not a stored meta", [Stored, 10]))
    end.

parse_meta(S, Topic, Key, Node, Decoder, Json, MetaRef, RefPrev) ->
    try 'gleam@json':parse(Json, Decoder) of
        {ok, Value} ->
            {meta, Value, MetaRef, RefPrev, Node};
        {error, Error} ->
            undecodable(S, Topic, Key, Node, 'gleam@string':inspect(Error))
    catch
        Class:Reason:Stack ->
            %% The decoder is the application's code; it must not take the
            %% shard, and every entry on it, down with it.
            brazier_log_ffi:error(<<"brazier.presence">>, "Shard ~ts: the decoder crashed on the meta "
                                 "of ~ts from ~ts: ~p:~P ~P",
                                 [label(S), Key, Node, Class, Reason, 20, Stack, 20]),
            undecodable(S, Topic, Key, Node, format("the decoder crashed: ~p:~P", [Class, Reason, 20]))
    end.

valid_ref_prev(none) -> true;
valid_ref_prev({some, Ref}) -> is_binary(Ref);
valid_ref_prev(_) -> false.

%% A peer's meta that this node's decoder cannot read. The row keeps the
%% reason, and every read that would return the entry fails with it
%% (brazier_presence_ffi), as the reads did when they decoded each row.
undecodable(S, Topic, Key, Node, Reason) ->
    brazier_log_ffi:error(<<"brazier.presence">>, "Shard ~ts cannot decode the meta of ~ts on ~ts "
                         "from ~ts: ~ts", [label(S), Key, Topic, Node, Reason]),
    {undecodable, Node, Reason}.

%% A track or update from a handle built with another decoder: its value is
%% not what this shard's readers expect.
fingerprint_mismatch(S = #{name := Name}, Pid) ->
    brazier_log_ffi:error(<<"brazier.presence">>, "Shard ~ts refused a request from ~p: its handle's "
                         "decoder is not the decoder the tracker was started with", [label(S), Pid]),
    {error, {meta_decode_failed, <<"the handle's decoder is not the decoder tracker ", Name/binary,
                                   " was started with">>}}.

ref_node({Node, _Vsn}) -> atom_to_binary(Node, utf8).

format(Format, Args) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).

ref_binary(Ref) -> unicode:characters_to_binary(io_lib:format("~p", [Ref])).

%% --- Helpers ---

publish(S = #{topic := Topic}, Message) ->
    case brazier_pubsub_ffi:broadcast(Topic, Message) of
        {ok, nil} ->
            ok;
        {error, Reason} ->
            brazier_log_ffi:error(<<"brazier.presence">>, "Shard ~ts could not broadcast ~p: ~p",
                                 [label(S), element(2, Message), Reason]),
            error
    end.

send_direct(S, Node, Topic, Message) ->
    case brazier_pubsub_ffi:direct_broadcast(Node, Topic, Message) of
        {ok, nil} ->
            ok;
        {error, {node_not_connected, _}} ->
            brazier_log_ffi:warning(<<"brazier.presence">>, "Shard ~ts could not send ~p to ~p: not "
                                   "connected", [label(S), element(2, Message), Node]),
            ok;
        {error, {node_not_verified, _}} ->
            %% The peer lost its membership after its message arrived.
            brazier_log_ffi:warning(<<"brazier.presence">>, "Shard ~ts did not send ~p to ~p: not a "
                                   "verified cluster member", [label(S), element(2, Message), Node]),
            ok;
        {error, Reason} ->
            brazier_log_ffi:error(<<"brazier.presence">>, "Shard ~ts could not send ~p to ~p: ~p",
                                 [label(S), element(2, Message), Node, Reason]),
            ok
    end.

event(#{name := Name, index := Index}, Kind, Count) ->
    brazier_telemetry_ffi:presence_event(Kind, Count, Name, Index).

label(#{name := Name, index := Index}) ->
    io_lib:format("~ts/~b", [Name, Index]).

now_ms() -> erlang:monotonic_time(millisecond).
