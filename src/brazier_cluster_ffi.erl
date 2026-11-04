-module(brazier_cluster_ffi).

%% Lifecycle and queries for the cluster manager (brazier_cluster_manager),
%% plus the facts brazier/cluster checks before starting it.

-include_lib("kernel/include/inet.hrl").

-export([start/1, start_link/1, stop/0, members/0, verified/1, verified_nodes/0,
         await_verified/1, distribution/0, tls_verify/2, resolve_dns/1, backoff_window/3]).

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
        Rows -> {ok, lists:sort([Node || {Node, _VerifiedAt} <- Rows])}
    catch
        error:badarg -> {error, not_started}
    end.

%% Whether Node may exchange cluster traffic with this node: it is this node,
%% or a connected peer that passed the peer check. Without a running
%% manager no remote node is verified (fail closed: no table, no members).
verified(Node) when Node =:= node() ->
    true;
verified(Node) ->
    try ets:member(?MEMBERS, Node)
    catch
        error:badarg -> false
    end.

%% Verified peers (not this node), unsorted. [] without a manager.
verified_nodes() ->
    try ets:tab2list(?MEMBERS) of
        Rows -> [Node || {Node, _VerifiedAt} <- Rows]
    catch
        error:badarg -> []
    end.

%% Ask the manager to send {brazier_cluster_peer_verified, Node} to the
%% caller once Node passes the peer check (at once if it has). A rejected
%% node stays connected and may still pass on a later hello, so the wait
%% outlives a rejection. Nothing is sent if Node is not connected, or goes
%% down before it passes.
await_verified(Node) when is_atom(Node) ->
    case whereis(?NAME) of
        undefined ->
            {error, not_started};
        Pid ->
            ok = gen_server:cast(Pid, {await_verified, Node, self()}),
            {ok, nil}
    end.

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
