-module(beacon_http_client_ffi).
-export([start_httpc/0, http_get/1, http_request/4, ws_connect/2, ws_connect_with_headers/3, ws_send/2, ws_recv/2, ws_close/1, ws_close_graceful/2]).

%% Start the inets application (required for httpc).
start_httpc() ->
    inets:start(),
    ssl:start(),
    nil.

%% Make a real HTTP GET request. Returns {ok, {Status, Headers, Body}} or {error, Reason}.
http_get(Url) ->
    UrlStr = binary_to_list(Url),
    case httpc:request(get, {UrlStr, []}, [{timeout, 5000}], [{body_format, binary}]) of
        {ok, {{_, Status, _}, Headers, Body}} ->
            HeadersBin = [{list_to_binary(K), list_to_binary(V)} || {K, V} <- Headers],
            {ok, {Status, HeadersBin, Body}};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Make a raw HTTP request with explicit method, headers, and body.
%% Returns {ok, {Status, Headers, Body}} or {error, Reason}.
http_request(Method, Url, Headers, Body) ->
    MethodBin = ensure_binary(Method),
    UrlMap = uri_string:parse(binary_to_list(ensure_binary(Url))),
    HostBin = list_to_binary(maps:get(host, UrlMap, "localhost")),
    Port = maps:get(port, UrlMap, 80),
    Path0 = list_to_binary(maps:get(path, UrlMap, "/")),
    Query = maps:get(query, UrlMap, undefined),
    Target = case Query of
        undefined -> Path0;
        "" -> Path0;
        _ -> <<Path0/binary, "?", (list_to_binary(Query))/binary>>
    end,
    BodyBin = ensure_binary(Body),
    HeaderLines = render_headers(Headers),
    case gen_tcp:connect(binary_to_list(HostBin), Port, [binary, {active, false}, {packet, raw}], 5000) of
        {ok, Socket} ->
            Request = iolist_to_binary([
                MethodBin, <<" ">>, Target, <<" HTTP/1.1\r\n">>,
                <<"Host: ">>, HostBin, <<":">>, integer_to_binary(Port), <<"\r\n">>,
                HeaderLines,
                <<"Content-Length: ">>, integer_to_binary(byte_size(BodyBin)), <<"\r\n">>,
                <<"Connection: close\r\n">>,
                <<"\r\n">>,
                BodyBin
            ]),
            case gen_tcp:send(Socket, Request) of
                ok ->
                    case recv_all(Socket, <<>>) of
                        {ok, Data} ->
                            gen_tcp:close(Socket),
                            parse_http_response(Data);
                        {error, Reason} ->
                            gen_tcp:close(Socket),
                            {error, list_to_binary(io_lib:format("recv failed: ~p", [Reason]))}
                    end;
                {error, Reason} ->
                    gen_tcp:close(Socket),
                    {error, list_to_binary(io_lib:format("send failed: ~p", [Reason]))}
            end;
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("connect failed: ~p", [Reason]))}
    end.

%% Open a real WebSocket connection via gen_tcp + HTTP upgrade handshake.
%% One attempt: a refused, failed or non-101 handshake is an error that
%% names its cause. There is no retry; a test that needs a server to be
%% ready waits for that, and a flaky connect is a bug to find, not hide.
ws_connect(Host, Port) ->
    ws_connect_with_headers(Host, Port, []).

ws_connect_with_headers(Host, Port, Headers) ->
    HostStr = binary_to_list(Host),
    case gen_tcp:connect(HostStr, Port, [binary, {active, false}, {packet, raw}], 5000) of
        {ok, Socket} ->
            Key = base64:encode(crypto:strong_rand_bytes(16)),
            Req = iolist_to_binary([
                <<"GET /ws?path=%2F HTTP/1.1\r\n">>,
                <<"Host: ">>, Host, <<"\r\n">>,
                render_headers(Headers),
                <<"Origin: http://">>, Host, <<"\r\n">>,
                <<"Upgrade: websocket\r\n">>,
                <<"Connection: Upgrade\r\n">>,
                <<"Sec-WebSocket-Key: ">>, Key, <<"\r\n">>,
                <<"Sec-WebSocket-Version: 13\r\n">>,
                <<"\r\n">>
            ]),
            Deadline = erlang:monotonic_time(millisecond) + 5000,
            Result = case gen_tcp:send(Socket, Req) of
                ok -> recv_handshake(Socket, Key, Deadline);
                {error, Reason} -> {error, list_to_binary(io_lib:format("send: ~p", [Reason]))}
            end,
            case Result of
                ok -> {ok, Socket};
                {error, _} = Error ->
                    gen_tcp:close(Socket),
                    Error
            end;
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("connect: ~p", [Reason]))}
    end.

