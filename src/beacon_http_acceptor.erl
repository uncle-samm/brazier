-module(beacon_http_acceptor).
%% One acceptor of a Beacon HTTP listener. Modelled on ranch_acceptor:
%% accept, ask the connection owner (beacon_http_conns) for a slot and a
%% linked handler process, hand the socket over, repeat.
%%
%% The acceptor never runs request handling itself, so a crashing handler
%% can never take an acceptor down, and every handler is linked to the
%% connection owner (no orphans).
%%
%% Telemetry: the acceptor emits [beacon, http, connection, accepted] once
%% the connection owner grants a slot and [beacon, http, connection,
%% rejected] when it refuses one (or the peer address is unreadable).
%% `duration` is the native time from accept/1 returning to the decision.
%% Emitting here keeps handlers off the connection owner's hot path.
%% [beacon, http, connection, closed] is emitted by beacon_http_conns, the
%% only process that sees every handler exit.
-export([start_link/3]).
-export([loop/3]).

-define(EMFILE_BACKOFF_MS, 100).
-define(REJECT_SEND_TIMEOUT_MS, 1000).

start_link(ListenSocket, ConnsName, Id) ->
    Pid = proc_lib:spawn_link(?MODULE, loop, [ListenSocket, ConnsName, Id]),
    {ok, Pid}.

loop(ListenSocket, ConnsName, Id) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            handoff(Socket, ConnsName, erlang:monotonic_time()),
            loop(ListenSocket, ConnsName, Id);
        {error, Reason} when Reason =:= emfile; Reason =:= enfile ->
            logger:error("beacon.http_acceptor ~p out of file descriptors (~p), backing off ~pms",
                         [Id, Reason, ?EMFILE_BACKOFF_MS]),
            receive after ?EMFILE_BACKOFF_MS -> ok end,
            loop(ListenSocket, ConnsName, Id);
        {error, closed} ->
            logger:warning("beacon.http_acceptor ~p listen socket closed", [Id]),
            exit({shutdown, listen_socket_closed});
        {error, Reason} ->
            logger:warning("beacon.http_acceptor ~p accept failed: ~p", [Id, Reason]),
            loop(ListenSocket, ConnsName, Id)
    end.

handoff(Socket, ConnsName, AcceptedAt) ->
    case beacon_ip_ffi:peer_ip_tuple(Socket) of
        {ok, Ip} ->
            case beacon_http_conns:start_connection(ConnsName, Ip) of
                {ok, Pid} ->
                    beacon_telemetry_ffi:http_connection(
                        accepted, erlang:monotonic_time() - AcceptedAt, <<"ok">>),
                    case gen_tcp:controlling_process(Socket, Pid) of
                        ok ->
                            Pid ! {beacon_http_shoot, Socket},
                            ok;
                        {error, Reason} ->
                            logger:warning("beacon.http_acceptor socket handoff failed: ~p", [Reason]),
                            Pid ! {beacon_http_abort, Reason},
                            gen_tcp:close(Socket)
                    end;
                {error, Limit} ->
                    logger:warning("beacon.http_acceptor rejecting connection from ~s: ~p",
                                   [inet:ntoa(Ip), Limit]),
                    beacon_telemetry_ffi:http_connection(
                        rejected, erlang:monotonic_time() - AcceptedAt, limit_reason(Limit)),
                    reject(Socket)
            end;
        {error, Reason} ->
            logger:warning("beacon.http_acceptor dropping connection: ~s", [Reason]),
            beacon_telemetry_ffi:http_connection(
                rejected, erlang:monotonic_time() - AcceptedAt, <<"peer_address_unavailable">>),
            gen_tcp:close(Socket)
    end.

%% The connection owner refuses a slot with exactly these limits.
limit_reason(max_connections) -> <<"max_connections">>;
limit_reason(max_connections_per_ip) -> <<"max_connections_per_ip">>.

%% Answer 503 without reading the request, then close. The short send
%% timeout keeps a non-reading client from stalling the acceptor.
reject(Socket) ->
    Body = <<"Too many connections">>,
    Response = [
        <<"HTTP/1.1 503 Service Unavailable\r\n">>,
        <<"content-type: text/plain; charset=utf-8\r\n">>,
        <<"x-content-type-options: nosniff\r\n">>,
        <<"connection: close\r\n">>,
        <<"retry-after: 1\r\n">>,
        <<"content-length: ">>, integer_to_binary(byte_size(Body)), <<"\r\n\r\n">>,
        Body
    ],
    case inet:setopts(Socket, [{send_timeout, ?REJECT_SEND_TIMEOUT_MS}]) of
        ok -> ok;
        {error, SetoptsReason} ->
            logger:warning("beacon.http_acceptor setopts before reject failed: ~p", [SetoptsReason])
    end,
    case gen_tcp:send(Socket, Response) of
        ok -> ok;
        {error, SendReason} ->
            logger:warning("beacon.http_acceptor failed to send 503: ~p", [SendReason])
    end,
    gen_tcp:close(Socket).
