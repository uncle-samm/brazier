-module(beacon_http_bench_ffi).
%% Keep-alive HTTP load generator for beacon_http_bench.
%%
%% Each client opens one TCP connection and sends Requests sequential
%% `GET /bench` requests on it, reading each response completely (the
%% server answers with a content-length) before sending the next one.
-export([run/3, now_us/0]).

-define(RECV_TIMEOUT_MS, 5000).

now_us() -> erlang:monotonic_time(microsecond).

%% Run Clients concurrent keep-alive clients against Port, each sending
%% Requests requests. Returns the wall-clock time in microseconds; crashes
%% if any client fails, so a broken server never produces a number.
run(Port, Clients, Requests) ->
    Parent = self(),
    Start = now_us(),
    Refs = [begin
                Ref = make_ref(),
                spawn_link(fun() -> Parent ! {Ref, client(Port, Requests)} end),
                Ref
            end || _ <- lists:seq(1, Clients)],
    [receive {Ref, ok} -> ok after 60000 -> erlang:error(bench_client_timeout) end
     || Ref <- Refs],
    now_us() - Start.

client(Port, Requests) ->
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port,
                                   [binary, {active, false}, {packet, raw}, {nodelay, true}],
                                   ?RECV_TIMEOUT_MS),
    Request = <<"GET /bench HTTP/1.1\r\nHost: bench\r\n\r\n">>,
    ok = loop(Socket, Request, Requests),
    ok = gen_tcp:close(Socket),
    ok.

loop(_Socket, _Request, 0) -> ok;
loop(Socket, Request, N) ->
    ok = gen_tcp:send(Socket, Request),
    ok = read_response(Socket, <<>>),
    loop(Socket, Request, N - 1).

read_response(Socket, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Body] ->
            Length = content_length(Head),
            read_body(Socket, byte_size(Body), Length);
        [_] ->
            {ok, Data} = gen_tcp:recv(Socket, 0, ?RECV_TIMEOUT_MS),
            read_response(Socket, <<Acc/binary, Data/binary>>)
    end.

read_body(_Socket, Have, Length) when Have =:= Length -> ok;
read_body(Socket, Have, Length) when Have < Length ->
    {ok, Data} = gen_tcp:recv(Socket, 0, ?RECV_TIMEOUT_MS),
    read_body(Socket, Have + byte_size(Data), Length).

content_length(Head) ->
    Lines = binary:split(Head, <<"\r\n">>, [global]),
    [Value] = [V || L <- Lines,
                    [K, V] <- [binary:split(L, <<": ">>)],
                    string:lowercase(K) =:= <<"content-length">>],
    binary_to_integer(Value).
