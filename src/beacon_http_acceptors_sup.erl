-module(beacon_http_acceptors_sup).
%% Supervisor that owns the listen socket and the acceptor pool for one
%% Beacon HTTP listener. Modelled on ranch_acceptors_sup: the listen socket
%% is opened in init/1 so it lives exactly as long as this supervisor, and
%% acceptors are permanent children restarted (and reported by the
%% supervisor) if they crash.
%%
%% The bound port is stored in the connection owner after the first bind,
%% so a restart of this supervisor rebinds the SAME port even when the
%% listener was started on port 0.
-behaviour(supervisor).

-export([start_link/4, start_link_gleam/4]).
-export([init/1]).

start_link(ConnsName, NumAcceptors, Backlog, SendTimeoutMs) ->
    supervisor:start_link(?MODULE, {ConnsName, NumAcceptors, Backlog, SendTimeoutMs}).

%% Gleam supervision start shape: {ok, {started, Pid, nil}} | {error, StartError}.
start_link_gleam(ConnsName, NumAcceptors, Backlog, SendTimeoutMs) ->
    case start_link(ConnsName, NumAcceptors, Backlog, SendTimeoutMs) of
        {ok, Pid} -> {ok, {started, Pid, nil}};
        {error, Reason} -> {error, {init_failed, format(Reason)}};
        ignore -> {error, {init_failed, <<"acceptor supervisor returned ignore">>}}
    end.

init({ConnsName, NumAcceptors, Backlog, SendTimeoutMs}) ->
    true = is_integer(NumAcceptors) andalso NumAcceptors > 0,
    true = is_integer(Backlog) andalso Backlog > 0,
    true = is_integer(SendTimeoutMs) andalso SendTimeoutMs > 0,
    Port = beacon_http_conns:get_port(ConnsName),
    Opts = [
        binary,
        {active, false},
        {packet, raw},
        {reuseaddr, true},
        {backlog, Backlog},
        {nodelay, true},
        {send_timeout, SendTimeoutMs},
        {send_timeout_close, true}
    ],
    case gen_tcp:listen(Port, Opts) of
        {ok, ListenSocket} ->
            case inet:port(ListenSocket) of
                {ok, BoundPort} ->
                    ok = beacon_http_conns:set_port(ConnsName, BoundPort),
                    logger:info("beacon.http_acceptors listening on port ~p with ~p acceptors",
                                [BoundPort, NumAcceptors]),
                    Children = [
                        #{id => {acceptor, Id},
                          start => {beacon_http_acceptor, start_link, [ListenSocket, ConnsName, Id]},
                          restart => permanent,
                          shutdown => brutal_kill,
                          type => worker}
                        || Id <- lists:seq(1, NumAcceptors)
                    ],
                    Intensity = 1 + ceil(math:log2(NumAcceptors)),
                    {ok, {#{strategy => one_for_one, intensity => Intensity, period => 5},
                          Children}};
                {error, Reason} ->
                    logger:error("beacon.http_acceptors could not read bound port: ~p", [Reason]),
                    gen_tcp:close(ListenSocket),
                    {error, {bound_port_unavailable, Reason}}
            end;
        {error, Reason} ->
            logger:error("beacon.http_acceptors failed to listen on port ~p: ~p", [Port, Reason]),
            {error, {listen_failed, Port, Reason}}
    end.

format(Reason) when is_binary(Reason) -> Reason;
format(Reason) -> list_to_binary(io_lib:format("~p", [Reason])).
