-module(brazier_peer_ffi).

%% Multi-node test harness over OTP's peer module.
%%
%% The test runner stays non-distributed: every peer is started with
%% peer:start_link/1 over a standard_io control connection, and the peers
%% are distributed among themselves (short names, one random cookie per
%% cluster). Code paths are the runner's build paths, so a Gleam closure
%% sent with rpc/3 runs the same compiled code on the peer.
%%
%% A keeper process owns the peers. It traps exits, so a peer that halts
%% (crash/1) does not take the test process down, and it monitors the test
%% process, so the peers are stopped even when a test fails or is killed.
%% with_cluster/3 also stops them in an `after` clause on the normal path.
%%
%% Cluster membership: PubSub, replicated stores, presence and session
%% revocation exchange messages only with nodes the cluster manager has
%% verified (brazier_cluster_ffi:verified/1). with_members/3 starts a
%% manager on every peer (and on peers added later) with one shared test
%% secret, and connect/2 waits until both sides of a connection have
%% verified each other whenever both run a manager, so a test body starts
%% with a cluster whose members already exchange messages.
%%
%% Naming: short names by default; with_long_name_cluster/3 starts peers
%% named Name@127.0.0.1 (DNS discovery builds node names from IP addresses).

-export([with_cluster/3, with_cluster_args/4, with_members/3, with_members_args/4,
         with_long_name_cluster/3, rpc/3, crash/1, stop/1, partition/2,
         heal/2, restore/2, connect/2, node_of/1, pause/1, alive/1, add_peer/2, add_peer_args/3,
         await_member/3]).

-define(START_TIMEOUT_MS, 30000).
-define(STOP_TIMEOUT_MS, 10000).
%% How long connect/2 waits for both managers to verify the connection.
-define(VERIFY_TIMEOUT_MS, 10000).
%% The secret key of every with_members/3 cluster (at least 32 bytes).
-define(MEMBER_SECRET, <<"brazier-test-member-secret-0123456789-abcdefghijklmnop">>).

%% Start Count connected peers, run Fun(Peers), always stop the peers.
%% Peers is a list of {peer, ControlPid, Node, Keeper}.
with_cluster(Count, Prefix, Fun) ->
    with_cluster_args(Count, Prefix, [], Fun).

