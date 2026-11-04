-module(brazier_cluster_manager).
-behaviour(gen_server).

%% The Brazier cluster manager: node discovery, reconnection with backoff,
%% node up/down reporting and the peer secret check.
%%
%% Discovery follows libcluster's Epmd (static list) and DNSPoll strategies:
%%   {static, Nodes}            connect to each node, retrying a failed or
%%                              lost connection with exponential backoff and
%%                              jitter (initial doubling to max).
%%   {dns, Query, Base, PollMs} every PollMs resolve Query (A + AAAA, or the
%%                              injected resolver) and connect to Base@Addr
%%                              for each address not yet connected. Only
%%                              IP addresses become node names, and at most
%%                              max_discovered_nodes new names are ever made
%%                              on one VM (node names are atoms).
%%   no_discovery               only report and check nodes that connect.
%%
%% Connection attempts and DNS lookups run in short-lived monitored
%% processes (net_kernel:connect_node/1 can block for net_setuptime), so the
%% manager itself never blocks. At most one attempt per target is in flight.
%%
%% Peer check: on nodeup (and at init, for nodes already connected) each
%% side sends
%%   {brazier_cluster_hello, FromNode, ?PROTOCOL_VERSION, Mac}
%% to {brazier_cluster, Node}, where Mac = HMAC-SHA256(secret_key,
%% "brazier-cluster-v1"). A manager that accepts a hello answers with
%%   {brazier_cluster_hello_ack, FromNode, ?PROTOCOL_VERSION, Mac}
%% which is checked the same way but not answered. The ack covers a hello
%% sent before the other side's manager was running (it is dropped), and a
%% manager restarted while its peers stayed connected (they see no nodeup).
%% A peer whose Mac or version differs, or that sends neither a hello nor
%% an ack within the check timeout, is rejected: error log,
%% [brazier, cluster, peer, rejected], and it is not (or no longer) a
%% member. It stays connected: the manager never disconnects a node (see
%% "Why a rejected peer stays connected" below). Anyone with the cookie can
%% already run code on this node, so this guards against misconfiguration
%% (two deployments sharing a cookie), not an attacker.
%%
%% Verified peers are listed in the protected table brazier_cluster_members
%% so members/0 and verified/1 read them without a call. The table is the
%% cluster's membership: PubSub, replicated stores, presence and session
%% revocation send only to verified nodes and drop what unverified nodes
%% send (brazier_cluster_ffi:verified/1). A node is verified per
%% connection: its row is removed when it is rejected or goes down, and a
%% reconnect is checked again. A rejected node's later hello or ack is
%% checked again too (its manager may have started late).
%%
%% Processes that sync with a peer when it joins (store replicas, session
%% maintenance) call brazier_cluster_ffi:await_verified/1 on nodeup and get
%% {brazier_cluster_peer_verified, Node} once the node passes the check,
%% instead of syncing on nodeup (Phoenix.Tracker replicates only with
%% replicas it has heard from). The interest is one-shot, kept while the
%% node stays connected (a rejected node may still pass later) and dropped
%% when it goes down: a node that never passes is never synced with.
%%
%% Why a rejected peer stays connected. Under OTP's default
%% kernel prevent_overlapping_partitions=true, global treats every lost
%% connection as a partition to close. When this node drops Node,
%% global:handle_nodedown/3 here (global.erl, OTP 28) sees a plain
%% `disconnected` and calls inform_connection_loss/2, which multicasts
%% {lost_connection, node(), _, _, Node} to every other node it knows.
%% Each receiver R (handle_info({lost_connection, ...}), ibid.) relays it,
%% sends {remove_connection, R} to Node and drops Node itself, and Node
%% then disconnects R (handle_info({remove_connection, ...})). Nothing checks who reported the loss:
%% when an intruder b rejects the verified members a and c and
%% disconnects a, b's global tells c "b lost a", and c and a cut their own
%% connection. With no discovery nothing reconnects them, so one
%% misconfigured node partitions the deployment it was refused from. A
%% plain-OTP mesh of three nodes where one calls erlang:disconnect_node/1
%% ends with all three apart. OTP's own answer is that only
%% global:disconnect/0, run on the node that leaves, removes a node
%% without that cascade; a node cannot make another one run it. So
%% rejection is a membership decision, not a connection one, as in OTP 25's
%% global_group (disconnect_nodes/1 no longer calls
%% erlang:disconnect_node/1; the node is just excluded) and in Mnesia,
%% which ignores connected nodes outside db_nodes. The connection carries
%% only what membership lets through, which is nothing from Brazier.
%%
%% Timers carry their reference ({timeout, TRef, {peer_check, Node}} from
%% erlang:start_timer/3), and the peer check timeout acts only when it is
%% the timer of the node's current pending check: a timer of an earlier
%% connection that fired as the node reconnected is stale and ignored.