%% Read the handshake response with the kernel's HTTP packet parser, which
%% consumes exactly the status line and headers: bytes after the blank
%% line stay in the socket buffer for the frame reader. A response split
%% across TCP segments is therefore read whole, and frame bytes that share
%% a segment with it are not lost. The 101 must carry the
%% Sec-WebSocket-Accept that RFC 6455 4.2.2 derives from our key.
recv_handshake(Socket, Key, Deadline) ->
    ok = inet:setopts(Socket, [{packet, http_bin}]),
    Result = case gen_tcp:recv(Socket, 0, remaining(Deadline)) of
        {ok, {http_response, _Version, 101, _Phrase}} ->
            case recv_headers(Socket, Deadline, #{}) of
                {ok, Headers} -> check_accept(Key, Headers);
                {error, _} = Error -> Error
            end;
        {ok, {http_response, _Version, Status, Phrase}} ->
            {error, iolist_to_binary(io_lib:format("upgrade_failed: ~b ~s", [Status, Phrase]))};
        {ok, Other} ->
            {error, iolist_to_binary(io_lib:format("upgrade_failed: unexpected ~0p", [Other]))};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("recv: ~p", [Reason]))}
    end,
    %% Back to raw bytes for the frame reader.
    case Result of
        ok -> ok = inet:setopts(Socket, [{packet, raw}]), ok;
        _ -> Result
    end.

recv_headers(Socket, Deadline, Acc) ->
    case gen_tcp:recv(Socket, 0, remaining(Deadline)) of
        {ok, http_eoh} -> {ok, Acc};
        {ok, {http_header, _, Name, _, Value}} ->
            recv_headers(Socket, Deadline, Acc#{header_name(Name) => Value});
        {ok, Other} ->
            {error, iolist_to_binary(io_lib:format("handshake header: unexpected ~0p", [Other]))};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("recv headers: ~p", [Reason]))}
    end.

header_name(Name) when is_atom(Name) -> string:lowercase(atom_to_binary(Name));
header_name(Name) when is_binary(Name) -> string:lowercase(Name).

check_accept(Key, Headers) ->
    Expected = base64:encode(crypto:hash(sha, <<Key/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>)),
    case maps:find(<<"sec-websocket-accept">>, Headers) of
        {ok, Expected} -> ok;
        {ok, Other} ->
            {error, <<"handshake: Sec-WebSocket-Accept ", Other/binary, " does not match the key">>};
        error ->
            {error, <<"handshake: 101 without Sec-WebSocket-Accept">>}
    end.

remaining(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).

%% Send a WebSocket text frame. Returns {ok, nil} or {error, Reason}.
ws_send(Socket, Payload) ->
    PayloadBin = if is_binary(Payload) -> Payload; true -> list_to_binary(Payload) end,
    send_frame(Socket, 1, PayloadBin).

