-module(beacon_client_ip_test_ffi).
%% Helpers for client-IP / rate-limit middleware tests: a real accepted
%% loopback socket (so peername works) and requests that carry it.
-export([loopback_socket/0, make_request/4, dead_socket/0]).

%% The server side of a fresh loopback connection. Its peer is 127.0.0.1.
%% The listening and client sockets are owned by a helper process that
%% lives as long as the caller, so the accepted socket stays connected.
loopback_socket() ->
    Caller = self(),
    Helper = spawn(fun() ->
        {ok, Listen} = gen_tcp:listen(0, [binary, {active, false},
                                          {ip, {127, 0, 0, 1}}]),
        {ok, Port} = inet:port(Listen),
        {ok, Client} = gen_tcp:connect({127, 0, 0, 1}, Port,
                                       [binary, {active, false}]),
        {ok, Server} = gen_tcp:accept(Listen, 2000),
        ok = gen_tcp:controlling_process(Server, Caller),
        Caller ! {loopback, self(), Server},
        MRef = erlang:monitor(process, Caller),
        receive {'DOWN', MRef, process, _, _} -> ok end,
        gen_tcp:close(Client),
        gen_tcp:close(Listen)
    end),
    receive
        {loopback, Helper, Server} -> Server
    after 2000 ->
        erlang:error(loopback_socket_timeout)
    end.

%% A socket that has been closed: peername fails on it.
dead_socket() ->
    Socket = loopback_socket(),
    ok = gen_tcp:close(Socket),
    Socket.

%% Request(method, headers, body, scheme, host, port, path, query) with a
%% server.Connection(socket:) body.
make_request(MethodBin, Path, Headers, Socket) ->
    Method = case MethodBin of
        <<"GET">> -> get;
        <<"POST">> -> post;
        _ -> {other, MethodBin}
    end,
    {request, Method, Headers, {connection, Socket}, http, <<"localhost">>,
     {some, 80}, Path, none}.