-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, format_status/1, backoff_window/3]).

-define(NAME, brazier_cluster).
-define(MEMBERS, brazier_cluster_members).
-define(PROTOCOL_VERSION, 1).
%% Exponent cap, so 2^attempt stays small; max_ms bounds the delay anyway.
-define(MAX_EXPONENT, 30).
%% The VM-wide count of node-name atoms DNS discovery created (atoms are
%% never freed, so the count only grows, across manager restarts).
-define(DNS_ATOMS, {brazier_cluster, dns_node_atoms}).
%% The longest address text a DNS answer may hold (an IPv6 address with
%% an IPv4 tail is 45 characters).
-define(MAX_ADDRESS_BYTES, 64).
%% format_status/1 scrubs this deep; anything deeper is replaced whole.
-define(REDACT_DEPTH, 64).

start_link(Config) ->
    gen_server:start_link({local, ?NAME}, ?MODULE, Config, []).

%% The delay window for a retry after Attempt failures (0-based): the
%% exponential delay D = min(Max, Initial * 2^Attempt), and the retry runs
%% at a uniformly random point in [D div 2, D] ("equal jitter"), so nodes
%% restarted together do not retry in lockstep.
backoff_window(Attempt, InitialMs, MaxMs) ->
    Exponent = min(Attempt, ?MAX_EXPONENT),
    Delay = min(MaxMs, InitialMs bsl Exponent),
    {Delay div 2, Delay}.

%% --- gen_server ---

init(Config = #{discovery := Discovery}) ->
    process_flag(trap_exit, true),
    ?MEMBERS = ets:new(?MEMBERS, [set, protected, named_table, {read_concurrency, true}]),
    ok = net_kernel:monitor_nodes(true, [nodedown_reason]),
    State0 = Config#{
        %% Node => #{attempts := N, timer := TRef | none, inflight := Ref | none}
        targets => #{},
        %% Node => {pending, TRef} | verified | rejected, for connected
        %% nodes only (removed on nodedown).
        peers => #{},
        %% MonitorRef => {connect, Node} | {resolve, Pid, TimeoutRef}
        jobs => #{},
        %% Node => [Pid]: live local processes told when Node passes the
        %% check. Only connected nodes have interests; they are dropped
        %% when the node is verified or goes down, and dead waiters are
        %% pruned on every new wait, so a node that stays rejected holds at
        %% most one entry per live process.
        interests => #{},
        dns_atoms => dns_atom_counter()
    },
    brazier_log_ffi:info(<<"brazier.cluster">>, "Cluster manager started on ~p (~ts)",
                        [node(), describe_discovery(Discovery)]),
    %% Nodes connected before the manager started send no nodeup.
    Connected = nodes(),
    Connected =/= [] andalso
        brazier_log_ffi:info(<<"brazier.cluster">>, "Checking ~b already-connected nodes: ~p",
                            [length(Connected), Connected]),
    State1 = lists:foldl(fun peer_up/2, State0, Connected),
    {ok, start_discovery(Discovery, State1)}.

handle_call(Request, From, State) ->
    brazier_log_ffi:warning(<<"brazier.cluster">>, "Unexpected call ~p from ~p", [Request, From]),
    {reply, {error, unknown_call}, State}.

%% Waiters are local (brazier_cluster_ffi:await_verified/1 sends self()):
%% pruning them uses is_process_alive/1, which takes local pids only, so a
%% remote one falls through to the unexpected-cast warning.
handle_cast({await_verified, Node, Pid}, State) when is_atom(Node), is_pid(Pid),
                                                     node(Pid) =:= node() ->
    {noreply, await_verified(Node, Pid, State)};
handle_cast(Request, State) ->
    brazier_log_ffi:warning(<<"brazier.cluster">>, "Unexpected cast ~0P", [Request, 10]),
    {noreply, State}.

