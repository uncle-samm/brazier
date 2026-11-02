-module(beacon_ws_test_ffi).
-export([
    receive_revoked/1,
    sleep_ms/1,
    raw_connect/2,
    raw_send/2,
    raw_recv_frame/2,
    raw_close/1,
    raw_upgrade_request/3,
    raw_frame/5,
    masked_frame/3,
    unmasked_frame/3,
    expect_closed/2,
    is_alive/1,
    pid_from_term/1,
    process_count/0,
    recv_buffer_small_connect/2,
    run_parallel/2,
    monotonic_us/0
]).

%% Wait for a session revocation message in the calling process.
receive_revoked(TimeoutMs) ->
    receive
        {beacon_session_revoked, SessionId, Reason} -> {ok, {SessionId, Reason}}
    after TimeoutMs ->
        {error, nil}
    end.

sleep_ms(Ms) ->
    timer:sleep(Ms),
    nil.

%% --- Raw TCP WebSocket client ---

raw_connect(Host, Port) ->
    case gen_tcp:connect(binary_to_list(Host), Port,
                         [binary, {active, false}, {packet, raw}], 5000) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, format(Reason)}
    end.

%% A client with a tiny receive buffer that never reads: used to apply
%% backpressure to the server's send path.
recv_buffer_small_connect(Host, Port) ->
    case gen_tcp:connect(binary_to_list(Host), Port,
                         [binary, {active, false}, {packet, raw},
                          {recbuf, 1024}, {buffer, 1024}], 5000) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, format(Reason)}
    end.

raw_send(Socket, Bytes) ->
    case gen_tcp:send(Socket, Bytes) of
        ok -> {ok, nil};
        {error, Reason} -> {error, format(Reason)}
    end.

raw_close(Socket) ->
    gen_tcp:close(Socket),
    nil.

%% Build an upgrade request with explicit header list.
raw_upgrade_request(Path, Host, Headers) ->
    iolist_to_binary([
        <<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
        <<"Host: ">>, Host, <<"\r\n">>,
        [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- Headers],
        <<"\r\n">>
    ]).

%% Read one HTTP response head (for upgrade) or one server frame.
%% Returns {ok, {Opcode, Payload}} for frames. For non-frame data (HTTP),
%% returns {ok, {-1, Data}}.
raw_recv_frame(Socket, Timeout) ->
    case get_buffer(Socket) of
        <<"HTTP/", _/binary>> = Buf ->
            read_http(Socket, Buf, Timeout);
        Buf ->
            read_frame(Socket, Buf, Timeout)
    end.

get_buffer(Socket) ->
    case erlang:get({ws_buf, Socket}) of
        undefined -> <<>>;
        B -> B
    end.

put_buffer(Socket, B) ->
    erlang:put({ws_buf, Socket}, B).

read_http(Socket, Buf, Timeout) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            put_buffer(Socket, Rest),
            {ok, {-1, Head}};
        [_] ->
            case gen_tcp:recv(Socket, 0, Timeout) of
                {ok, More} -> read_http(Socket, <<Buf/binary, More/binary>>, Timeout);
                {error, Reason} -> {error, format(Reason)}
            end
    end.

read_frame(Socket, <<>>, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, <<"HTTP/", _/binary>> = Data} -> read_http(Socket, Data, Timeout);
        {ok, Data} -> read_frame(Socket, Data, Timeout);
        {error, Reason} -> {error, format(Reason)}
    end;
read_frame(Socket, Buf, Timeout) ->
    case parse(Buf) of
        {ok, Opcode, Payload, Rest} ->
            put_buffer(Socket, Rest),
            {ok, {Opcode, Payload}};
        more ->
            case gen_tcp:recv(Socket, 0, Timeout) of
                {ok, More} -> read_frame(Socket, <<Buf/binary, More/binary>>, Timeout);
                {error, Reason} -> {error, format(Reason)}
            end
    end.

parse(<<_:4, Op:4, 0:1, 127:7, Len:64, Rest/binary>>) -> take(Op, Len, Rest);
parse(<<_:4, Op:4, 0:1, 126:7, Len:16, Rest/binary>>) -> take(Op, Len, Rest);
parse(<<_:4, Op:4, 0:1, Len:7, Rest/binary>>) when Len < 126 -> take(Op, Len, Rest);
parse(_) -> more.

