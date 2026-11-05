-module(brazier_cluster_ffi).

%% Lifecycle and queries for the cluster manager (brazier_cluster_manager),
%% plus the facts brazier/cluster checks before starting it.

-include_lib("kernel/include/inet.hrl").

-export([start/1, start_link/1, stop/0, members/0, verified/1, verified_nodes/0,
         await_verified/1, distribution/0, tls_verify/2, resolve_dns/1, backoff_window/3,
         connection_id/1, waiters/0, subscribe_mutual/1, unsubscribe_mutual/1,
         live_subscribers/0]).

-define(NAME, brazier_cluster).
-define(MEMBERS, brazier_cluster_members).
-define(STOP_TIMEOUT_MS, 15000).

%% Start the manager unlinked from the caller (cluster.start).
start(ConfigRecord) ->
    case brazier_cluster_manager:start_link(config_map(ConfigRecord)) of
        {ok, Pid} ->
            true = unlink(Pid),
            {ok, nil};
        Error ->
            start_error(Error)
    end.

%% Start the manager linked to the caller, for a supervisor to own.
start_link(ConfigRecord) ->
    case brazier_cluster_manager:start_link(config_map(ConfigRecord)) of
        {ok, Pid} -> {ok, Pid};
        Error -> start_error(Error)
    end.

start_error({error, {already_started, Pid}}) ->
    brazier_log_ffi:error(<<"brazier.cluster">>, "The cluster manager is already running as ~p", [Pid]),
    {error, already_started};
start_error({error, Reason}) ->
    brazier_log_ffi:error(<<"brazier.cluster">>, "Cluster manager failed to start: ~p", [Reason]),
    {error, {start_failed, format(Reason)}};
start_error(ignore) ->
    brazier_log_ffi:error(<<"brazier.cluster">>, "Cluster manager init returned ignore"),
    {error, {start_failed, <<"init returned ignore">>}}.

stop() ->
    case whereis(?NAME) of
        undefined ->
            {error, not_started};
        Pid ->
            brazier_log_ffi:info(<<"brazier.cluster">>, "Stopping the cluster manager"),
            try gen_server:stop(Pid, normal, ?STOP_TIMEOUT_MS) of
                ok ->
                    brazier_log_ffi:info(<<"brazier.cluster">>, "Cluster manager stopped"),
                    {ok, nil}
            catch
                exit:noproc ->
                    brazier_log_ffi:warning(<<"brazier.cluster">>, "The cluster manager was already stopping"),
                    {error, not_started};
                exit:Reason ->
                    brazier_log_ffi:error(<<"brazier.cluster">>, "Cluster manager did not stop: ~p", [Reason]),
                    {error, {stop_failed, format(Reason)}}
            end
    end.

%% Verified peers, sorted.
members() ->
    try ets:tab2list(?MEMBERS) of
        Rows -> {ok, lists:sort(current_members(Rows))}
    catch
        error:badarg -> {error, not_started}
    end.

%% Whether Node may exchange cluster traffic with this node: it is this node,
%% or a connected peer that passed the peer check on its current
%% connection. Without a running manager no remote node is verified (fail
%% closed: no table, no members).
%%
%% A member row {Node, VerifiedAtMs, ConnectionId} names the distribution
%% connection the check passed on (erlang:nodes/2 connection_id). The
%% manager deletes the row when it handles the nodedown, which can come
%% well after the connection is gone: in between, the row alone would
%% still count Node, and a new connection to the same node name (a
%% reconnect, or another VM that took the name) would be trusted before
%% its own check. So the row counts only while its connection is the one
%% Node is connected over now. The cost is one erlang:nodes/2 per call on a
%% verified node (a list of the connected nodes); an unverified node costs
%% one ETS lookup.
verified(Node) when Node =:= node() ->
    true;
verified(Node) ->
    try ets:lookup(?MEMBERS, Node) of
        [{Node, _VerifiedAt, ConnectionId}] -> connection_id(Node) =:= {ok, ConnectionId};
        [] -> false
    catch
        error:badarg -> false
    end.

%% Verified peers (not this node), unsorted. [] without a manager.
verified_nodes() ->
    try ets:tab2list(?MEMBERS) of
        Rows -> current_members(Rows)
    catch
        error:badarg -> []
    end.

