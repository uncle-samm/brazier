-module(beacon_peer_ffi).

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

-export([with_cluster/3, with_cluster_args/4, rpc/3, crash/1, stop/1, partition/2,
         heal/2, restore/2, connect/2, node_of/1, pause/1, alive/1, add_peer/2, add_peer_args/3]).

-define(START_TIMEOUT_MS, 30000).
-define(STOP_TIMEOUT_MS, 10000).

%% Start Count connected peers, run Fun(Peers), always stop the peers.
%% Peers is a list of {peer, ControlPid, Node, Keeper}.
with_cluster(Count, Prefix, Fun) ->
    with_cluster_args(Count, Prefix, [], Fun).

%% with_cluster/3 with extra command-line arguments for every peer (for
%% example TLS distribution flags).
with_cluster_args(Count, Prefix, ExtraArgs, Fun) ->
    Owner = self(),
    Cookie = random_cookie(),
    Keeper = spawn(fun() -> keeper_init(Owner, Cookie) end),
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
        {Ref, {ok, Pid, Node}} ->
            erlang:demonitor(Ref, [flush]),
            {peer, Pid, Node, Keeper};
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

%% Connect peer A to peer B. {ok, nil} | {error, Description}.
connect(A, B) ->
    NodeB = node_of(B),
    case rpc(A, fun() -> net_kernel:connect_node(NodeB) end, 10000) of
        {ok, true} ->
            {ok, nil};
        {ok, Other} ->
            {error, unicode:characters_to_binary(
                io_lib:format("connect ~p -> ~p returned ~p", [node_of(A), NodeB, Other]))};
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
    {ok, true} = rpc(A, fun() -> erlang:set_cookie(NodeB, beacon_partitioned_a) end, 5000),
    {ok, true} = rpc(B, fun() -> erlang:set_cookie(NodeA, beacon_partitioned_b) end, 5000),
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

keeper_init(Owner, Cookie) ->
    process_flag(trap_exit, true),
    OwnerRef = erlang:monitor(process, Owner),
    keeper_loop(Owner, OwnerRef, Cookie, []).

keeper_loop(Owner, OwnerRef, Cookie, Peers) ->
    receive
        {start_peer, From, Ref, Prefix, ExtraArgs} ->
            case start_node(Cookie, Prefix, ExtraArgs) of
                {ok, Pid, Node} ->
                    From ! {Ref, {ok, Pid, Node}},
                    keeper_loop(Owner, OwnerRef, Cookie, [Pid | Peers]);
                {error, Reason} ->
                    From ! {Ref, {error, Reason}},
                    keeper_loop(Owner, OwnerRef, Cookie, Peers)
            end;
        {stop_all, From, Ref} ->
            stop_peers(Peers),
            From ! {Ref, stopped};
        {'DOWN', OwnerRef, process, Owner, _Reason} ->
            stop_peers(Peers);
        {'EXIT', Pid, _Reason} ->
            keeper_loop(Owner, OwnerRef, Cookie, lists:delete(Pid, Peers))
    end.

start_node(Cookie, Prefix, ExtraArgs) ->
    %% Every non-OTP code path of the runner (the Gleam build directories),
    %% made absolute so the peer resolves them whatever its cwd.
    Root = code:root_dir(),
    Paths = [filename:absname(P) || P <- code:get_path(),
                                    string:prefix(filename:absname(P), Root) =:= nomatch,
                                    P =/= "."],
    Args = ["-setcookie", atom_to_list(Cookie),
            "-kernel", "logger_level", "none"
            | [unicode:characters_to_list(A) || A <- ExtraArgs]] ++ ["-pa" | Paths],
    try peer:start_link(#{name => peer:random_name(unicode:characters_to_list(Prefix)),
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
    binary_to_atom(<<"beacon_test_", Hex/binary>>).