take(Op, Len, Rest) when byte_size(Rest) >= Len ->
    <<Payload:Len/binary, Tail/binary>> = Rest,
    {ok, Op, Payload, Tail};
take(_, _, _) -> more.

%% Wait until the server closes the TCP connection. Drains any frames.
%% Returns {ok, CloseCode} where CloseCode is the code from a received close
%% frame (or -1 if the socket closed without one), or {error, timeout}.
expect_closed(Socket, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    expect_closed_loop(Socket, Deadline, -1).

expect_closed_loop(Socket, Deadline, Code) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true -> {error, <<"timeout">>};
        false ->
            case raw_recv_frame(Socket, Remaining) of
                {ok, {8, <<C:16, _/binary>>}} -> expect_closed_loop(Socket, Deadline, C);
                {ok, {8, <<>>}} -> expect_closed_loop(Socket, Deadline, 1005);
                {ok, _Other} -> expect_closed_loop(Socket, Deadline, Code);
                {error, <<"closed">>} -> {ok, Code};
                {error, <<"timeout">>} -> {error, <<"timeout">>};
                {error, Other} -> {error, Other}
            end
    end.

%% Build an arbitrary client frame. Fin and Rsv are integers, Masked is a bool.
raw_frame(Fin, Rsv, Opcode, Masked, Payload) ->
    Len = byte_size(Payload),
    MaskBit = case Masked of true -> 1; false -> 0 end,
    LenBits = if
        Len < 126 -> <<MaskBit:1, Len:7>>;
        Len < 65536 -> <<MaskBit:1, 126:7, Len:16>>;
        true -> <<MaskBit:1, 127:7, Len:64>>
    end,
    case Masked of
        true ->
            Key = crypto:strong_rand_bytes(4),
            <<Fin:1, Rsv:3, Opcode:4, LenBits/binary, Key/binary,
              (mask(Payload, Key))/binary>>;
        false ->
            <<Fin:1, Rsv:3, Opcode:4, LenBits/binary, Payload/binary>>
    end.

masked_frame(Fin, Opcode, Payload) ->
    raw_frame(Fin, 0, Opcode, true, Payload).

unmasked_frame(Fin, Opcode, Payload) ->
    raw_frame(Fin, 0, Opcode, false, Payload).

mask(Payload, <<K1, K2, K3, K4>>) ->
    mask(Payload, {K1, K2, K3, K4}, 0, <<>>).

mask(<<>>, _, _, Acc) -> Acc;
mask(<<B, Rest/binary>>, {K1, K2, K3, K4} = K, N, Acc) ->
    M = element((N rem 4) + 1, {K1, K2, K3, K4}),
    mask(Rest, K, N + 1, <<Acc/binary, (B bxor M)>>).

is_alive(Pid) when is_pid(Pid) -> erlang:is_process_alive(Pid).

%% Extract a pid from a dynamic value (e.g. a Gleam Subject record).
pid_from_term(Pid) when is_pid(Pid) -> {ok, Pid};
pid_from_term(T) when is_tuple(T) ->
    case [E || E <- tuple_to_list(T), is_pid(E)] of
        [P | _] -> {ok, P};
        [] -> {error, nil}
    end;
pid_from_term(_) -> {error, nil}.

process_count() ->
    erlang:system_info(process_count).

monotonic_us() ->
    erlang:monotonic_time(microsecond).

%% Run Fun(I) for I in 1..N in parallel processes; wait for all.
%% Returns the list of results in index order.
run_parallel(N, Fun) ->
    Parent = self(),
    Refs = [begin
                Ref = make_ref(),
                spawn(fun() -> Parent ! {Ref, Fun(I)} end),
                Ref
            end || I <- lists:seq(1, N)],
    [receive {Ref, R} -> R after 60000 -> error(run_parallel_timeout) end || Ref <- Refs].

format(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
format(Reason) -> list_to_binary(io_lib:format("~p", [Reason])).