%% The nodes of member Rows whose connection is still the one they were
%% verified on (see verified/1).
current_members(Rows) ->
    Current = maps:from_list(connections()),
    [Node || {Node, _VerifiedAt, ConnectionId} <- Rows,
             maps:get(Node, Current, none) =:= ConnectionId].

%% The id of the distribution connection to Node now: {ok, Id}, or error
%% when Node is not connected. A new connection to the same node name gets
%% a new id.
connection_id(Node) ->
    case lists:keyfind(Node, 1, connections()) of
        {Node, Id} -> {ok, Id};
        false -> error
    end.

%% [{Node, ConnectionId}] of every connected visible node.
connections() ->
    [{Node, Id} || {Node, #{connection_id := Id}} <- erlang:nodes(visible, #{connection_id => true})].

%% --- Waiters and subscribers ---
%%
%% The processes told about the membership are kept in the public table
%% brazier_cluster_waiters, owned by the node's ETS table owner
%% (brazier_ets_ffi), not in the manager's state: a manager that crashes
%% and is restarted (by its supervisor, or by hand) finds them all again,
%% and the new manager's peer check of every connected node tells them as
%% the old one would have. OTP's own registries keep what must outlive a
%% server outside it in the same way (an ETS table whose owner outlives
%% the server that writes it); Phoenix.Tracker instead loses its tracked
%% processes with a crashed shard and relies on them tracking again, which
%% a process waiting for a message cannot do. Rows:
%%
%%   {{await, Node, Pid}, ConnectionId}  Pid waits for Node to pass the
%%                                       check on that connection; taken
%%                                       (ets:take/2, so exactly one
%%                                       process sends) when it does
%%   {{subscriber, Pid}, nil}            Pid is told every time a node and
%%                                       this one have verified each other
%%
%% Bounds: a waiter row is deleted when it is told, when its connection
%% goes down (the manager's nodedown, or the next manager's init for one
%% that went down while none ran), and when its process is found dead (on
%% the next wait for the same node, and at init); a subscriber row by
%% unsubscribe_mutual/1, and when found dead (on every notice and every
%% subscribe). So the table holds at most one row per live process and
%% node, plus the rows of processes that died since the last sweep.

-define(WAITERS, brazier_cluster_waiters).

%% The waiter table, created on first use. {ok, Table} | {error, Reason}.
waiters() ->
    case ets:whereis(?WAITERS) of
        undefined ->
            case brazier_ets_ffi:ensure_table(atom_to_binary(?WAITERS), ets_set) of
                {ok, ?WAITERS} ->
                    {ok, ?WAITERS};
                {error, Reason} ->
                    brazier_log_ffi:error(<<"brazier.cluster">>, "Cannot create the cluster waiter table: ~p",
                                         [Reason]),
                    {error, {waiters_unavailable, format(Reason)}}
            end;
        _Tid ->
            {ok, ?WAITERS}
    end.

%% Send {brazier_cluster_peer_verified, Node} to the caller once Node
%% passes the peer check on the connection it is connected over now (at
%% once if it has). A rejected node stays connected and may still pass on
%% a later hello, so the wait outlives a rejection, and a restart of the
%% manager (the wait is in brazier_cluster_waiters). Nothing is sent if
%% Node is not connected, or goes down before it passes. {ok, nil}, or
%% {error, not_started} when no manager runs, or {error, {waiters_unavailable,
%% Reason}}.
%%
%% The row is written before the caller looks at the membership, and both
%% the manager and the caller take it with ets:take/2, so the notice is
%% sent exactly once however the two interleave: the manager writes the
%% member row before it takes the waiters, so a caller that finds Node not
%% yet verified after its insert is sure to be taken by the manager.
await_verified(Node) when is_atom(Node) ->
    case whereis(?NAME) of
        undefined ->
            {error, not_started};
        _Pid ->
            case waiters() of
                {ok, Table} -> await_on(Table, Node, self());
                {error, _} = Error -> Error
            end
    end.

await_on(Table, Node, Self) ->
    case connection_id(Node) of
        error ->
            brazier_log_ffi:debug(<<"brazier.cluster">>, "Not waiting for ~p for ~p: it is not connected",
                                 [Node, Self]),
            {ok, nil};
        {ok, Id} ->
            Pruned = prune_waiters(Table, Node),
            Key = {await, Node, Self},
            true = ets:insert(Table, {Key, Id}),
            case {connection_id(Node), verified(Node)} of
                {{ok, Id}, true} ->
                    %% Verified already, or as the row was written: whoever
                    %% takes the row sends the notice.
                    case ets:take(Table, Key) of
                        [_] -> Self ! {brazier_cluster_peer_verified, Node};
                        [] -> ok
                    end;
                {{ok, Id}, false} ->
                    brazier_log_ffi:debug(<<"brazier.cluster">>, "~p waits for ~p to be verified (~b dead "
                                         "waiters pruned)", [Self, Node, Pruned]);
                {_Gone, _} ->
                    %% The connection went down as the row was written; its
                    %% nodedown may already have been handled, so the row is
                    %% removed here. A notice for it can no longer come.
                    true = ets:delete(Table, Key),
                    brazier_log_ffi:debug(<<"brazier.cluster">>, "Not waiting for ~p for ~p: its connection "
                                         "went down", [Node, Self])
            end,
            {ok, nil}
    end.

%% Delete the waits for Node of processes that died; returns how many.
prune_waiters(Table, Node) ->
    Dead = [Key || {{await, _, Pid} = Key, _Id} <- ets:match_object(Table, {{await, Node, '_'}, '_'}),
                   not is_process_alive(Pid)],
    lists:foreach(fun(Key) -> true = ets:delete(Table, Key) end, Dead),
    length(Dead).

%% Tell Pid {brazier_cluster_peer_mutual, Node} every time Node and this
%% node have verified each other on a connection: this node verified Node,
%% and Node's manager acknowledged this node's hello (it sends an ack only
%% for a hello it accepted, and for an ack that verified this node). That
%% is the moment both directions of cluster traffic flow, so it is when
%% state missed while they could not (revocations, store states) is caught
%% up. Told once per connection while a manager runs; a restarted manager
%% tells again for the nodes it checks anew. Works with no manager running
%% (nothing is sent until one runs), and survives manager restarts. Pid
%% must be local. {ok, nil} | {error, {waiters_unavailable, Reason}}.
subscribe_mutual(Pid) when is_pid(Pid), node(Pid) =:= node() ->
    case waiters() of
        {ok, Table} ->
            Pruned = prune_subscribers(Table),
            true = ets:insert(Table, {{subscriber, Pid}, nil}),
            brazier_log_ffi:debug(<<"brazier.cluster">>, "~p subscribed to mutual verification (~b dead "
                                 "subscribers pruned)", [Pid, Pruned]),
            {ok, nil};
        {error, _} = Error ->
            Error
    end.

unsubscribe_mutual(Pid) when is_pid(Pid) ->
    case ets:whereis(?WAITERS) of
        undefined -> nil;
        _Tid -> true = ets:delete(?WAITERS, {subscriber, Pid}), nil
    end.

%% The live subscribers, deleting the rows of dead ones. Called by the
%% manager for every notice, and by subscribe_mutual/1.
live_subscribers() ->
    case ets:whereis(?WAITERS) of
        undefined -> [];
        _Tid ->
            _ = prune_subscribers(?WAITERS),
            [Pid || {{subscriber, Pid}, nil} <- ets:match_object(?WAITERS, {{subscriber, '_'}, '_'})]
    end.

prune_subscribers(Table) ->
    Dead = [Key || {{subscriber, Pid} = Key, nil} <- ets:match_object(Table, {{subscriber, '_'}, '_'}),
                   not is_process_alive(Pid)],
    lists:foreach(fun(Key) -> true = ets:delete(Table, Key) end, Dead),
    length(Dead).

%% {distribution, Alive, ProtoDist, CookieBytes, TlsVerify}. The cookie
%% itself never leaves here.
distribution() ->
    Alive = erlang:is_alive(),
    Proto = case init:get_argument(proto_dist) of
                {ok, [[P | _] | _]} -> unicode:characters_to_binary(P);
                _ -> <<"inet_tcp">>
            end,
    CookieBytes = case Alive of
                      true -> byte_size(atom_to_binary(erlang:get_cookie()));
                      false -> 0
                  end,
    TlsVerify = tls_verify(init:get_argument(ssl_dist_optfile), init:get_argument(ssl_dist_opt)),
    {distribution, Alive, Proto, CookieBytes, TlsVerify}.

%% The peer verification options of TLS distribution, from the arguments
%% init:get_argument/1 returned for -ssl_dist_optfile and -ssl_dist_opt.
%% OTP reads the option file instead of every -ssl_dist_opt when both are
%% given (inet_tls_dist), so this does too. {ok, {tls_verify,
%% ServerVerifyPeer, ServerFailIfNoPeerCert, ClientVerifyPeer}} or {error,
%% Description} when the option file cannot be read.
tls_verify({ok, [[Path | _] | _]}, _Opts) ->
    case file:consult(Path) of
        {ok, [Terms]} when is_list(Terms) ->
            Server = proplist(server, Terms),
            Client = proplist(client, Terms),
            {ok, {tls_verify,
                  proplists:get_value(verify, Server) =:= verify_peer,
                  proplists:get_value(fail_if_no_peer_cert, Server) =:= true,
                  proplists:get_value(verify, Client) =:= verify_peer}};
        {ok, Other} ->
            {error, format({ssl_dist_optfile_not_one_list, Path, length(Other)})};
        {error, Reason} ->
            {error, format({ssl_dist_optfile_unreadable, Path, Reason})}
    end;
tls_verify(_NoOptfile, {ok, Groups}) ->
    Pairs = pairs(lists:append(Groups)),
    {ok, {tls_verify,
          proplists:get_value("server_verify", Pairs) =:= "verify_peer",
          proplists:get_value("server_fail_if_no_peer_cert", Pairs) =:= "true",
          proplists:get_value("client_verify", Pairs) =:= "verify_peer"}};
tls_verify(_NoOptfile, error) ->
    {ok, {tls_verify, false, false, false}}.

proplist(Key, Terms) ->
    case proplists:get_value(Key, Terms, []) of
        Opts when is_list(Opts) -> Opts;
        _ -> []
    end.

%% -ssl_dist_opt takes Key Value pairs; an odd trailing key has no value.
pairs([Key, Value | Rest]) -> [{Key, Value} | pairs(Rest)];
pairs(_) -> [].

%% The default DNS resolver: A and AAAA records of Query, as address
%% strings. An error only when both lookups fail (a name with only A or
%% only AAAA records is normal).
resolve_dns(Query) ->
    Name = unicode:characters_to_list(Query),
    case {lookup(Name, a), lookup(Name, aaaa)} of
        {{error, A}, {error, Aaaa}} ->
            {error, format({dns_lookup_failed, [{a, A}, {aaaa, Aaaa}]})};
        {V4, V6} ->
            {ok, addresses(V4) ++ addresses(V6)}
    end.

lookup(Name, Type) ->
    case inet_res:getbyname(Name, Type) of
        {ok, #hostent{h_addr_list = Addrs}} -> {ok, Addrs};
        {error, Reason} -> {error, Reason}
    end.

addresses({ok, Addrs}) -> [unicode:characters_to_binary(inet:ntoa(A)) || A <- Addrs];
addresses({error, _}) -> [].

backoff_window(Attempt, InitialMs, MaxMs) ->
    {Low, High} = brazier_cluster_manager:backoff_window(Attempt, InitialMs, MaxMs),
    {backoff_window, Low, High}.

%% The Gleam ManagerConfig record, as the manager's map.
config_map({manager_config, Discovery, Mac, CheckTimeoutMs, InitialMs, MaxMs, Resolver,
            ResolveTimeoutMs, MaxDnsNodes, MaxDiscoveredNodes}) ->
    #{discovery => discovery(Discovery),
      mac => Mac,
      check_timeout_ms => CheckTimeoutMs,
      initial_ms => InitialMs,
      max_ms => MaxMs,
      resolver => Resolver,
      resolve_timeout_ms => ResolveTimeoutMs,
      max_dns_nodes => MaxDnsNodes,
      max_discovered_nodes => MaxDiscoveredNodes}.

%% Static node names were validated (count and length bounded) by
%% brazier/cluster, so creating their atoms is bounded too.
discovery({static, Nodes}) -> {static, [binary_to_atom(N) || N <- Nodes]};
discovery({dns, Query, Base, PollMs}) -> {dns, Query, Base, PollMs};
discovery(no_discovery) -> no_discovery.

format(Term) -> unicode:characters_to_binary(io_lib:format("~0p", [Term])).
