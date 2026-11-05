-module(brazier_stress_ffi).
%% Raw WebSocket client for brazier/stress. Every step is checked against
%% the wire protocol (docs/WIRE_PROTOCOL.md): the upgrade must answer 101,
%% the join must be answered, every event must be acknowledged by a patch
%% carrying its clock, and the close handshake must echo 1000. Nothing
%% sleeps: each step waits for the server's answer, bounded by a deadline.
-export([connect_and_join/4, connect_and_join/5, timed_events/4, close_handshake/2,
         monotonic_us/0]).

monotonic_us() ->
    erlang:monotonic_time(microsecond).

%% Connect, upgrade, join and send Events events, waiting for each patch.
%% {ok, {Conn, Acknowledged}} | {error, Reason}. Conn is opaque to Gleam and
%% must be closed by the process that opened it (close_handshake/2).
%%
%% The join carries no build id: brazier/stress may drive a server in
%% another VM, whose client bundle it cannot know, so the server warns once
%% per connection that it cannot check the page's build.
connect_and_join(Host, Port, Events, TimeoutMs) ->
    connect_and_join(Host, Port, Events, none, TimeoutMs).

%% As connect_and_join/4, but the join carries Build (`{some, Hash}`, the
%% hash of the `brazier_client_<hash>.js` the server serves, as a page that
%% loaded that script sends it) or none.
connect_and_join(Host, Port, Events, Build, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    HostBin = ensure_binary(Host),
    case gen_tcp:connect(binary_to_list(HostBin), Port,
                         [binary, {active, false}, {packet, raw}], TimeoutMs) of
        {ok, Socket} ->
            case join(Socket, HostBin, join_message(Build), Events, Deadline) of
                {ok, Buffer, Acknowledged} ->
                    {ok, {{Socket, Buffer}, Acknowledged}};
                {error, Reason} ->
                    ok = gen_tcp:close(Socket),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, <<"connect: ", (format_reason(Reason))/binary>>}
    end.

join_message(none) ->
    <<"{\"type\":\"join\",\"token\":\"\",\"path\":\"/\"}">>;
join_message({some, Build}) when is_binary(Build), Build =/= <<>> ->
    iolist_to_binary([<<"{\"type\":\"join\",\"token\":\"\",\"path\":\"/\",\"build\":">>,
                      json:encode(Build), <<"}">>]).

join(Socket, Host, Join, Events, Deadline) ->
    case upgrade(Socket, Host, Deadline) of
        {ok, Buffer0} ->
            case send_text(Socket, Join) of
                ok ->
                    case recv_text(Socket, Buffer0, Deadline) of
                        {ok, _ModelSync, Buffer1} ->
                            join_title(Socket, Buffer1, Events, Deadline);
                        {error, Reason} ->
                            {error, <<"join reply: ", Reason/binary>>}
                    end;
                {error, Reason} ->
                    {error, <<"join send: ", Reason/binary>>}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% The join's model_sync is followed by the page title (the stress app's
%% title is constant, so no event is answered by another one).
join_title(Socket, Buffer, Events, Deadline) ->
    case recv_text(Socket, Buffer, Deadline) of
        {ok, Title, Buffer1} ->
            case binary:match(Title, <<"\"type\":\"title\"">>) of
                {_, _} ->
                    events(Socket, Buffer1, Events, 1, Deadline);
                nomatch ->
                    {error, <<"join title: got ", Title/binary>>}
            end;
        {error, Reason} ->
            {error, <<"join title: ", Reason/binary>>}
    end.

%% Send events one at a time; each must be answered by a patch whose
%% ack_clock is that event's clock.
events(_Socket, Buffer, Events, Clock, _Deadline) when Clock > Events ->
    {ok, Buffer, Events};
events(Socket, Buffer, Events, Clock, Deadline) ->
    case event(Socket, Buffer, Clock, Deadline) of
        {ok, Buffer1} -> events(Socket, Buffer1, Events, Clock + 1, Deadline);
        {error, Reason} -> {error, Reason}
    end.