%% Send one masked, unfragmented client frame with the given opcode.
send_frame(Socket, Opcode, PayloadBin) ->
    Len = byte_size(PayloadBin),
    %% Client frames MUST be masked (RFC 6455)
    MaskKey = crypto:strong_rand_bytes(4),
    <<M1, M2, M3, M4>> = MaskKey,
    MaskedPayload = mask_payload(PayloadBin, M1, M2, M3, M4, 0, <<>>),
    Frame = if
        Len < 126 ->
            <<1:1, 0:3, Opcode:4, 1:1, Len:7, MaskKey/binary, MaskedPayload/binary>>;
        Len < 65536 ->
            <<1:1, 0:3, Opcode:4, 1:1, 126:7, Len:16, MaskKey/binary, MaskedPayload/binary>>;
        true ->
            <<1:1, 0:3, Opcode:4, 1:1, 127:7, Len:64, MaskKey/binary, MaskedPayload/binary>>
    end,
    case gen_tcp:send(Socket, Frame) of
        ok -> {ok, nil};
        {error, Reason} -> {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Receive the next WebSocket data frame's payload within Timeout ms.
%%
%% Frames are read exactly: the 2-byte header, the extended length, then
%% the payload, each with gen_tcp:recv/3 and an exact byte count. Several
%% frames that arrive in one TCP segment are therefore returned one per
%% call, never merged or dropped. A ping is answered with a pong and a
%% pong is skipped (both are control frames, not responses). A close frame,
%% a fragmented or masked server frame, or an unknown opcode is an error
%% that names it.
ws_recv(Socket, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case recv_frame(Socket, Deadline) of
        {data, Payload} -> {ok, Payload};
        {close, Code, Reason} -> {error, close_text(Code, Reason)};
        {error, _} = Error -> Error
    end.

%% Close the connection the way a browser does (RFC 6455 5.5.1): send a
%% close frame with code 1000, read until the server's close frame, then
%% close the TCP socket. Data frames still in flight before the server's
%% close are discarded: the client has said it is leaving. The server
%% must answer with 1000; any other code, or no answer within Timeout ms,
%% is an error. The socket is closed in every case.
ws_close_graceful(Socket, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Result = case send_frame(Socket, 8, <<1000:16>>) of
        {ok, nil} -> await_close(Socket, Deadline);
        {error, Reason} -> {error, <<"sending close: ", Reason/binary>>}
    end,
    gen_tcp:close(Socket),
    Result.

await_close(Socket, Deadline) ->
    case recv_frame(Socket, Deadline) of
        {data, _InFlight} -> await_close(Socket, Deadline);
        {close, 1000, _Reason} -> {ok, nil};
        {close, Code, Reason} ->
            {error, <<"close handshake: ", (close_text(Code, Reason))/binary>>};
        {error, Reason} -> {error, <<"close handshake: ", Reason/binary>>}
    end.

close_text(none, _Reason) -> <<"server closed: no status">>;
close_text(Code, Reason) ->
    iolist_to_binary(io_lib:format("server closed: ~b ~ts", [Code, Reason])).

%% Read one frame: {data, Payload}, {close, Code | none, Reason} or
%% {error, Reason}. Pings are answered and pongs skipped here.
recv_frame(Socket, Deadline) ->
    case recv_exact(Socket, 2, Deadline) of
        {ok, <<Fin:1, _Rsv:3, Opcode:4, Masked:1, Len7:7>>} ->
            case recv_length(Socket, Len7, Deadline) of
                {ok, Len} ->
                    case recv_exact(Socket, Len, Deadline) of
                        {ok, Payload} -> on_frame(Socket, Deadline, Fin, Opcode, Masked, Payload);
                        {error, Reason} -> recv_error("payload", Reason)
                    end;
                {error, Reason} -> recv_error("length", Reason)
            end;
        {error, Reason} -> recv_error("header", Reason)
    end.

on_frame(_Socket, _Deadline, _Fin, _Opcode, 1, _Payload) ->
    {error, <<"server sent a masked frame (RFC 6455 5.1)">>};
on_frame(_Socket, _Deadline, 0, Opcode, 0, _Payload) ->
    {error, iolist_to_binary(io_lib:format(
        "server sent a fragmented frame (opcode ~b); the test client does not reassemble", [Opcode]))};
on_frame(_Socket, _Deadline, 1, Opcode, 0, Payload) when Opcode =:= 1; Opcode =:= 2 ->
    {data, Payload};
on_frame(Socket, Deadline, 1, 9, 0, Payload) ->
    case send_frame(Socket, 10, Payload) of
        {ok, nil} -> recv_frame(Socket, Deadline);
        {error, Reason} -> {error, <<"pong failed: ", Reason/binary>>}
    end;
on_frame(Socket, Deadline, 1, 10, 0, _Payload) ->
    recv_frame(Socket, Deadline);
on_frame(_Socket, _Deadline, 1, 8, 0, <<Code:16, Reason/binary>>) ->
    {close, Code, Reason};
on_frame(_Socket, _Deadline, 1, 8, 0, <<>>) ->
    {close, none, <<>>};
on_frame(_Socket, _Deadline, 1, 8, 0, Payload) ->
    {error, iolist_to_binary(io_lib:format("server sent a malformed close payload ~0p", [Payload]))};
on_frame(_Socket, _Deadline, _Fin, Opcode, 0, _Payload) ->
    {error, iolist_to_binary(io_lib:format("server sent unexpected opcode ~b", [Opcode]))}.

recv_length(_Socket, Len7, _Deadline) when Len7 < 126 -> {ok, Len7};
recv_length(Socket, 126, Deadline) ->
    case recv_exact(Socket, 2, Deadline) of
        {ok, <<Len:16>>} -> {ok, Len};
        {error, Reason} -> {error, Reason}
    end;
recv_length(Socket, 127, Deadline) ->
    case recv_exact(Socket, 8, Deadline) of
        {ok, <<Len:64>>} -> {ok, Len};
        {error, Reason} -> {error, Reason}
    end.

recv_exact(_Socket, 0, _Deadline) -> {ok, <<>>};
recv_exact(Socket, N, Deadline) ->
    gen_tcp:recv(Socket, N, remaining(Deadline)).

recv_error(Part, Reason) ->
    {error, iolist_to_binary(io_lib:format("~p (reading frame ~s)", [Reason, Part]))}.

%% Drop the TCP connection without a close frame (an abrupt disconnect:
%% a crashed tab, a lost network).
ws_close(Socket) ->
    gen_tcp:close(Socket),
    nil.

render_headers(Headers) ->
    iolist_to_binary([
        [ensure_binary(K), <<": ">>, ensure_binary(V), <<"\r\n">>]
        || {K, V} <- Headers
    ]).

ensure_binary(Value) when is_binary(Value) -> Value;
ensure_binary(Value) when is_list(Value) -> list_to_binary(Value);
ensure_binary(Value) -> list_to_binary(io_lib:format("~p", [Value])).

recv_all(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Data} -> recv_all(Socket, <<Acc/binary, Data/binary>>);
        {error, closed} -> {ok, Acc};
        {error, Reason} -> {error, Reason}
    end.

parse_http_response(Data) ->
    case binary:split(Data, <<"\r\n\r\n">>) of
        [HeaderBlock, Body] ->
            Headers = binary:split(HeaderBlock, <<"\r\n">>, [global]),
            Status = parse_status(Headers),
            HeaderPairs = parse_headers(tl(Headers), []),
            {ok, {Status, HeaderPairs, Body}};
        _ ->
            {error, <<"malformed HTTP response">>}
    end.

parse_status([StatusLine | _]) ->
    case binary:split(StatusLine, <<" ">>, [global]) of
        [_, StatusCode | _] -> binary_to_integer(StatusCode);
        _ -> 0
    end;
parse_status([]) -> 0.

parse_headers([], Acc) ->
    lists:reverse(Acc);
parse_headers([Line | Rest], Acc) ->
    case binary:split(Line, <<": ">>) of
        [Name, Value] -> parse_headers(Rest, [{Name, Value} | Acc]);
        _ -> parse_headers(Rest, Acc)
    end.

%% XOR mask payload bytes with the 4-byte mask key.
mask_payload(<<>>, _, _, _, _, _, Acc) -> Acc;
mask_payload(<<B, Rest/binary>>, M1, M2, M3, M4, N, Acc) ->
    Mask = case N rem 4 of
        0 -> M1;
        1 -> M2;
        2 -> M3;
        3 -> M4
    end,
    mask_payload(Rest, M1, M2, M3, M4, N + 1, <<Acc/binary, (B bxor Mask)>>).