handle_info({nodeup, Node, _Info}, State) ->
    brazier_log_ffi:info(<<"brazier.cluster">>, "Node up: ~p", [Node]),
    ok = brazier_telemetry_ffi:cluster_node(node_up, atom_to_binary(Node), <<"connected">>),
    {noreply, peer_up(Node, State)};
handle_info({nodedown, Node, Info}, State) ->
    Reason = format(proplists:get_value(nodedown_reason, Info, unknown)),
    brazier_log_ffi:warning(<<"brazier.cluster">>, "Node down: ~p (~ts)", [Node, Reason]),
    ok = brazier_telemetry_ffi:cluster_node(node_down, atom_to_binary(Node), Reason),
    {noreply, retry_target(Node, peer_down(Node, State))};
handle_info({brazier_cluster_hello, Node, Version, Mac}, State)
        when is_atom(Node), is_integer(Version), is_binary(Mac) ->
    case connected_peer(brazier_cluster_hello, Node) andalso check(Node, Version, Mac, State) of
        false ->
            {noreply, State};
        {verified, State1 = #{mac := Own}} ->
            {?NAME, Node} ! {brazier_cluster_hello_ack, node(), ?PROTOCOL_VERSION, Own},
            {noreply, State1};
        {rejected, State1} ->
            {noreply, State1}
    end;
handle_info({brazier_cluster_hello_ack, Node, Version, Mac}, State)
        when is_atom(Node), is_integer(Version), is_binary(Mac) ->
    case connected_peer(brazier_cluster_hello_ack, Node) andalso check(Node, Version, Mac, State) of
        false -> {noreply, State};
        {_, State1} -> {noreply, State1}
    end;
handle_info(Message, State) when is_tuple(Message), tuple_size(Message) >= 1,
                                 (element(1, Message) =:= brazier_cluster_hello orelse
                                  element(1, Message) =:= brazier_cluster_hello_ack) ->
    %% Never logged as a whole: a malformed hello may still carry a MAC.
    From = case tuple_size(Message) >= 2 andalso element(2, Message) of
               Node when is_atom(Node), Node =/= false -> Node;
               _ -> unknown
           end,
    brazier_log_ffi:warning(<<"brazier.cluster">>, "Dropping a malformed ~p (~b elements) from ~p",
                           [element(1, Message), tuple_size(Message), From]),
    {noreply, State};
handle_info({timeout, TRef, {peer_check, Node}}, State = #{peers := Peers}) ->
    case maps:get(Node, Peers, none) of
        {pending, TRef} ->
            {noreply, reject(Node, <<"no hello within the peer check timeout">>, State)};
        Current ->
            %% The timer of an earlier connection of Node (it went down and
            %% came back, or was verified, as the timer fired): the current
            %% connection has its own timer, or needs none.
            brazier_log_ffi:debug(<<"brazier.cluster">>, "Ignoring a stale peer check timer for ~p (~p)",
                                 [Node, peer_status(Current)]),
            {noreply, State}
    end;
handle_info({connect, Node}, State) ->
    {noreply, start_connect(Node, clear_timer(Node, State))};
handle_info(poll, State) ->
    {noreply, start_resolve(State)};
handle_info({resolve_timeout, Ref}, State = #{jobs := Jobs}) ->
    case maps:take(Ref, Jobs) of
        {{resolve, Pid, _}, Rest} ->
            true = erlang:demonitor(Ref, [flush]),
            true = exit(Pid, kill),
            {noreply, resolve_failed(<<"timed out">>, State#{jobs := Rest})};
        error ->
            %% The lookup finished as the timer fired; DOWN handled it.
            {noreply, State}
    end;
handle_info({'DOWN', Ref, process, _Pid, Result}, State = #{jobs := Jobs}) ->
    case maps:take(Ref, Jobs) of
        {Job, Rest} -> {noreply, job_done(Job, Result, State#{jobs := Rest})};
        error ->
            brazier_log_ffi:warning(<<"brazier.cluster">>, "DOWN for unknown job ~p: ~p", [Ref, Result]),
            {noreply, State}
    end;
handle_info(Message, State) ->
    brazier_log_ffi:warning(<<"brazier.cluster">>, "Unexpected message ~0P", [Message, 10]),
    {noreply, State}.

%% The MAC is the HMAC of the secret key: never print it. gen_server calls
%% this for sys:get_status/1 and for its crash report, whose last message,
%% reason (a stack's arguments hold the state) and sys log may each carry
%% the own MAC or a peer's (in a hello), so every value is scrubbed.
format_status(Status) ->
    Own = case Status of
              #{state := #{mac := Mac}} -> Mac;
              _ -> none
          end,
    maps:map(fun(_Key, Value) -> redact(Value, Own, ?REDACT_DEPTH) end, Status).

redact(_Term, _Own, 0) ->
    redacted;
redact(Own, Own, _Depth) when is_binary(Own) ->
    redacted;
redact(Map, Own, Depth) when is_map(Map) ->
    maps:map(fun
        (mac, _Mac) -> redacted;
        (_Key, Value) -> redact(Value, Own, Depth - 1)
    end, Map);
redact({Tag, Node, Version, _Mac}, _Own, _Depth) when Tag =:= brazier_cluster_hello;
                                                     Tag =:= brazier_cluster_hello_ack ->
    {Tag, Node, Version, redacted};
redact(Tuple, _Own, _Depth) when tuple_size(Tuple) >= 1,
                                 (element(1, Tuple) =:= brazier_cluster_hello orelse
                                  element(1, Tuple) =:= brazier_cluster_hello_ack) ->
    {element(1, Tuple), redacted};
redact(Tuple, Own, Depth) when is_tuple(Tuple) ->
    list_to_tuple([redact(E, Own, Depth - 1) || E <- tuple_to_list(Tuple)]);
redact(List, Own, Depth) when is_list(List) ->
    redact_list(List, Own, Depth);
redact(Term, _Own, _Depth) ->
    Term.

%% Element by element, so an improper list keeps its tail.
redact_list([], _Own, _Depth) -> [];
redact_list([Head | Tail], Own, Depth) -> [redact(Head, Own, Depth - 1) | redact_list(Tail, Own, Depth)];
redact_list(Tail, Own, Depth) -> redact(Tail, Own, Depth - 1).

terminate(Reason, #{jobs := Jobs}) ->
    brazier_log_ffi:info(<<"brazier.cluster">>, "Cluster manager stopping: ~p", [Reason]),
    %% A resolver may hang (that is what its timeout is for); do not leave
    %% it behind. Connect attempts end within net_setuptime on their own.
    [true = exit(Pid, kill) || {resolve, Pid, _} <- maps:values(Jobs)],
    ok.

%% --- Peer check ---

peer_up(Node, State = #{peers := Peers, mac := Mac, check_timeout_ms := Timeout}) ->
    {?NAME, Node} ! {brazier_cluster_hello, node(), ?PROTOCOL_VERSION, Mac},
    case maps:get(Node, Peers, none) of
        verified ->
            %% Its hello arrived before our nodeup.
            State;
        rejected ->
            %% Its hello arrived before our nodeup and failed; the hello
            %% just sent lets its manager check us, and a later hello from
            %% it is checked again. No timer: it was already judged.
            brazier_log_ffi:debug(<<"brazier.cluster">>, "Node up for ~p, already rejected on this "
                                 "connection", [Node]),
            State;
        {pending, Old} ->
            %% A node that connected between monitor_nodes/2 and nodes()
            %% in init is checked twice; the newer timer replaces the old.
            cancel(Old),
            TRef = erlang:start_timer(Timeout, self(), {peer_check, Node}),
            State#{peers := Peers#{Node => {pending, TRef}}};
        none ->
            TRef = erlang:start_timer(Timeout, self(), {peer_check, Node}),
            State#{peers := Peers#{Node => {pending, TRef}}}
    end.

peer_down(Node, State = #{peers := Peers}) ->
    State1 = drop_interests(Node, State),
    case maps:take(Node, Peers) of
        {{pending, TRef}, Rest} ->
            cancel(TRef),
            State1#{peers := Rest};
        {verified, Rest} ->
            true = ets:delete(?MEMBERS, Node),
            State1#{peers := Rest};
        {rejected, Rest} ->
            brazier_log_ffi:info(<<"brazier.cluster">>, "Rejected peer ~p went down", [Node]),
            State1#{peers := Rest};
        error ->
            State1
    end.

peer_status(verified) -> verified;
peer_status(rejected) -> rejected;
peer_status({pending, _}) -> pending_newer_check;
peer_status(none) -> not_connected.

%% The member table and the peers map agree on Node: a row exactly when
%% the node is verified. Checked after every transition that touches both.
assert_membership(Node, #{peers := Peers}) ->
    Verified = maps:get(Node, Peers, none) =:= verified,
    Verified = ets:member(?MEMBERS, Node),
    ok.

%% A hello or ack names its sender; one from a node that is not connected
%% (a forged FromNode, or a message that outlived its connection) must not
%% create a member row.
connected_peer(Tag, Node) ->
    case lists:member(Node, nodes()) of
        true ->
            true;
        false ->
            brazier_log_ffi:warning(<<"brazier.cluster">>, "Dropping a ~p naming ~p, which is not connected",
                                   [Tag, Node]),
            false
    end.

%% --- Verified-peer interests ---

await_verified(Node, Pid, State = #{peers := Peers, interests := Interests}) ->
    case maps:get(Node, Peers, none) of
        verified ->
            Pid ! {brazier_cluster_peer_verified, Node},
            State;
        _ ->
            case lists:member(Node, nodes()) of
                true ->
                    %% Pending, rejected (it may still pass on a later
                    %% hello), or connected and its nodeup not yet handled
                    %% here (the caller saw its own nodeup first). A
                    %% rejected node can stay connected indefinitely, so
                    %% waiters that died meanwhile are pruned here.
                    Live = [P || P <- maps:get(Node, Interests, []), is_process_alive(P)],
                    Waiting = case lists:member(Pid, Live) of
                                  true -> Live;
                                  false -> [Pid | Live]
                              end,
                    brazier_log_ffi:debug(<<"brazier.cluster">>, "~p waits for ~p to be verified (~p, ~b "
                                         "waiting)", [Pid, Node, peer_status(maps:get(Node, Peers, none)),
                                                      length(Waiting)]),
                    State#{interests := Interests#{Node => Waiting}};
                false ->
                    brazier_log_ffi:debug(<<"brazier.cluster">>, "Not waiting for ~p for ~p: it is not "
                                         "connected", [Node, Pid]),
                    State
            end
    end.

notify_verified(Node, State = #{interests := Interests}) ->
    case maps:take(Node, Interests) of
        {Waiting, Rest} ->
            [Pid ! {brazier_cluster_peer_verified, Node} || Pid <- Waiting],
            brazier_log_ffi:debug(<<"brazier.cluster">>, "Told ~b processes that ~p is verified",
                                 [length(Waiting), Node]),
            State#{interests := Rest};
        error ->
            State
    end.

drop_interests(Node, State = #{interests := Interests}) ->
    case maps:take(Node, Interests) of
        {Waiting, Rest} ->
            brazier_log_ffi:debug(<<"brazier.cluster">>, "Dropping ~b waits for ~p: it went down "
                                 "unverified", [length(Waiting), Node]),
            State#{interests := Rest};
        error ->
            State
    end.

check(Node, ?PROTOCOL_VERSION, TheirMac, State = #{mac := Mac, peers := Peers})
        when is_binary(TheirMac) ->
    case crypto:hash_equals(pad(TheirMac, byte_size(Mac)), Mac)
         andalso byte_size(TheirMac) =:= byte_size(Mac) of
        true ->
            Previous = maps:get(Node, Peers, none),
            case Previous of
                {pending, TRef} -> cancel(TRef);
                _ -> ok
            end,
            true = ets:insert(?MEMBERS, {Node, erlang:system_time(millisecond)}),
            brazier_log_ffi:info(<<"brazier.cluster">>, "Peer verified: ~p (was ~p)",
                                [Node, peer_status(Previous)]),
            State1 = reset_attempts(Node, State#{peers := Peers#{Node => verified}}),
            ok = assert_membership(Node, State1),
            {verified, notify_verified(Node, State1)};
        false ->
            {rejected, reject(Node, <<"secret key mismatch">>, State)}
    end;
check(Node, Version, _Mac, State) ->
    Reason = format({protocol_version_mismatch, Version, ?PROTOCOL_VERSION}),
    {rejected, reject(Node, Reason, State)}.

%% hash_equals/2 needs equal sizes; compare a padded copy and check the
%% size separately so a short Mac cannot crash the manager.
pad(Bin, Size) when byte_size(Bin) >= Size -> binary:part(Bin, 0, Size);
pad(Bin, Size) -> <<Bin/binary, 0:((Size - byte_size(Bin)) * 8)>>.

%% Rejection removes Node from the membership and leaves its connection
%% alone. Disconnecting it here would make global, under the default
%% prevent_overlapping_partitions, tell every other node that this node
%% lost Node, and they would disconnect from each other in turn (see the
%% module comment). Node stays connected until it goes down; its waiters
%% are kept, since a later hello may still verify it.
reject(Node, Reason, State = #{peers := Peers}) ->
    Previous = maps:get(Node, Peers, none),
    brazier_log_ffi:error(<<"brazier.cluster">>, "Rejecting peer ~p (was ~p): ~ts; it is not a member "
                         "and stays connected, take it out of this cluster with "
                         "global:disconnect() run on it", [Node, peer_status(Previous), Reason]),
    ok = brazier_telemetry_ffi:cluster_peer_rejected(atom_to_binary(Node), Reason),
    case Previous of
        {pending, TRef} -> cancel(TRef);
        _ -> ok
    end,
    %% A verified node that now fails (another hello on the same
    %% connection) loses its membership; for any other state there is no
    %% row and the delete does nothing.
    true = ets:delete(?MEMBERS, Node),
    State1 = State#{peers := Peers#{Node => rejected}},
    ok = assert_membership(Node, State1),
    State1.

%% --- Discovery ---

start_discovery({static, Nodes}, State) ->
    Targets = maps:from_list([{N, new_target()} || N <- Nodes, N =/= node()]),
    State1 = State#{targets := Targets},
    lists:foldl(fun(N, S) ->
                        case lists:member(N, nodes()) of
                            true -> S;
                            false -> start_connect(N, S)
                        end
                end, State1, maps:keys(Targets));
start_discovery({dns, _Query, _Base, _PollMs}, State) ->
    self() ! poll,
    State;
start_discovery(no_discovery, State) ->
    State.

new_target() -> #{attempts => 0, timer => none, inflight => none}.

start_connect(Node, State = #{targets := Targets, jobs := Jobs}) ->
    Target = maps:get(Node, Targets, new_target()),
    case Target of
        #{inflight := none} ->
            {_Pid, Ref} = spawn_monitor(fun() -> exit({connected, net_kernel:connect_node(Node)}) end),
            State#{targets := Targets#{Node => Target#{inflight := Ref}},
                   jobs := Jobs#{Ref => {connect, Node}}};
        #{inflight := _} ->
            State
    end.

start_resolve(State = #{discovery := {dns, Query, _, _}, resolver := Resolve,
                         resolve_timeout_ms := Timeout, jobs := Jobs}) ->
    {Pid, Ref} = spawn_monitor(fun() -> exit({resolved, Resolve(Query)}) end),
    TRef = erlang:send_after(Timeout, self(), {resolve_timeout, Ref}),
    State#{jobs := Jobs#{Ref => {resolve, Pid, TRef}}}.

job_done({connect, Node}, Result, State) ->
    State1 = finish_connect(Node, State),
    case Result of
        {connected, true} ->
            brazier_log_ffi:debug(<<"brazier.cluster">>, "Connected to ~p", [Node]),
            State1;
        {connected, false} ->
            connect_failed(Node, <<"unreachable">>, State1);
        {connected, ignored} ->
            %% Only when this node is not distributed, which start refuses.
            connect_failed(Node, <<"distribution is not started">>, State1);
        Other ->
            connect_failed(Node, format(Other), State1)
    end;
job_done({resolve, _Pid, TRef}, Result, State = #{discovery := {dns, Query, Base, _}}) ->
    cancel(TRef),
    case Result of
        {resolved, {ok, Addresses}} when is_list(Addresses) ->
            schedule_poll(connect_discovered(Query, Base, Addresses, State));
        {resolved, {error, Reason}} when is_binary(Reason) ->
            resolve_failed(Reason, State);
        Other ->
            resolve_failed(format({resolver_crashed, Other}), State)
    end.

resolve_failed(Reason, State = #{discovery := {dns, Query, _, PollMs}}) ->
    brazier_log_ffi:error(<<"brazier.cluster">>, "DNS lookup of ~ts failed: ~ts; retrying in ~bms",
                         [Query, Reason, PollMs]),
    ok = brazier_telemetry_ffi:cluster_connect_failed(Query, <<"dns: ", Reason/binary>>),
    schedule_poll(State).

schedule_poll(State = #{discovery := {dns, _, _, PollMs}}) ->
    erlang:send_after(PollMs, self(), poll),
    State.

connect_discovered(Query, Base, Addresses, State = #{max_dns_nodes := Max}) ->
    Unique = lists:usort(Addresses),
    case length(Unique) =< Max of
        false ->
            Reason = format({too_many_addresses, length(Unique), Max}),
            brazier_log_ffi:error(<<"brazier.cluster">>, "DNS lookup of ~ts returned ~b addresses, more "
                                 "than max_dns_nodes (~b); connecting to none of them",
                                 [Query, length(Unique), Max]),
            ok = brazier_telemetry_ffi:cluster_connect_failed(Query, Reason),
            State;
        true ->
            {Valid, Invalid} = canonical_addresses(Unique),
            ok = report_invalid(Query, Invalid),
            {Nodes, Refused} = node_atoms(Base, lists:usort(Valid), State),
            ok = report_refused(Query, Refused, State),
            Connected = nodes(),
            brazier_log_ffi:debug(<<"brazier.cluster">>, "DNS ~ts -> ~p", [Query, Nodes]),
            lists:foldl(fun(N, S) -> start_connect(N, S) end, State,
                        [N || N <- Nodes, N =/= node(), not lists:member(N, Connected)])
    end.

%% A node name is an atom, and atoms are never freed: only a well-formed
%% IP address (in its canonical text, so one address is one name) becomes
%% part of one. Anything else in the answer is dropped.
canonical_addresses(Addresses) ->
    lists:foldr(fun(A, {Valid, Invalid}) ->
                        case canonical_address(A) of
                            {ok, Canonical} -> {[Canonical | Valid], Invalid};
                            {error, invalid} -> {Valid, [A | Invalid]}
                        end
                end, {[], []}, Addresses).

canonical_address(A) when is_binary(A), byte_size(A) =< ?MAX_ADDRESS_BYTES ->
    case inet:parse_strict_address(binary_to_list(A)) of
        {ok, Ip} -> {ok, list_to_binary(inet:ntoa(Ip))};
        {error, einval} -> {error, invalid}
    end;
canonical_address(_) ->
    {error, invalid}.

report_invalid(_Query, []) ->
    ok;
report_invalid(Query, Invalid = [First | _]) ->
    Shown = case is_binary(First) of
                true -> binary:part(First, 0, min(byte_size(First), ?MAX_ADDRESS_BYTES));
                false -> not_a_binary
            end,
    brazier_log_ffi:error(<<"brazier.cluster">>, "DNS lookup of ~ts returned ~b entries that are not IP "
                         "addresses (first: ~0p); skipping them", [Query, length(Invalid), Shown]),
    brazier_telemetry_ffi:cluster_connect_failed(Query, format({invalid_addresses, length(Invalid)})).

%% The node names for Addresses. A name that is already an atom costs
%% nothing; a new one counts against max_discovered_nodes for the life of
%% the VM (the count survives manager restarts), and past it no new name
%% is made: a DNS answer that keeps changing cannot exhaust the atom table.
node_atoms(Base, Addresses, #{dns_atoms := Counter, max_discovered_nodes := Cap}) ->
    lists:foldr(fun(A, {Nodes, Refused}) ->
                        Name = <<Base/binary, "@", A/binary>>,
                        case existing_atom(Name) of
                            {ok, Node} ->
                                {[Node | Nodes], Refused};
                            {error, new} ->
                                case atomics:get(Counter, 1) < Cap of
                                    true ->
                                        ok = atomics:add(Counter, 1, 1),
                                        {[binary_to_atom(Name) | Nodes], Refused};
                                    false ->
                                        {Nodes, Refused + 1}
                                end
                        end
                end, {[], 0}, Addresses).

existing_atom(Name) ->
    try binary_to_existing_atom(Name) of
        Atom -> {ok, Atom}
    catch
        error:badarg -> {error, new}
    end.

report_refused(_Query, 0, _State) ->
    ok;
report_refused(Query, Refused, #{max_discovered_nodes := Cap}) ->
    brazier_log_ffi:error(<<"brazier.cluster">>, "DNS lookup of ~ts named ~b new nodes past "
                         "max_discovered_nodes (~b node names made over this VM's life); not "
                         "connecting to them", [Query, Refused, Cap]),
    brazier_telemetry_ffi:cluster_connect_failed(Query, format({max_discovered_nodes, Cap, Refused})).

%% The VM-wide count of node names DNS discovery made, created by the first
%% manager to start on this VM.
dns_atom_counter() ->
    case persistent_term:get(?DNS_ATOMS, none) of
        none ->
            Counter = atomics:new(1, [{signed, false}]),
            ok = persistent_term:put(?DNS_ATOMS, Counter),
            Counter;
        Counter ->
            Counter
    end.

connect_failed(Node, Reason, State = #{discovery := Discovery}) ->
    ok = brazier_telemetry_ffi:cluster_connect_failed(atom_to_binary(Node), Reason),
    case Discovery of
        {static, _} ->
            {State1, Delay, Attempt} = schedule_retry(Node, bump_attempts(Node, State)),
            brazier_log_ffi:warning(<<"brazier.cluster">>, "Connect to ~p failed (~ts), attempt ~b; "
                                   "retrying in ~bms", [Node, Reason, Attempt, Delay]),
            State1;
        {dns, _, _, PollMs} ->
            brazier_log_ffi:warning(<<"brazier.cluster">>, "Connect to ~p failed (~ts); retrying on the "
                                   "next DNS poll in ~bms", [Node, Reason, PollMs]),
            State;
        no_discovery ->
            State
    end.

%% A static target that went down is retried with backoff. A rejected one
%% stays connected, so it needs no retry.
retry_target(Node, State = #{discovery := {static, _}, targets := Targets}) ->
    case maps:is_key(Node, Targets) of
        true ->
            {State1, Delay, _} = schedule_retry(Node, State),
            brazier_log_ffi:info(<<"brazier.cluster">>, "Reconnecting to ~p in ~bms", [Node, Delay]),
            State1;
        false ->
            State
    end;
retry_target(_Node, State) ->
    State.

schedule_retry(Node, State = #{targets := Targets, initial_ms := Initial, max_ms := Max}) ->
    Target = #{attempts := Attempts} = maps:get(Node, Targets),
    {Low, High} = backoff_window(Attempts, Initial, Max),
    Delay = Low + rand:uniform(High - Low + 1) - 1,
    cancel(maps:get(timer, Target)),
    TRef = erlang:send_after(Delay, self(), {connect, Node}),
    {State#{targets := Targets#{Node => Target#{timer := TRef}}}, Delay, Attempts}.

bump_attempts(Node, State = #{targets := Targets}) ->
    case maps:find(Node, Targets) of
        {ok, Target = #{attempts := A}} ->
            State#{targets := Targets#{Node => Target#{attempts := A + 1}}};
        error ->
            State
    end.

reset_attempts(Node, State = #{targets := Targets}) ->
    case maps:find(Node, Targets) of
        {ok, Target} -> State#{targets := Targets#{Node => Target#{attempts := 0}}};
        error -> State
    end.

%% A static target keeps its entry (attempts, retry timer). A DNS-discovered
%% node is only tracked while its attempt is in flight, so the table stays
%% bounded by max_dns_nodes however the DNS answer changes over time.
finish_connect(Node, State = #{discovery := {static, _}, targets := Targets}) ->
    case maps:find(Node, Targets) of
        {ok, Target} -> State#{targets := Targets#{Node => Target#{inflight := none}}};
        error -> State
    end;
finish_connect(Node, State = #{targets := Targets}) ->
    State#{targets := maps:remove(Node, Targets)}.

clear_timer(Node, State = #{targets := Targets}) ->
    case maps:find(Node, Targets) of
        {ok, Target} -> State#{targets := Targets#{Node => Target#{timer := none}}};
        error -> State
    end.

cancel(none) -> ok;
cancel(TRef) ->
    %% The result (time left, or false if it already fired) does not matter:
    %% handlers check the current state when a stale timer message arrives.
    _ = erlang:cancel_timer(TRef),
    ok.

describe_discovery({static, Nodes}) -> io_lib:format("static, ~b nodes", [length(Nodes)]);
describe_discovery({dns, Query, Base, PollMs}) ->
    io_lib:format("dns ~ts as ~ts@<address> every ~bms", [Query, Base, PollMs]);
describe_discovery(no_discovery) -> "no discovery".

format(Term) -> unicode:characters_to_binary(io_lib:format("~0p", [Term])).
