-module(beacon_cluster_manager).
-behaviour(gen_server).

%% The Beacon cluster manager: node discovery, reconnection with backoff,
%% node up/down reporting and the peer secret check.
%%
%% Discovery follows libcluster's Epmd (static list) and DNSPoll strategies:
%%   {static, Nodes}            connect to each node, retrying a failed or
%%                              lost connection with exponential backoff and
%%                              jitter (initial doubling to max).
%%   {dns, Query, Base, PollMs} every PollMs resolve Query (A + AAAA, or the
%%                              injected resolver) and connect to Base@Addr
%%                              for each address not yet connected.
%%   no_discovery               only report and check nodes that connect.
%%
%% Connection attempts and DNS lookups run in short-lived monitored
%% processes (net_kernel:connect_node/1 can block for net_setuptime), so the
%% manager itself never blocks. At most one attempt per target is in flight.
%%
%% Peer check: on nodeup (and at init, for nodes already connected) each
%% side sends
%%   {beacon_cluster_hello, FromNode, ?PROTOCOL_VERSION, Mac}
%% to {beacon_cluster, Node}, where Mac = HMAC-SHA256(secret_key,
%% "beacon-cluster-v1"). A manager that accepts a hello answers with
%%   {beacon_cluster_hello_ack, FromNode, ?PROTOCOL_VERSION, Mac}
%% which is checked the same way but not answered. The ack covers a hello
%% sent before the other side's manager was running (it is dropped), and a
%% manager restarted while its peers stayed connected (they see no nodeup).
%% A peer whose Mac or version differs, or that sends neither a hello nor
%% an ack within the check timeout, is rejected: error log,
%% [beacon, cluster, peer, rejected], erlang:disconnect_node/1. Anyone with
%% the cookie can already run code on this node, so this guards against
%% misconfiguration (two deployments sharing a cookie), not an attacker.
%%
%% Verified peers are listed in the protected table beacon_cluster_members
%% so members/0 reads them without a call.

-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, backoff_window/3]).

-define(NAME, beacon_cluster).
-define(MEMBERS, beacon_cluster_members).
-define(PROTOCOL_VERSION, 1).
%% Exponent cap, so 2^attempt stays small; max_ms bounds the delay anyway.
-define(MAX_EXPONENT, 30).

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
        %% Node => {pending, TRef} | verified
        peers => #{},
        %% MonitorRef => {connect, Node} | {resolve, Pid, TimeoutRef}
        jobs => #{}
    },
    beacon_log_ffi:info(<<"beacon.cluster">>, "Cluster manager started on ~p (~ts)",
                        [node(), describe_discovery(Discovery)]),
    %% Nodes connected before the manager started send no nodeup.
    Connected = nodes(),
    Connected =/= [] andalso
        beacon_log_ffi:info(<<"beacon.cluster">>, "Checking ~b already-connected nodes: ~p",
                            [length(Connected), Connected]),
    State1 = lists:foldl(fun peer_up/2, State0, Connected),
    {ok, start_discovery(Discovery, State1)}.

handle_call(Request, From, State) ->
    beacon_log_ffi:warning(<<"beacon.cluster">>, "Unexpected call ~p from ~p", [Request, From]),
    {reply, {error, unknown_call}, State}.

handle_cast(Request, State) ->
    beacon_log_ffi:warning(<<"beacon.cluster">>, "Unexpected cast ~p", [Request]),
    {noreply, State}.

handle_info({nodeup, Node, _Info}, State) ->
    beacon_log_ffi:info(<<"beacon.cluster">>, "Node up: ~p", [Node]),
    ok = beacon_telemetry_ffi:cluster_node(node_up, atom_to_binary(Node), <<"connected">>),
    {noreply, peer_up(Node, State)};
handle_info({nodedown, Node, Info}, State) ->
    Reason = format(proplists:get_value(nodedown_reason, Info, unknown)),
    beacon_log_ffi:warning(<<"beacon.cluster">>, "Node down: ~p (~ts)", [Node, Reason]),
    ok = beacon_telemetry_ffi:cluster_node(node_down, atom_to_binary(Node), Reason),
    {noreply, retry_target(Node, peer_down(Node, State))};
