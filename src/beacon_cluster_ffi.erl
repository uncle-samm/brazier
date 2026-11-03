-module(beacon_cluster_ffi).

%% Lifecycle and queries for the cluster manager (beacon_cluster_manager),
%% plus the facts beacon/cluster checks before starting it.

-include_lib("kernel/include/inet.hrl").

-export([start/1, start_link/1, stop/0, members/0, distribution/0,
         resolve_dns/1, backoff_window/3]).

-define(NAME, beacon_cluster).
-define(MEMBERS, beacon_cluster_members).
-define(STOP_TIMEOUT_MS, 15000).

%% Start the manager unlinked from the caller (cluster.start).
start(ConfigRecord) ->
    case beacon_cluster_manager:start_link(config_map(ConfigRecord)) of
        {ok, Pid} ->
            true = unlink(Pid),
            {ok, nil};
        Error ->
            start_error(Error)
    end.

%% Start the manager linked to the caller, for a supervisor to own.
start_link(ConfigRecord) ->
    case beacon_cluster_manager:start_link(config_map(ConfigRecord)) of
        {ok, Pid} -> {ok, Pid};
        Error -> start_error(Error)
    end.

start_error({error, {already_started, Pid}}) ->
    beacon_log_ffi:error(<<"beacon.cluster">>, "The cluster manager is already running as ~p", [Pid]),
    {error, already_started};
start_error({error, Reason}) ->
    beacon_log_ffi:error(<<"beacon.cluster">>, "Cluster manager failed to start: ~p", [Reason]),
    {error, {start_failed, format(Reason)}};
start_error(ignore) ->
    beacon_log_ffi:error(<<"beacon.cluster">>, "Cluster manager init returned ignore"),
    {error, {start_failed, <<"init returned ignore">>}}.

stop() ->
    case whereis(?NAME) of
        undefined ->
            {error, not_started};
        Pid ->
            beacon_log_ffi:info(<<"beacon.cluster">>, "Stopping the cluster manager"),
            try gen_server:stop(Pid, normal, ?STOP_TIMEOUT_MS) of
                ok ->
                    beacon_log_ffi:info(<<"beacon.cluster">>, "Cluster manager stopped"),
                    {ok, nil}
            catch
                exit:noproc ->
                    beacon_log_ffi:warning(<<"beacon.cluster">>, "The cluster manager was already stopping"),
                    {error, not_started};
                exit:Reason ->
                    beacon_log_ffi:error(<<"beacon.cluster">>, "Cluster manager did not stop: ~p", [Reason]),
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

%% {Alive, ProtoDist, CookieBytes}. The cookie itself never leaves here.
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
    {distribution, Alive, Proto, CookieBytes}.

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
    {Low, High} = beacon_cluster_manager:backoff_window(Attempt, InitialMs, MaxMs),
    {backoff_window, Low, High}.

%% The Gleam ManagerConfig record, as the manager's map.
config_map({manager_config, Discovery, Mac, CheckTimeoutMs, InitialMs, MaxMs, Resolver,
            ResolveTimeoutMs, MaxDnsNodes}) ->
    #{discovery => discovery(Discovery),
      mac => Mac,
      check_timeout_ms => CheckTimeoutMs,
      initial_ms => InitialMs,
      max_ms => MaxMs,
      resolver => Resolver,
      resolve_timeout_ms => ResolveTimeoutMs,
      max_dns_nodes => MaxDnsNodes}.

%% Static node names were validated (count and length bounded) by
%% beacon/cluster, so creating their atoms is bounded too.
discovery({static, Nodes}) -> {static, [binary_to_atom(N) || N <- Nodes]};
discovery({dns, Query, Base, PollMs}) -> {dns, Query, Base, PollMs};
discovery(no_discovery) -> no_discovery.

format(Term) -> unicode:characters_to_binary(io_lib:format("~0p", [Term])).
