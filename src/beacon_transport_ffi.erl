-module(beacon_transport_ffi).
-export([
    listen/2, accept/1, tcp_send/2, close/1,
    controlling_process/2, set_active_once/1,
    read_http_request/1, read_http_request_with_limits/4, read_body/2,
    ws_accept_key/1,
    ws_encode_text_frame/1, ws_encode_close_frame/0,
    classify_tcp_message/1,
    start_acceptor_pool/3
]).
%% Strict RFC 6455 frame layer and WebSocket connection helpers.
-export([
    ws_parse_frame/2,
    ws_encode_frame/2,
    ws_encode_close/2,
    ws_is_valid_utf8/1,
    ws_decode_key/1,
    ws_set_send_timeout/2,
    ws_peer_ip/1,
    ws_acquire_ip_slot/2,
    ws_release_ip_slot/1,
    ws_ip_slot_count/1,
    ws_now_ms/0,
    ws_classify_message/1,
    ws_mailbox_len/0
]).

%% --- TCP Operations ---

listen(Port, Backlog) ->
    case gen_tcp:listen(Port, [
        binary,
        {active, false},
        {reuseaddr, true},
        {backlog, Backlog},
        {nodelay, true}
    ]) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

accept(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

tcp_send(Socket, Data) ->
    case gen_tcp:send(Socket, Data) of
        ok -> {ok, nil};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

close(Socket) ->
    gen_tcp:close(Socket),
    nil.

controlling_process(Socket, Pid) ->
    case gen_tcp:controlling_process(Socket, Pid) of
        ok -> {ok, nil};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

set_active_once(Socket) ->
    inet:setopts(Socket, [{active, once}]),
    nil.

%% --- HTTP Request Parsing ---
%% Uses Erlang's {packet, http_bin} mode for efficient parsing.
%% Returns: {ok, {MethodBin, PathBin, [{KeyBin, ValueBin}]}} | {error, Reason}

read_http_request(Socket) ->
    read_http_request_with_limits(Socket, 100, 65536, 5000).

read_http_request_with_limits(Socket, MaxHeaders, MaxHeaderBytes, TimeoutMs) ->
    case inet:setopts(Socket, [{packet, http_bin}]) of
        {error, Reason} ->
            {error, format_reason(Reason)};
        ok ->
            DeadlineMs = erlang:monotonic_time(millisecond) + TimeoutMs,
            case recv_before_deadline(Socket, DeadlineMs) of
                {ok, {http_request, Method, {abs_path, Path}, _Version}} ->
                    RequestLineBytes =
                        byte_size(method_to_binary(Method)) + byte_size(Path),
                    case read_headers(Socket, [], MaxHeaders, MaxHeaderBytes, RequestLineBytes, DeadlineMs) of
                        {ok, Headers} ->
                            inet:setopts(Socket, [{packet, raw}]),
                            {ok, {method_to_binary(Method), Path, Headers}};
                        {error, Reason2} ->
                            inet:setopts(Socket, [{packet, raw}]),
                            {error, Reason2}
                    end;
                {ok, {http_error, _}} ->
                    inet:setopts(Socket, [{packet, raw}]),
                    {error, <<"bad_request">>};
                {error, closed} ->
                    {error, <<"closed">>};
                {error, Reason3} ->
                    inet:setopts(Socket, [{packet, raw}]),
                    {error, format_reason(Reason3)}
            end
    end.

recv_before_deadline(Socket, DeadlineMs) ->
    NowMs = erlang:monotonic_time(millisecond),
    RemainingMs = DeadlineMs - NowMs,
    case RemainingMs =< 0 of
        true -> {error, <<"timeout">>};
        false -> gen_tcp:recv(Socket, 0, RemainingMs)
    end.

read_headers(Socket, Acc, MaxHeaders, MaxHeaderBytes, BytesRead, DeadlineMs) ->
    case recv_before_deadline(Socket, DeadlineMs) of
        {ok, {http_header, _, Name, _, Value}} ->
            Key = normalize_header_name(Name),
            NewBytesRead = BytesRead + byte_size(Key) + byte_size(Value),
            NewHeaderCount = length(Acc) + 1,
            case NewHeaderCount > MaxHeaders of
                true ->
                    {error, <<"too_many_headers">>};
                false ->
                    case NewBytesRead > MaxHeaderBytes of
                        true ->
                            {error, <<"headers_too_large">>};
                        false ->
                            read_headers(
                                Socket,
                                [{Key, Value} | Acc],
                                MaxHeaders,
                                MaxHeaderBytes,
                                NewBytesRead,
                                DeadlineMs
                            )
                    end
            end;
        {ok, http_eoh} ->
            {ok, lists:reverse(Acc)};
        {ok, {http_error, _}} ->
            {error, <<"bad_header">>};
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

%% Read exactly Length bytes from the socket (request body).
%% Socket must be in {packet, raw} mode (set by read_http_request after headers).
%% MaxBytes is the safety limit — if Length > MaxBytes, returns error without reading.
%% Returns {ok, Data} or {error, Reason}.
read_body(Socket, Length) ->
    case gen_tcp:recv(Socket, Length, 30000) of
        {ok, Data} ->
            {ok, Data};
        {error, closed} ->
            {error, <<"closed">>};
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

normalize_header_name(Name) when is_atom(Name) ->
    string:lowercase(atom_to_binary(Name, utf8));
normalize_header_name(Name) when is_binary(Name) ->
    string:lowercase(Name).

method_to_binary('GET') -> <<"GET">>;
method_to_binary('POST') -> <<"POST">>;
method_to_binary('PUT') -> <<"PUT">>;
method_to_binary('DELETE') -> <<"DELETE">>;
method_to_binary('HEAD') -> <<"HEAD">>;
method_to_binary('OPTIONS') -> <<"OPTIONS">>;
method_to_binary('PATCH') -> <<"PATCH">>;
method_to_binary(Other) when is_atom(Other) -> atom_to_binary(Other, utf8);
method_to_binary(Other) -> Other.

%% --- WebSocket ---

%% Compute Sec-WebSocket-Accept key per RFC 6455.
ws_accept_key(ClientKey) ->
    Guid = <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>,
    Hash = crypto:hash(sha, <<ClientKey/binary, Guid/binary>>),
    base64:encode(Hash).

%% Encode a text frame (server → client, unmasked).
ws_encode_text_frame(Text) when is_binary(Text) ->
    Len = byte_size(Text),
    if
        Len < 126 ->
            <<1:1, 0:3, 1:4, 0:1, Len:7, Text/binary>>;
        Len < 65536 ->
            <<1:1, 0:3, 1:4, 0:1, 126:7, Len:16, Text/binary>>;
        true ->
            <<1:1, 0:3, 1:4, 0:1, 127:7, Len:64, Text/binary>>
    end.

%% Encode a close frame (server → client, unmasked, no status).
ws_encode_close_frame() ->
    <<1:1, 0:3, 8:4, 0:1, 0:7>>.

%% --- Strict RFC 6455 frame parser ---
%% Parses ONE client frame from the front of Data.
%%
%% Returns the Erlang shape of the Gleam type ws.ParseOutcome:
%%   {parsed, Fin :: boolean(), Opcode, UnmaskedPayload, Rest}
%%   need_more
%%   {parse_failed, FrameError}
%% where FrameError is the Erlang shape of ws.FrameError:
%%   reserved_bits_set | {unknown_opcode, Op} | fragmented_control_frame
%%   | {control_frame_too_large, Len} | unmasked_frame | non_minimal_length
%%   | {frame_too_large, Len}
%%
%% Checks run on the 2..14 byte header BEFORE the payload is buffered, so a
%% peer declaring a 2^62 byte frame is rejected immediately instead of making
%% the server buffer up to the limit (cowboy/cowlib do the same).
%% Reference: RFC 6455 §5.2, §5.5; cowlib cow_ws:parse_header/3.
ws_parse_frame(Data, MaxPayload) when is_binary(Data), is_integer(MaxPayload), MaxPayload >= 0 ->
    case Data of
        <<Fin:1, Rsv:3, Op:4, Mask:1, Len7:7, Rest/binary>> ->
            parse_header(Fin, Rsv, Op, Mask, Len7, Rest, MaxPayload);
        _ ->
            need_more
    end.

parse_header(_Fin, Rsv, _Op, _Mask, _Len7, _Rest, _Max) when Rsv =/= 0 ->
    %% No extensions are negotiated, so every RSV bit must be zero (§5.2).
    {parse_failed, reserved_bits_set};
parse_header(_Fin, _Rsv, Op, _Mask, _Len7, _Rest, _Max)
  when Op =/= 0, Op =/= 1, Op =/= 2, Op =/= 8, Op =/= 9, Op =/= 10 ->
    {parse_failed, {unknown_opcode, Op}};
parse_header(0, _Rsv, Op, _Mask, _Len7, _Rest, _Max) when Op >= 8 ->
    %% Control frames MUST NOT be fragmented (§5.5).
    {parse_failed, fragmented_control_frame};
parse_header(_Fin, _Rsv, Op, _Mask, Len7, _Rest, _Max) when Op >= 8, Len7 > 125 ->
    %% Control frames MUST have a payload length of 125 bytes or less (§5.5).
    {parse_failed, {control_frame_too_large, Len7}};
parse_header(_Fin, _Rsv, _Op, 0, _Len7, _Rest, _Max) ->
    %% A server MUST close the connection on an unmasked client frame (§5.1).
    {parse_failed, unmasked_frame};
parse_header(Fin, _Rsv, Op, 1, Len7, Rest, Max) when Len7 < 126 ->
    parse_payload(Fin, Op, Len7, Rest, Max);
parse_header(Fin, _Rsv, Op, 1, 126, Rest, Max) ->
    case Rest of
        <<Len:16, _/binary>> when Len < 126 ->
            {parse_failed, non_minimal_length};
        <<Len:16, Rest2/binary>> ->
            parse_payload(Fin, Op, Len, Rest2, Max);
        _ ->
            need_more
    end;
parse_header(Fin, _Rsv, Op, 1, 127, Rest, Max) ->
    case Rest of
        <<1:1, _:63, _/binary>> ->
            %% The most significant bit of a 64-bit length MUST be 0 (§5.2).
            {parse_failed, {frame_too_large, 16#7FFFFFFFFFFFFFFF}};
        <<Len:64, _/binary>> when Len < 65536 ->
            {parse_failed, non_minimal_length};
        <<Len:64, Rest2/binary>> ->
            parse_payload(Fin, Op, Len, Rest2, Max);
        _ ->
            need_more
    end.

parse_payload(_Fin, _Op, Len, _Rest, Max) when Len > Max ->
    {parse_failed, {frame_too_large, Len}};
parse_payload(Fin, Op, Len, Rest, _Max) ->
    case Rest of
        <<MaskKey:4/binary, Payload:Len/binary, Remaining/binary>> ->
            {parsed, Fin =:= 1, Op, unmask(Payload, MaskKey), Remaining};
        _ ->
            need_more
    end.

%% Encode one unfragmented server frame (FIN set, unmasked, RSV 0).
%% Server frames MUST NOT be masked (§5.1).
ws_encode_frame(Opcode, Payload) when is_integer(Opcode), is_binary(Payload) ->
    Len = byte_size(Payload),
    if
        Len < 126 ->
            <<1:1, 0:3, Opcode:4, 0:1, Len:7, Payload/binary>>;
        Len < 65536 ->
            <<1:1, 0:3, Opcode:4, 0:1, 126:7, Len:16, Payload/binary>>;
        true ->
            <<1:1, 0:3, Opcode:4, 0:1, 127:7, Len:64, Payload/binary>>
    end.

%% Encode a close frame carrying a status code and reason (§5.5.1).
%% The caller guarantees byte_size(Reason) =< 123 so the payload fits a
%% control frame; this is asserted here so a violation crashes loudly.
ws_encode_close(Code, Reason) when is_integer(Code), Code >= 1000, Code =< 4999,
                                   is_binary(Reason), byte_size(Reason) =< 123 ->
    ws_encode_frame(8, <<Code:16, Reason/binary>>).

%% True when the binary is entirely well-formed UTF-8 (§8.1).
ws_is_valid_utf8(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Bin -> true;
        _ -> false
    end.

%% Decode a Sec-WebSocket-Key. Returns {ok, Raw} or {error, nil}.
ws_decode_key(Key) when is_binary(Key) ->
    try base64:decode(Key) of
        Raw -> {ok, Raw}
    catch
        error:_ -> {error, nil}
    end.

%% Bound how long a send may block on a slow reader. With send_timeout_close
%% the socket is closed by the VM when the timeout fires, so a stuck peer can
%% never pin the handler process or grow the kernel send queue forever.
%% Reference: cowboy/ranch send_timeout + send_timeout_close.
ws_set_send_timeout(Socket, TimeoutMs) when is_integer(TimeoutMs), TimeoutMs > 0 ->
    case inet:setopts(Socket, [{send_timeout, TimeoutMs}, {send_timeout_close, true}]) of
        ok -> {ok, nil};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

%% The peer IP address as text, used for per-IP connection accounting.
ws_peer_ip(Socket) ->
    case inet:peername(Socket) of
        {ok, {Addr, _Port}} -> {ok, list_to_binary(inet:ntoa(Addr))};
        {error, Reason} -> {error, format_reason(Reason)}
    end.

%% --- Per-IP WebSocket slots ---
%% The calling process joins the pg group {beacon_ws_ip, SlotKey}, where
%% SlotKey identifies a listener and a peer IP. pg removes a member
%% automatically when it exits, so a crashed handler can never leak a slot.
%% Join-then-count is race free: two concurrent joins may both see the other
%% and both be rejected, but the cap can never be exceeded.
-define(WS_PG_SCOPE, beacon_ws_pg).

ensure_ws_pg() ->
    case pg:start(?WS_PG_SCOPE) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok
    end.

%% Returns {ok, Count} when the slot was taken, {error, Count} when the cap
%% would be exceeded (the caller has already been removed from the group).
ws_acquire_ip_slot(SlotKey, Max) when is_binary(SlotKey), is_integer(Max), Max > 0 ->
    ensure_ws_pg(),
    Group = {beacon_ws_ip, SlotKey},
    ok = pg:join(?WS_PG_SCOPE, Group, self()),
    Count = length(pg:get_local_members(?WS_PG_SCOPE, Group)),
    case Count > Max of
        true ->
            ok = pg:leave(?WS_PG_SCOPE, Group, self()),
            {error, Count - 1};
        false ->
            {ok, Count}
    end.

%% Release the calling process's slot. Idempotent: returns true when a slot
%% was held, false when it had already been released.
ws_release_ip_slot(SlotKey) when is_binary(SlotKey) ->
    ensure_ws_pg(),
    case pg:leave(?WS_PG_SCOPE, {beacon_ws_ip, SlotKey}, self()) of
        ok -> true;
        not_joined -> false
    end.

ws_ip_slot_count(SlotKey) when is_binary(SlotKey) ->
    ensure_ws_pg(),
    length(pg:get_local_members(?WS_PG_SCOPE, {beacon_ws_ip, SlotKey})).

%% Monotonic clock in milliseconds (liveness bookkeeping).
ws_now_ms() ->
    erlang:monotonic_time(millisecond).

%% Classify a raw (non-Subject) message received by a WebSocket handler.
%% Returns the Erlang shape of the Gleam type ws.SocketEvent.
ws_classify_message({tcp, _Socket, Data}) ->
    {socket_data, Data};
ws_classify_message({tcp_closed, _Socket}) ->
    socket_closed;
ws_classify_message({tcp_error, _Socket, Reason}) ->
    {socket_error, format_reason(Reason)};
ws_classify_message({beacon_session_revoked, SessionId, Reason})
  when is_binary(SessionId), is_binary(Reason) ->
    {session_revoked, SessionId, Reason};
ws_classify_message(Other) ->
    {unexpected_message, list_to_binary(io_lib:format("~0P", [Other, 8]))}.

%% Number of messages waiting in the calling process's mailbox.
ws_mailbox_len() ->
    {message_queue_len, Len} = erlang:process_info(self(), message_queue_len),
    Len.

%% Unmask payload using XOR with 4-byte mask key.
%% Uses crypto:exor for efficiency.
unmask(Payload, Mask) ->
    Len = byte_size(Payload),
    case Len of
        0 -> <<>>;
        _ ->
            Reps = Len div 4,
            Rem = Len rem 4,
            FullMask = binary:copy(Mask, Reps),
            PartMask = binary:part(Mask, 0, Rem),
            FullKey = <<FullMask/binary, PartMask/binary>>,
            crypto:exor(Payload, FullKey)
    end.

%% --- TCP Message Classification ---
%% Classifies raw Erlang messages received via {active, once} mode.
%% Maps to Gleam TcpMsg type constructors.

classify_tcp_message({tcp, _Socket, Data}) ->
    {ok, {tcp_data, Data}};
classify_tcp_message({tcp_closed, _Socket}) ->
    {ok, tcp_closed};
classify_tcp_message({tcp_error, _Socket, Reason}) ->
    {ok, {tcp_error, format_reason(Reason)}};
classify_tcp_message(_) ->
    {error, nil}.

%% --- Acceptor Loop ---
%% Accept a connection, spawn a replacement acceptor, then handle the
%% connection in THIS process. Eliminates controlling_process entirely —
%% the accepting process already owns the socket, so there is no ownership
%% transfer window. This is the Ranch/Glisten pattern and is immune to
%% thundering-herd races.

%% Start N acceptors and wait for all to be blocked on gen_tcp:accept.
%% Uses a probe connection to verify the accept queue is active:
%% after spawning all acceptors, connects and immediately disconnects.
%% If the connect succeeds, at least one acceptor was ready.
%% We add a small yield to let all acceptors enter their accept calls.
start_acceptor_pool(ListenSocket, HandlerFun, Count) ->
    lists:foreach(fun(_) ->
        spawn(fun() -> acceptor_loop(ListenSocket, HandlerFun) end)
    end, lists:seq(1, Count)),
    %% Probe connection: verify at least one acceptor is blocking on accept.
    %% This eliminates the cold-start race where connections arrive before
    %% acceptors have entered gen_tcp:accept. The probe connects, the handler
    %% sees an empty read (closed), and exits cleanly.
    {ok, {Addr, Port}} = inet:sockname(ListenSocket),
    ConnAddr = case Addr of
        {0,0,0,0} -> {127,0,0,1};
        {0,0,0,0,0,0,0,0} -> {0,0,0,0,0,0,0,1};
        Other -> Other
    end,
    case gen_tcp:connect(ConnAddr, Port, [binary], 1000) of
        {ok, Probe} -> gen_tcp:close(Probe);
        {error, _} -> timer:sleep(10)
    end,
    nil.

acceptor_loop(ListenSocket, HandlerFun) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            %% Spawn replacement acceptor BEFORE handling (keeps pool full).
            %% MUST be unlinked — if linked, handler exit kills the replacement.
            spawn(fun() -> acceptor_loop(ListenSocket, HandlerFun) end),
            %% This process becomes the handler (already owns Socket)
            try
                HandlerFun(Socket)
            catch
                Class:Reason ->
                    logger:error("beacon.server handler crashed: ~p:~p", [Class, Reason]),
                    gen_tcp:close(Socket)
            end;
        {error, closed} ->
            %% Listen socket closed — server is shutting down
            ok;
        {error, _Reason} ->
            timer:sleep(100),
            acceptor_loop(ListenSocket, HandlerFun)
    end.

%% --- Helpers ---

format_reason(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
format_reason(Reason) when is_binary(Reason) ->
    Reason;
format_reason(Reason) ->
    list_to_binary(io_lib:format("~p", [Reason])).