handle_info({beacon_cluster_hello, Node, Version, Mac}, State) when is_atom(Node) ->
    case check(Node, Version, Mac, State) of
        {verified, State1 = #{mac := Own}} ->
            {?NAME, Node} ! {beacon_cluster_hello_ack, node(), ?PROTOCOL_VERSION, Own},
            {noreply, State1};
        {rejected, State1} ->
            {noreply, State1}
    end;
handle_info({beacon_cluster_hello_ack, Node, Version, Mac}, State) when is_atom(Node) ->
    {_, State1} = check(Node, Version, Mac, State),
    {noreply, State1};
handle_info({peer_check_timeout, Node}, State = #{peers := Peers}) ->
    case maps:get(Node, Peers, none) of
        {pending, _} ->
            {noreply, reject(Node, <<"no hello within the peer check timeout">>, State)};
        _ ->
            %% Verified or gone since the timer was set; cancel_timer races.
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
            beacon_log_ffi:warning(<<"beacon.cluster">>, "DOWN for unknown job ~p: ~p", [Ref, Result]),
            {noreply, State}
    end;
handle_info(Message, State) ->
    beacon_log_ffi:warning(<<"beacon.cluster">>, "Unexpected message ~p", [Message]),
    {noreply, State}.

terminate(Reason, #{jobs := Jobs}) ->
    beacon_log_ffi:info(<<"beacon.cluster">>, "Cluster manager stopping: ~p", [Reason]),
    %% A resolver may hang (that is what its timeout is for); do not leave
    %% it behind. Connect attempts end within net_setuptime on their own.
    [true = exit(Pid, kill) || {resolve, Pid, _} <- maps:values(Jobs)],
    ok.

%% --- Peer check ---

peer_up(Node, State = #{peers := Peers, mac := Mac, check_timeout_ms := Timeout}) ->
    {?NAME, Node} ! {beacon_cluster_hello, node(), ?PROTOCOL_VERSION, Mac},
    case maps:get(Node, Peers, none) of
        verified ->
            %% Its hello arrived before our nodeup.
            State;
        _ ->
            TRef = erlang:send_after(Timeout, self(), {peer_check_timeout, Node}),
            State#{peers := Peers#{Node => {pending, TRef}}}
    end.

peer_down(Node, State = #{peers := Peers}) ->
    case maps:take(Node, Peers) of
        {{pending, TRef}, Rest} ->
            cancel(TRef),
            State#{peers := Rest};
        {verified, Rest} ->
            true = ets:delete(?MEMBERS, Node),
            State#{peers := Rest};
        error ->
            State
    end.

check(Node, ?PROTOCOL_VERSION, TheirMac, State = #{mac := Mac, peers := Peers})
        when is_binary(TheirMac) ->
    case crypto:hash_equals(pad(TheirMac, byte_size(Mac)), Mac)
         andalso byte_size(TheirMac) =:= byte_size(Mac) of
        true ->
            case maps:get(Node, Peers, none) of
                {pending, TRef} -> cancel(TRef);
                _ -> ok
            end,
            true = ets:insert(?MEMBERS, {Node, erlang:system_time(millisecond)}),
            beacon_log_ffi:info(<<"beacon.cluster">>, "Peer verified: ~p", [Node]),
            {verified, reset_attempts(Node, State#{peers := Peers#{Node => verified}})};
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

reject(Node, Reason, State) ->
    beacon_log_ffi:error(<<"beacon.cluster">>, "Rejecting peer ~p: ~ts; disconnecting", [Node, Reason]),
    ok = beacon_telemetry_ffi:cluster_peer_rejected(atom_to_binary(Node), Reason),
    %% disconnect_node/1 returns false when the node is already gone, which
    %% is the outcome we want either way; the nodedown is handled as usual.
    Disconnected = erlang:disconnect_node(Node),
    beacon_log_ffi:info(<<"beacon.cluster">>, "disconnect_node(~p) -> ~p", [Node, Disconnected]),
    bump_attempts(Node, peer_down(Node, State)).

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
            beacon_log_ffi:debug(<<"beacon.cluster">>, "Connected to ~p", [Node]),
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
    beacon_log_ffi:error(<<"beacon.cluster">>, "DNS lookup of ~ts failed: ~ts; retrying in ~bms",
                         [Query, Reason, PollMs]),
    ok = beacon_telemetry_ffi:cluster_connect_failed(Query, <<"dns: ", Reason/binary>>),
    schedule_poll(State).

schedule_poll(State = #{discovery := {dns, _, _, PollMs}}) ->
    erlang:send_after(PollMs, self(), poll),
    State.

connect_discovered(Query, Base, Addresses, State = #{max_dns_nodes := Max}) ->
    Unique = lists:usort(Addresses),
    case length(Unique) =< Max of
        false ->
            Reason = format({too_many_addresses, length(Unique), Max}),
            beacon_log_ffi:error(<<"beacon.cluster">>, "DNS lookup of ~ts returned ~b addresses, more "
                                 "than max_dns_nodes (~b); connecting to none of them",
                                 [Query, length(Unique), Max]),
            ok = beacon_telemetry_ffi:cluster_connect_failed(Query, Reason),
            State;
        true ->
            Connected = nodes(),
            Nodes = [binary_to_atom(<<Base/binary, "@", A/binary>>) || A <- Unique],
            beacon_log_ffi:debug(<<"beacon.cluster">>, "DNS ~ts -> ~p", [Query, Nodes]),
            lists:foldl(fun(N, S) -> start_connect(N, S) end, State,
                        [N || N <- Nodes, N =/= node(), not lists:member(N, Connected)])
    end.

connect_failed(Node, Reason, State = #{discovery := Discovery}) ->
    ok = beacon_telemetry_ffi:cluster_connect_failed(atom_to_binary(Node), Reason),
    case Discovery of
        {static, _} ->
            {State1, Delay, Attempt} = schedule_retry(Node, bump_attempts(Node, State)),
            beacon_log_ffi:warning(<<"beacon.cluster">>, "Connect to ~p failed (~ts), attempt ~b; "
                                   "retrying in ~bms", [Node, Reason, Attempt, Delay]),
            State1;
        {dns, _, _, PollMs} ->
            beacon_log_ffi:warning(<<"beacon.cluster">>, "Connect to ~p failed (~ts); retrying on the "
                                   "next DNS poll in ~bms", [Node, Reason, PollMs]),
            State;
        no_discovery ->
            State
    end.

%% A static target that went down or was rejected is retried with backoff.
retry_target(Node, State = #{discovery := {static, _}, targets := Targets}) ->
    case maps:is_key(Node, Targets) of
        true ->
            {State1, Delay, _} = schedule_retry(Node, State),
            beacon_log_ffi:info(<<"beacon.cluster">>, "Reconnecting to ~p in ~bms", [Node, Delay]),
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
