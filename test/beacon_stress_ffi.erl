-module(beacon_stress_ffi).
-export([open_ws_and_exercise/4, monotonic_us/0]).

monotonic_us() ->
    erlang:monotonic_time(microsecond).

open_ws_and_exercise(Host, Port, HoldMs, EventsPerConnection) ->
    HostBin = ensure_binary(Host),
    HostStr = binary_to_list(HostBin),
    case gen_tcp:connect(HostStr, Port, [binary, {active, false}, {packet, raw}], 5000) of
        {ok, Socket} ->
            Result = upgrade(Socket, HostBin),
            case Result of
                ok ->
                    ExerciseResult = exercise_connection(Socket, EventsPerConnection),
                    timer:sleep(HoldMs),
                    CloseResult = gen_tcp:close(Socket),
                    case {ExerciseResult, CloseResult} of
                        {ok, _} -> {ok, nil};
                        {{error, Reason}, _} -> {error, Reason}
                    end;
                {error, Reason} ->
                    gen_tcp:close(Socket),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

exercise_connection(Socket, EventsPerConnection) ->
    Join = <<"{\"type\":\"join\",\"token\":\"\",\"path\":\"/\"}">>,
    case gen_tcp:send(Socket, text_frame(Join)) of
        ok -> send_event_frames(Socket, EventsPerConnection, 1);
        {error, Reason} -> {error, format_reason(Reason)}
    end.

send_event_frames(_Socket, Remaining, _Clock) when Remaining =< 0 ->
    ok;
send_event_frames(Socket, Remaining, Clock) ->
    ClockBin = integer_to_binary(Clock),
    Event = iolist_to_binary([
        <<"{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"inc\",\"data\":\"\",\"target_path\":\"/\",\"clock\":">>,
        ClockBin,
        <<"}">>
    ]),
    case gen_tcp:send(Socket, text_frame(Event)) of
        ok -> send_event_frames(Socket, Remaining - 1, Clock + 1);
        {error, Reason} -> {error, format_reason(Reason)}
    end.

text_frame(Payload) ->
    Mask = crypto:strong_rand_bytes(4),
    Masked = mask_payload(Payload, Mask, 0, []),
    Len = byte_size(Payload),
    Header = case Len of
        N when N < 126 -> <<16#81, (16#80 bor N)>>;
        N when N < 65536 -> <<16#81, (16#80 bor 126), N:16/big>>;
        N -> <<16#81, (16#80 bor 127), N:64/big>>
    end,
    <<Header/binary, Mask/binary, Masked/binary>>.

mask_payload(Payload, _Mask, Index, Acc) when Index >= byte_size(Payload) ->
    iolist_to_binary(lists:reverse(Acc));
mask_payload(Payload, Mask, Index, Acc) ->
    Byte = binary:at(Payload, Index),
    MaskByte = binary:at(Mask, Index rem 4),
    mask_payload(Payload, Mask, Index + 1, [<<(Byte bxor MaskByte)>> | Acc]).

upgrade(Socket, Host) ->
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    Request = iolist_to_binary([
        <<"GET /ws?path=%2F HTTP/1.1\r\n">>,
        <<"Host: ">>, Host, <<"\r\n">>,
        <<"Origin: http://">>, Host, <<"\r\n">>,
        <<"Upgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\n">>,
        <<"Sec-WebSocket-Key: ">>, Key, <<"\r\n">>,
        <<"Sec-WebSocket-Version: 13\r\n">>,
        <<"\r\n">>
    ]),
    case gen_tcp:send(Socket, Request) of
        ok ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Response} ->
                    case binary:match(Response, <<"101">>) of
                        {_, _} -> ok;
                        nomatch -> {error, <<"websocket upgrade failed">>}
                    end;
                {error, Reason} -> {error, format_reason(Reason)}
            end;
        {error, Reason} -> {error, format_reason(Reason)}
    end.

ensure_binary(Value) when is_binary(Value) -> Value;
ensure_binary(Value) when is_list(Value) -> list_to_binary(Value);
ensure_binary(Value) -> list_to_binary(io_lib:format("~p", [Value])).

format_reason(Reason) when is_binary(Reason) -> Reason;
format_reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
format_reason(Reason) -> list_to_binary(io_lib:format("~p", [Reason])).