%% Send events FirstClock .. FirstClock + Events - 1 on a joined Conn, one
%% at a time, timing each from its send to its acknowledging patch.
%% {ok, {Conn, LatenciesUs}} (in send order) | {error, Reason}.
timed_events({Socket, Buffer}, FirstClock, Events, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    timed_events(Socket, Buffer, FirstClock, FirstClock + Events, Deadline, []).

timed_events(Socket, Buffer, Clock, End, _Deadline, Acc) when Clock =:= End ->
    {ok, {{Socket, Buffer}, lists:reverse(Acc)}};
timed_events(Socket, Buffer, Clock, End, Deadline, Acc) ->
    Start = monotonic_us(),
    case event(Socket, Buffer, Clock, Deadline) of
        {ok, Buffer1} ->
            Latency = monotonic_us() - Start,
            timed_events(Socket, Buffer1, Clock + 1, End, Deadline, [Latency | Acc]);
        {error, Reason} ->
            {error, Reason}
    end.

%% One event, answered by a patch carrying its clock.
%% {ok, Buffer} | {error, Reason}.
event(Socket, Buffer, Clock, Deadline) ->
    ClockBin = integer_to_binary(Clock),
    Event = <<"{\"type\":\"event\",\"name\":\"click\",\"handler_id\":\"inc\",",
              "\"data\":\"\",\"target_path\":\"/\",\"clock\":", ClockBin/binary, "}">>,
    case send_text(Socket, Event) of
        ok ->
            case recv_text(Socket, Buffer, Deadline) of
                {ok, Reply, Buffer1} ->
                    Ack = <<"\"ack_clock\":", ClockBin/binary, ",\"streams\":">>,
                    case {binary:match(Reply, <<"\"type\":\"patch\"">>),
                          binary:match(Reply, Ack)} of
                        {{_, _}, {_, _}} ->
                            {ok, Buffer1};
                        _ ->
                            {error, <<"event ", ClockBin/binary,
                                      " was answered by ", Reply/binary>>}
                    end;
                {error, Reason} ->
                    {error, <<"event ", ClockBin/binary, " reply: ", Reason/binary>>}
            end;
        {error, Reason} ->
            {error, <<"event ", ClockBin/binary, " send: ", Reason/binary>>}
    end.

%% Send close 1000 and wait for the server to echo it, then close the
%% socket. {ok, nil} | {error, Reason}.
close_handshake({Socket, Buffer}, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    Result = case gen_tcp:send(Socket, frame(8, <<1000:16>>)) of
        ok -> await_close(Socket, Buffer, Deadline);
        {error, Reason} -> {error, <<"close send: ", (format_reason(Reason))/binary>>}
    end,
    ok = gen_tcp:close(Socket),
    Result.

await_close(Socket, Buffer, Deadline) ->
    case recv_frame(Socket, Buffer, Deadline) of
        {ok, 8, <<1000:16, _/binary>>, _} -> {ok, nil};
        {ok, 8, Payload, _} ->
            {error, <<"server closed with ", (close_code(Payload))/binary>>};
        %% Frames already in flight before the server read the close.
        {ok, _Opcode, _Payload, Rest} -> await_close(Socket, Rest, Deadline);
        {error, Reason} -> {error, <<"close reply: ", Reason/binary>>}
    end.

upgrade(Socket, Host, Deadline) ->
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
            case recv_head(Socket, <<>>, Deadline) of
                {ok, <<"HTTP/1.1 101 ", _/binary>>, Rest} -> {ok, Rest};
                {ok, Head, _} ->
                    [StatusLine | _] = binary:split(Head, <<"\r\n">>),
                    {error, <<"upgrade answered ", StatusLine/binary>>};
                {error, Reason} -> {error, <<"upgrade: ", Reason/binary>>}
            end;
        {error, Reason} ->
            {error, <<"upgrade send: ", (format_reason(Reason))/binary>>}
    end.

%% The response head up to the blank line, and any bytes after it.
recv_head(Socket, Acc, Deadline) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Rest] -> {ok, Head, Rest};
        [_] ->
            case recv_more(Socket, Deadline) of
                {ok, Data} -> recv_head(Socket, <<Acc/binary, Data/binary>>, Deadline);
                {error, _} = E -> E
            end
    end.

%% The next text frame. Pings are answered and skipped; any other frame
%% is a protocol answer the client did not expect.
recv_text(Socket, Buffer, Deadline) ->
    case recv_frame(Socket, Buffer, Deadline) of
        {ok, 1, Payload, Rest} -> {ok, Payload, Rest};
        {ok, 9, Payload, Rest} ->
            case gen_tcp:send(Socket, frame(10, Payload)) of
                ok -> recv_text(Socket, Rest, Deadline);
                {error, Reason} -> {error, <<"pong send: ", (format_reason(Reason))/binary>>}
            end;
        {ok, 8, Payload, _} ->
            {error, <<"server closed with ", (close_code(Payload))/binary>>};
        {ok, Opcode, _, _} ->
            {error, <<"unexpected opcode ", (integer_to_binary(Opcode))/binary>>};
        {error, _} = E -> E
    end.

%% One unmasked, unfragmented server frame: {ok, Opcode, Payload, Rest}.
recv_frame(Socket, Buffer, Deadline) ->
    case parse_frame(Buffer) of
        {ok, Opcode, Payload, Rest} -> {ok, Opcode, Payload, Rest};
        more ->
            case recv_more(Socket, Deadline) of
                {ok, Data} -> recv_frame(Socket, <<Buffer/binary, Data/binary>>, Deadline);
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end.

parse_frame(<<1:1, _:3, Opcode:4, 0:1, 127:7, Len:64, Payload:Len/binary, Rest/binary>>) ->
    {ok, Opcode, Payload, Rest};
parse_frame(<<1:1, _:3, Opcode:4, 0:1, 126:7, Len:16, Payload:Len/binary, Rest/binary>>) ->
    {ok, Opcode, Payload, Rest};
parse_frame(<<1:1, _:3, Opcode:4, 0:1, Len:7, Payload:Len/binary, Rest/binary>>) when Len < 126 ->
    {ok, Opcode, Payload, Rest};
parse_frame(<<0:1, _:7, _/binary>>) ->
    {error, <<"fragmented server frame">>};
parse_frame(<<_:8, 1:1, _/bitstring>>) ->
    {error, <<"masked server frame">>};
parse_frame(_) ->
    more.

recv_more(Socket, Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining > 0 ->
            case gen_tcp:recv(Socket, 0, Remaining) of
                {ok, Data} -> {ok, Data};
                {error, Reason} -> {error, format_reason(Reason)}
            end;
        _ ->
            {error, <<"timeout">>}
    end.

send_text(Socket, Payload) ->
    case gen_tcp:send(Socket, frame(1, Payload)) of
        ok -> ok;
        {error, Reason} -> {error, format_reason(Reason)}
    end.

%% A masked client frame.
frame(Opcode, Payload) ->
    Mask = crypto:strong_rand_bytes(4),
    Len = byte_size(Payload),
    Header = if
        Len < 126 -> <<1:1, 0:3, Opcode:4, 1:1, Len:7>>;
        Len < 65536 -> <<1:1, 0:3, Opcode:4, 1:1, 126:7, Len:16>>;
        true -> <<1:1, 0:3, Opcode:4, 1:1, 127:7, Len:64>>
    end,
    <<Header/binary, Mask/binary, (mask(Payload, Mask))/binary>>.

mask(Payload, <<M1, M2, M3, M4>>) ->
    << <<(B bxor lists:nth((I rem 4) + 1, [M1, M2, M3, M4]))>>
       || {I, B} <- lists:zip(lists:seq(0, byte_size(Payload) - 1),
                              binary_to_list(Payload)) >>.

close_code(<<Code:16, Reason/binary>>) ->
    <<"code ", (integer_to_binary(Code))/binary, " ", Reason/binary>>;
close_code(<<>>) ->
    <<"no code">>;
close_code(Other) ->
    iolist_to_binary(io_lib:format("malformed close payload ~0p", [Other])).

ensure_binary(Value) when is_binary(Value) -> Value;
ensure_binary(Value) when is_list(Value) -> list_to_binary(Value).

format_reason(Reason) when is_binary(Reason) -> Reason;
format_reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
format_reason(Reason) -> iolist_to_binary(io_lib:format("~0p", [Reason])).