%% with_cluster/3 with extra command-line arguments for every peer (for
%% example TLS distribution flags).
with_cluster_args(Count, Prefix, ExtraArgs, Fun) ->
    run_cluster(Count, Prefix, ExtraArgs, #{members => false, long_names => false}, Fun).

%% with_cluster/3 where every peer runs a cluster manager and every pair
%% has verified each other before Fun runs.
with_members(Count, Prefix, Fun) ->
    with_members_args(Count, Prefix, [], Fun).

with_members_args(Count, Prefix, ExtraArgs, Fun) ->
    run_cluster(Count, Prefix, ExtraArgs, #{members => true, long_names => false}, Fun).

%% with_cluster/3 with peers named Name@127.0.0.1.
with_long_name_cluster(Count, Prefix, Fun) ->
    run_cluster(Count, Prefix, [], #{members => false, long_names => true}, Fun).

run_cluster(Count, Prefix, ExtraArgs, Opts, Fun) ->
    Owner = self(),
    Cookie = random_cookie(),
    Keeper = spawn(fun() -> keeper_init(Owner, Cookie, Opts) end),
    try
        Peers = [start_peer(Keeper, Prefix, ExtraArgs) || _ <- lists:seq(1, Count)],
        ok = mesh(Peers),
        Fun(Peers)
    after
        stop_keeper(Keeper)
    end.

%% Start one more peer in the cluster that Existing belongs to (it is not
%% connected to anything yet; use connect/2).
add_peer(Existing, Prefix) ->
    add_peer_args(Existing, Prefix, []).

add_peer_args({peer, _, _, Keeper}, Prefix, ExtraArgs) ->
    start_peer(Keeper, Prefix, ExtraArgs).

start_peer(Keeper, Prefix, ExtraArgs) ->
    Ref = erlang:monitor(process, Keeper),
    Keeper ! {start_peer, self(), Ref, Prefix, ExtraArgs},
    receive
        {Ref, {ok, Pid, Node, Members}} ->
            erlang:demonitor(Ref, [flush]),
            Peer = {peer, Pid, Node, Keeper},
            ok = start_member(Peer, Members),
            Peer;
        {Ref, {error, Reason}} ->
            erlang:demonitor(Ref, [flush]),
            erlang:error({peer_start_failed, Reason});
        {'DOWN', Ref, process, Keeper, Reason} ->
            erlang:error({peer_keeper_down, Reason})
    after ?START_TIMEOUT_MS ->
        erlang:error(peer_start_timeout)
    end.

mesh(Peers) ->
    Pairs = [{A, B} || A <- Peers, B <- Peers, node_of(A) < node_of(B)],
    lists:foreach(fun({A, B}) -> {ok, nil} = connect(A, B) end, Pairs),
    ok.

%% A cluster manager on the new peer of a with_members/3 cluster.
start_member(_Peer, false) ->
    ok;
start_member(Peer, true) ->
    Start = fun() ->
                    'brazier@cluster':start('brazier@cluster':new(no_discovery), ?MEMBER_SECRET)
            end,
    case rpc(Peer, Start, 10000) of
        {ok, {ok, nil}} -> ok;
        Other -> erlang:error({cluster_manager_not_started, node_of(Peer), Other})
    end.

%% Connect peer A to peer B. {ok, nil} | {error, Description}. When both
%% run a cluster manager, returns once each has verified the other.
connect(A, B) ->
    NodeB = node_of(B),
    case rpc(A, fun() -> net_kernel:connect_node(NodeB) end, 10000) of
        {ok, true} ->
            await_members(A, B);
        {ok, Other} ->
            {error, unicode:characters_to_binary(
                io_lib:format("connect ~p -> ~p returned ~p", [node_of(A), NodeB, Other]))};
        {error, Reason} ->
            {error, Reason}
    end.

await_members(A, B) ->
    case {manager_running(A), manager_running(B)} of
        {true, true} ->
            case await_member(A, node_of(B), ?VERIFY_TIMEOUT_MS) of
                {ok, nil} -> await_member(B, node_of(A), ?VERIFY_TIMEOUT_MS);
                Error -> Error
            end;
        _ ->
            {ok, nil}
    end.

manager_running(Peer) ->
    {ok, Running} = rpc(Peer, fun() -> whereis(brazier_cluster) =/= undefined end, 5000),
    Running.

%% Wait on Peer until its cluster manager has verified Node: {ok, nil}, or
%% {error, Description} when it was not verified within TimeoutMs (the
%% manager rejected it, or Node went down).
await_member(Peer, Node, TimeoutMs) ->
    Wait = fun() ->
                   case brazier_cluster_ffi:await_verified(Node) of
                       {ok, nil} ->
                           receive
                               {brazier_cluster_peer_verified, Node} -> verified
                           after TimeoutMs ->
                               not_verified
                           end;
                       {error, not_started} ->
                           no_cluster_manager
                   end
           end,
    case rpc(Peer, Wait, TimeoutMs + 5000) of
        {ok, verified} ->
            {ok, nil};
        {ok, Outcome} ->
            {error, unicode:characters_to_binary(
                io_lib:format("~p on ~p: ~p", [Node, node_of(Peer), Outcome]))};
        {error, Reason} ->
            {error, Reason}
    end.

node_of({peer, _Pid, Node, _Keeper}) -> Node.

alive({peer, Pid, _Node, _Keeper}) -> is_process_alive(Pid).

%% Run Fun() on the peer. {ok, Result} | {error, Description}.
rpc({peer, Pid, Node, _Keeper}, Fun, TimeoutMs) ->
    try peer:call(Pid, erlang, apply, [Fun, []], TimeoutMs) of
        Result -> {ok, Result}
    catch
        Class:Reason ->
            {error, unicode:characters_to_binary(
                io_lib:format("rpc on ~p failed: ~p:~p", [Node, Class, Reason]))}
    end.

%% Halt the peer at once (no graceful shutdown), and wait until its control
%% process is gone.
crash(Peer = {peer, Pid, _Node, Keeper}) ->
    ok = peer:cast(Pid, erlang, halt, [137]),
    await_peer_exit(Peer, Keeper).

%% Graceful shutdown: init:stop/0 on the peer, then wait for it to exit.
stop(Peer = {peer, Pid, _Node, Keeper}) ->
    ok = peer:cast(Pid, init, stop, []),
    await_peer_exit(Peer, Keeper).

await_peer_exit({peer, Pid, _Node, _}, _Keeper) ->
    Ref = erlang:monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> nil
    after ?STOP_TIMEOUT_MS ->
        erlang:error({peer_did_not_exit, Pid})
    end.

%% Netsplit between A and B: each side gets a different wrong cookie for
%% the other (the same wrong cookie on both sides would still match), so
%% neither can reconnect, then the connection is dropped.
partition(A, B) ->
    NodeA = node_of(A),
    NodeB = node_of(B),
    {ok, true} = rpc(A, fun() -> erlang:set_cookie(NodeB, brazier_partitioned_a) end, 5000),
    {ok, true} = rpc(B, fun() -> erlang:set_cookie(NodeA, brazier_partitioned_b) end, 5000),
    {ok, _} = rpc(A, fun() -> erlang:disconnect_node(NodeB) end, 5000),
    nil.

%% Undo partition/2: restore each side's cookie for the other and connect.
heal(A, B) ->
    restore(A, B),
    {ok, nil} = connect(A, B),
    nil.

%% Undo partition/2 without connecting: A and B can connect again, and
%% whatever reconnects them (a cluster manager) is under test.
restore(A, B) ->
    NodeA = node_of(A),
    NodeB = node_of(B),
    {ok, true} = rpc(A, fun() -> erlang:set_cookie(NodeB, erlang:get_cookie()) end, 5000),
    {ok, true} = rpc(B, fun() -> erlang:set_cookie(NodeA, erlang:get_cookie()) end, 5000),
    nil.

pause(Ms) ->
    receive after Ms -> nil end.

%% --- Keeper ---

keeper_init(Owner, Cookie, Opts) ->
    process_flag(trap_exit, true),
    OwnerRef = erlang:monitor(process, Owner),
    keeper_loop(Owner, OwnerRef, Cookie, Opts, []).

keeper_loop(Owner, OwnerRef, Cookie, Opts = #{members := Members}, Peers) ->
    receive
        {start_peer, From, Ref, Prefix, ExtraArgs} ->
            case start_node(Cookie, Prefix, ExtraArgs, Opts) of
                {ok, Pid, Node} ->
                    From ! {Ref, {ok, Pid, Node, Members}},
                    keeper_loop(Owner, OwnerRef, Cookie, Opts, [Pid | Peers]);
                {error, Reason} ->
                    From ! {Ref, {error, Reason}},
                    keeper_loop(Owner, OwnerRef, Cookie, Opts, Peers)
            end;
        {stop_all, From, Ref} ->
            stop_peers(Peers),
            From ! {Ref, stopped};
        {'DOWN', OwnerRef, process, Owner, _Reason} ->
            stop_peers(Peers);
        {'EXIT', Pid, _Reason} ->
            keeper_loop(Owner, OwnerRef, Cookie, Opts, lists:delete(Pid, Peers))
    end.

start_node(Cookie, Prefix, ExtraArgs, #{long_names := LongNames}) ->
    %% Every non-OTP code path of the runner (the Gleam build directories),
    %% made absolute so the peer resolves them whatever its cwd.
    Root = code:root_dir(),
    Paths = [filename:absname(P) || P <- code:get_path(),
                                    string:prefix(filename:absname(P), Root) =:= nomatch,
                                    P =/= "."],
    Args = ["-setcookie", atom_to_list(Cookie),
            "-kernel", "logger_level", "none"
            | [unicode:characters_to_list(A) || A <- ExtraArgs]] ++ ["-pa" | Paths],
    Naming = case LongNames of
                 true -> #{longnames => true, host => "127.0.0.1"};
                 false -> #{}
             end,
    try peer:start_link(Naming#{name => peer:random_name(unicode:characters_to_list(Prefix)),
                                connection => standard_io,
                                args => Args,
                                wait_boot => ?START_TIMEOUT_MS}) of
        {ok, Pid, Node} -> start_apps(Pid, Node);
        {ok, Pid} -> {error, {started_without_node, Pid}};
        {error, Reason} -> {error, Reason}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% Applications every peer runs before the test body sees it. telemetry
%% must be running for handlers to attach (the runner has it started by
%% the test entry point).
-define(PEER_APPS, [telemetry]).

start_apps(Pid, Node) ->
    Results = [{App, peer:call(Pid, application, ensure_all_started, [App])}
               || App <- ?PEER_APPS],
    case [R || R = {_, Outcome} <- Results, element(1, Outcome) =/= ok] of
        [] -> {ok, Pid, Node};
        Failed ->
            ok = peer:stop(Pid),
            {error, {apps_not_started, Node, Failed}}
    end.

stop_peers(Peers) ->
    lists:foreach(fun(Pid) ->
        try peer:stop(Pid)
        catch
            %% The peer exited between our EXIT bookkeeping and this call.
            exit:noproc -> ok;
            exit:{noproc, _} -> ok
        end
    end, Peers).

stop_keeper(Keeper) ->
    Ref = erlang:monitor(process, Keeper),
    Keeper ! {stop_all, self(), Ref},
    receive
        {Ref, stopped} ->
            erlang:demonitor(Ref, [flush]),
            nil;
        {'DOWN', Ref, process, Keeper, Reason} ->
            erlang:error({peer_keeper_down, Reason})
    after ?STOP_TIMEOUT_MS * 3 ->
        exit(Keeper, kill),
        erlang:error(peer_stop_timeout)
    end.

%% 44 bytes: long enough for cluster.start's production cookie check.
random_cookie() ->
    Hex = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
    binary_to_atom(<<"brazier_test_", Hex/binary>>).
