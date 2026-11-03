-module(beacon_http_client_ffi).
-export([start_httpc/0, http_get/1, http_request/4, ws_connect/2, ws_connect_with_headers/3, ws_connect_no_retry/2, ws_send/2, ws_recv/2, ws_close/1]).

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
ws_connect(Host, Port) ->
    ws_connect(Host, Port, 1).

ws_connect(Host, Port, Attempt) ->
    HostStr = binary_to_list(Host),
    case gen_tcp:connect(HostStr, Port, [binary, {active, false}, {packet, raw}], 5000) of
        {ok, Socket} ->
            %% Send WebSocket upgrade request
            Key = base64:encode(crypto:strong_rand_bytes(16)),
            Req = iolist_to_binary([
                <<"GET /ws?path=%2F HTTP/1.1\r\n">>,
                <<"Host: ">>, Host, <<"\r\n">>,
                <<"Origin: http://">>, Host, <<"\r\n">>,
                <<"Upgrade: websocket\r\n">>,
                <<"Connection: Upgrade\r\n">>,
                <<"Sec-WebSocket-Key: ">>, Key, <<"\r\n">>,
                <<"Sec-WebSocket-Version: 13\r\n">>,
                <<"\r\n">>
            ]),
            ok = gen_tcp:send(Socket, Req),
            %% Read response (101 Switching Protocols)
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Response} ->
                    case binary:match(Response, <<"101">>) of
                        {_, _} -> {ok, Socket};
                        nomatch ->
                            gen_tcp:close(Socket),
                            maybe_retry(Host, Port, Attempt, <<"upgrade_failed">>)
                    end;
                {error, Reason} ->
                    gen_tcp:close(Socket),
                    maybe_retry(Host, Port, Attempt, list_to_binary(io_lib:format("recv: ~p", [Reason])))
            end;
        {error, Reason} ->
            maybe_retry(Host, Port, Attempt, list_to_binary(io_lib:format("connect: ~p", [Reason])))
    end.

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
            ok = gen_tcp:send(Socket, Req),
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Response} ->
                    case binary:match(Response, <<"101">>) of
                        {_, _} -> {ok, Socket};
                        nomatch ->
                            gen_tcp:close(Socket),
                            {error, <<"upgrade_failed">>}
                    end;
                {error, Reason} ->
                    gen_tcp:close(Socket),
                    {error, list_to_binary(io_lib:format("recv: ~p", [Reason]))}
            end;
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("connect: ~p", [Reason]))}
    end.

%% Retry up to 3 times with exponential backoff — mirrors real client reconnect behavior.
%% Delays: 200ms, 400ms, 600ms. Real browsers use exponential backoff + jitter.
maybe_retry(_Host, _Port, Attempt, Reason) when Attempt >= 3 ->
    {error, Reason};
maybe_retry(Host, Port, Attempt, _Reason) ->
    %% Silent retry — normal during test startup when server isn't ready yet
    timer:sleep(Attempt * 200),
    ws_connect(Host, Port, Attempt + 1).

%% Single-attempt WebSocket connect — NO retry.
%% Used to test raw server availability without client-side mitigation.
ws_connect_no_retry(Host, Port) ->
    HostStr = binary_to_list(Host),
    case gen_tcp:connect(HostStr, Port, [binary, {active, false}, {packet, raw}], 5000) of
        {ok, Socket} ->
            Key = base64:encode(crypto:strong_rand_bytes(16)),
            Req = iolist_to_binary([
                <<"GET /ws?path=%2F HTTP/1.1\r\n">>,
                <<"Host: ">>, Host, <<"\r\n">>,
                <<"Origin: http://">>, Host, <<"\r\n">>,
                <<"Upgrade: websocket\r\n">>,
                <<"Connection: Upgrade\r\n">>,
                <<"Sec-WebSocket-Key: ">>, Key, <<"\r\n">>,
                <<"Sec-WebSocket-Version: 13\r\n">>,
                <<"\r\n">>
            ]),
            ok = gen_tcp:send(Socket, Req),
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Response} ->
                    case binary:match(Response, <<"101">>) of
                        {_, _} -> {ok, Socket};
                        nomatch ->
                            gen_tcp:close(Socket),
                            {error, <<"upgrade_failed">>}
                    end;
                {error, Reason} ->
                    gen_tcp:close(Socket),
                    {error, list_to_binary(io_lib:format("~p", [Reason]))}
            end;
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Send a WebSocket text frame. Returns {ok, nil} or {error, Reason}.
ws_send(Socket, Payload) ->
    PayloadBin = if is_binary(Payload) -> Payload; true -> list_to_binary(Payload) end,
    Len = byte_size(PayloadBin),
    %% Client frames MUST be masked (RFC 6455)
    MaskKey = crypto:strong_rand_bytes(4),
    <<M1, M2, M3, M4>> = MaskKey,
    MaskedPayload = mask_payload(PayloadBin, M1, M2, M3, M4, 0, <<>>),
    Frame = if
        Len < 126 ->
            <<1:1, 0:3, 1:4, 1:1, Len:7, MaskKey/binary, MaskedPayload/binary>>;
        Len < 65536 ->
            <<1:1, 0:3, 1:4, 1:1, 126:7, Len:16, MaskKey/binary, MaskedPayload/binary>>;
        true ->
            <<1:1, 0:3, 1:4, 1:1, 127:7, Len:64, MaskKey/binary, MaskedPayload/binary>>
    end,
    case gen_tcp:send(Socket, Frame) of
        ok -> {ok, nil};
        {error, Reason} -> {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Receive a WebSocket text frame (simplified — assumes unfragmented, unmasked server frame).
ws_recv(Socket, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} ->
            case Data of
                <<_Fin:1, _Rsv:3, _Opcode:4, 0:1, Len:7, Rest/binary>> when Len < 126 ->
                    <<Payload:Len/binary, _/binary>> = Rest,
                    {ok, Payload};
                <<_Fin:1, _Rsv:3, _Opcode:4, 0:1, 126:7, Len:16, Rest/binary>> ->
                    <<Payload:Len/binary, _/binary>> = Rest,
                    {ok, Payload};
                _ ->
                    {ok, Data}
            end;
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Close a WebSocket connection.
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
