-module(brazier_transport_ffi).
-export([
    listen/2, accept/1, tcp_send/2, send_file/4, close/1,
    controlling_process/2, set_active_once/1,
    ws_accept_key/1,
    ws_encode_text_frame/1, ws_encode_close_frame/0,
    classify_tcp_message/1
]).
%% HTTP/1.1 request head parsing, body framing context, handler isolation.
-export([
    read_http_head/3, http_body_begin/5, http_body_read/2, http_body_state/1,
    http_body_end/1, http_buffered_bytes/1, run_handler/2, monotonic_ms/0,
    linger_close/3
]).

%% Per-request telemetry context for [brazier, http, request].
-export([
    http_route_reset/0, http_route_tag/1, http_route_take/0,
    http_connection_id/0, http_body_consumed/1
]).

-define(ROUTE_KEY, brazier_http_route).

%% Strict RFC 6455 frame layer and WebSocket connection helpers.
-export([
    ws_parse_frame/2,
    ws_encode_frame/2,
    ws_encode_frame_iodata/2,
    ws_encode_close/2,
    json_raw/1,
    ws_is_valid_utf8/1,
    ws_decode_key/1,
    ws_set_send_timeout/2,
    ws_peer_ip/1,
    ws_now_ms/0,
    ws_classify_message/1,
    ws_mailbox_len/0
]).

-define(ALLOWED_METHODS, [<<"GET">>, <<"HEAD">>, <<"POST">>, <<"PUT">>, <<"DELETE">>,
                          <<"OPTIONS">>, <<"PATCH">>]).

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

%% Send Length bytes of the file at Path, from Offset, with file:sendfile/5
%% (the kernel copies the file to the socket; the bytes never enter the
%% BEAM heap). The response head is already on the wire with
%% Content-Length: Length, so a file that shrank in between leaves the
%% message short: that is an error, and the caller closes the connection.
%% Reference: cowboy_http sendfile bodies, Plug.Conn.send_file/5.
send_file(Socket, Path, Offset, Length)
  when is_binary(Path), is_integer(Offset), Offset >= 0, is_integer(Length), Length >= 0 ->
    case Length of
        0 ->
            {ok, nil};
        _ ->
            %% file:sendfile/5 takes a raw file; the file is opened per
            %% response and closed before returning, so no descriptor
            %% outlives the response.
            case file:open(Path, [read, raw, binary]) of
                {ok, Fd} ->
                    Result = file:sendfile(Fd, Socket, Offset, Length, []),
                    case file:close(Fd) of
                        ok -> ok;
                        {error, CloseReason} ->
                            brazier_log_ffi:warning(<<"brazier.http">>, "closing ~ts failed: ~p",
                                                   [Path, CloseReason])
                    end,
                    case Result of
                        {ok, Length} ->
                            {ok, nil};
                        {ok, Sent} ->
                            {error, iolist_to_binary(io_lib:format(
                                "sendfile sent ~p of ~p bytes of ~ts (the file changed)",
                                [Sent, Length, Path]))};
                        {error, Reason} ->
                            {error, format_reason(Reason)}
                    end;
                {error, Reason} ->
                    {error, iolist_to_binary(io_lib:format("cannot open ~ts: ~p",
                                                           [Path, Reason]))}
            end
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
%% Parses a per-connection buffer with erlang:decode_packet/3 (http_bin /
%% httph_bin). Every decode_packet result is handled explicitly (RFC 9112):
%%   * origin-form  {abs_path, Path}                  -> Path
%%   * absolute-form {absoluteURI, S, Host, Port, P}  -> P, Host header replaced
%%   * asterisk-form '*'                              -> only for OPTIONS
%%   * anything else (authority-form, {scheme,..}, raw binary, response
%%     lines, http_error)                              -> 400
%% Up to 8 empty lines before the request line are ignored (RFC 9112 2.2).
%% MaxLineBytes bounds the request line (414), MaxHeaderBytes the raw
%% header section (431).
%%
%% read_http_head/3 returns
%%   {ok, {MethodBin, PathBin, http10 | http11, [{LowerName, Value}]}}
%% or {error, Reason} with Reason one of
%%   peer_closed | idle_timeout | draining | request_timeout | request_line_too_long |
%%   headers_too_large | too_many_headers | {bad_request, Bin} |
%%   {not_implemented, Bin} | {version_not_supported, Bin} | {socket_error, Bin}

-define(MAX_EMPTY_LINES, 8).

%% Bytes received but not yet consumed (pipelined requests, body bytes that
%% arrived with the head) live in the connection process dictionary. The
%% socket always stays in {packet, raw}: parsing a buffer with
%% erlang:decode_packet/3 (as mist/glisten and cowboy parse their own
%% buffers) keeps an oversized line answerable, whereas the inet driver's
%% {packet, http_bin} closes the socket on emsgsize before a 431/414 can be
%% written.
-define(BUFFER_KEY(Socket), {brazier_http_buffer, Socket}).

read_http_head(Socket, {head_limits, MaxHeaders, MaxHeaderBytes, MaxLineBytes},
               {head_timing, LineTimeoutMs, HeaderSpec}) ->
    true = is_integer(MaxHeaders) andalso MaxHeaders > 0,
    true = is_integer(MaxHeaderBytes) andalso MaxHeaderBytes > 0,
    true = is_integer(MaxLineBytes) andalso MaxLineBytes > 0,
    true = is_integer(LineTimeoutMs) andalso LineTimeoutMs > 0,
    LineDeadline = now_ms() + LineTimeoutMs,
    case request_start(Socket, take_buffer(Socket), LineDeadline) of
        {ok, Buffer} ->
            read_http_head(Socket, Buffer, MaxHeaders, MaxHeaderBytes, MaxLineBytes,
                           LineDeadline, HeaderSpec);
        {error, _} = Error ->
            Error
    end.

read_http_head(Socket, Buffer, MaxHeaders, MaxHeaderBytes, MaxLineBytes, LineDeadline,
               HeaderSpec) ->
    case read_request_line(Socket, Buffer, MaxLineBytes, LineDeadline, 0) of
        {ok, Method, Target, Version, Rest} ->
            HeaderDeadline = case HeaderSpec of
                shared_with_request_line -> LineDeadline;
                {after_request_line, Ms} when is_integer(Ms), Ms > 0 -> now_ms() + Ms
            end,
            case read_headers(Socket, Rest, [], 0, 0, MaxHeaders, MaxHeaderBytes,
                              HeaderDeadline) of
                {ok, Headers0, Rest1} ->
                    put(?BUFFER_KEY(Socket), Rest1),
                    {Path, Headers} = apply_target(Target, Headers0),
                    {ok, {Method, Path, Version, Headers}};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% The first bytes of the next request. A pipelined request is already
%% buffered. Otherwise the connection is idle: wait for bytes with the
%% socket in {active, once}, so the connection owner's drain message (see
%% brazier_http_conns) ends the wait at once instead of after the idle
%% timeout. A request that has started is never interrupted: once the first
%% bytes arrived, the head is read with blocking receives as before.
request_start(_Socket, Buffer, _Deadline) when byte_size(Buffer) > 0 ->
    {ok, Buffer};
request_start(Socket, <<>>, Deadline) ->
    Owner = brazier_http_conns:owner_if_any(),
    case Owner =/= none andalso brazier_http_conns:drain_requested() of
        true ->
            {error, draining};
        false ->
            case inet:setopts(Socket, [{active, once}]) of
                ok -> receive_request_start(Socket, Owner, Deadline);
                {error, Reason} -> {error, {socket_error, format_reason(Reason)}}
            end
    end.

receive_request_start(Socket, Owner, Deadline) ->
    receive
        {tcp, Socket, Data} ->
            %% {active, once} already set the socket passive again.
            {ok, Data};
        {tcp_closed, Socket} ->
            {error, peer_closed};
        {tcp_error, Socket, Reason} ->
            {error, {socket_error, format_reason(Reason)}};
        {brazier_http_drain, Owner} ->
            brazier_http_conns:mark_draining(),
            passive_and_closing(Socket, draining)
    after max(0, Deadline - now_ms()) ->
        passive_and_closing(Socket, idle_timeout)
    end.

%% Leave {active, once} before the connection is closed for Reason, and drop
%% a socket message that arrived in between: nothing reads it any more.
passive_and_closing(Socket, Reason) ->
    case inet:setopts(Socket, [{active, false}]) of
        ok -> ok;
        {error, SetoptsReason} ->
            brazier_log_ffi:debug(<<"brazier.http">>, "socket already gone while closing (~p): ~p",
                                 [Reason, SetoptsReason])
    end,
    receive
        {tcp, Socket, _Data} -> ok;
        {tcp_closed, Socket} -> ok;
        {tcp_error, Socket, _} -> ok
    after 0 -> ok
    end,
    {error, Reason}.

take_buffer(Socket) ->
    case erase(?BUFFER_KEY(Socket)) of
        undefined -> <<>>;
        Bin when is_binary(Bin) -> Bin
    end.

%% Number of received bytes not yet consumed by the HTTP parser or a body
%% read. Non-zero at a WebSocket upgrade means the client sent data before
%% the handshake completed.
http_buffered_bytes(Socket) ->
    case get(?BUFFER_KEY(Socket)) of
        undefined -> 0;
        Bin when is_binary(Bin) -> byte_size(Bin)
    end.

%% Decode one packet from Buffer, receiving more bytes until it is complete.
%% A packet longer than MaxBytes fails with too_long, and no more bytes are
%% read once the buffer exceeds MaxBytes, so the buffer stays bounded.
%% {ok, Packet, Rest} | {error, too_long | closed | {timeout, BufferedBytes}
%%                             | {invalid, Reason} | {socket, Reason}}
next_packet(Socket, Type, Buffer, MaxBytes, Deadline) ->
    case erlang:decode_packet(Type, Buffer, []) of
        {ok, Packet, Rest} ->
            case byte_size(Buffer) - byte_size(Rest) > MaxBytes of
                true -> {error, too_long};
                false -> {ok, Packet, Rest}
            end;
        {more, _} when byte_size(Buffer) > MaxBytes ->
            {error, too_long};
        {more, _} ->
            case recv_before_deadline(Socket, Deadline) of
                {ok, Data} ->
                    next_packet(Socket, Type, <<Buffer/binary, Data/binary>>, MaxBytes,
                                Deadline);
                {error, timeout} -> {error, {timeout, byte_size(Buffer)}};
                {error, closed} -> {error, closed};
                {error, Reason} -> {error, {socket, Reason}}
            end;
        {error, Reason} ->
            {error, {invalid, Reason}}
    end.

read_request_line(Socket, Buffer, MaxLineBytes, Deadline, EmptyLines) ->
    case next_packet(Socket, http_bin, Buffer, MaxLineBytes, Deadline) of
        {ok, {http_request, Method, Uri, Version}, Rest} ->
            case validate_request_line(Method, Uri, Version) of
                {ok, ValidMethod, Target, ValidVersion} ->
                    {ok, ValidMethod, Target, ValidVersion, Rest};
                {error, _} = Error ->
                    Error
            end;
        {ok, {http_error, Line}, Rest} when (Line =:= <<"\r\n">> orelse Line =:= <<"\n">>),
                                            EmptyLines < ?MAX_EMPTY_LINES ->
            read_request_line(Socket, Rest, MaxLineBytes, Deadline, EmptyLines + 1);
        {ok, {http_error, _Line}, _Rest} ->
            {error, {bad_request, <<"malformed request line">>}};
        {ok, {http_response, _, _, _}, _Rest} ->
            {error, {bad_request, <<"status line received where a request line was expected">>}};
        {ok, _Other, _Rest} ->
            {error, {bad_request, <<"unexpected data before request line">>}};
        {error, too_long} ->
            {error, request_line_too_long};
        %% Nothing at all arrived: an idle connection, closed without a response.
        {error, {timeout, 0}} when EmptyLines =:= 0 ->
            {error, idle_timeout};
        {error, {timeout, _Buffered}} ->
            {error, request_timeout};
        {error, closed} ->
            {error, peer_closed};
        {error, {invalid, _Reason}} ->
            {error, {bad_request, <<"malformed request line">>}};
        {error, {socket, Reason}} ->
            {error, {socket_error, format_reason(Reason)}}
    end.

validate_request_line(Method0, Uri, Version) ->
    Method = method_to_binary(Method0),
    case is_token(Method) of
        false ->
            {error, {bad_request, <<"invalid request method">>}};
        true ->
            case lists:member(Method, ?ALLOWED_METHODS) of
                false ->
                    {error, {not_implemented, Method}};
                true ->
                    case version_atom(Version) of
                        {error, _} = Error ->
                            Error;
                        {ok, VersionAtom} ->
                            case request_target(Method, Uri) of
                                {ok, Target} -> {ok, Method, Target, VersionAtom};
                                {error, _} = Error -> Error
                            end
                    end
            end
    end.

version_atom({1, 1}) -> {ok, http11};
version_atom({1, 0}) -> {ok, http10};
version_atom({0, 9}) -> {error, {bad_request, <<"missing HTTP version">>}};
version_atom({Major, Minor}) when is_integer(Major), is_integer(Minor) ->
    {error, {version_not_supported,
             iolist_to_binary(["HTTP/", integer_to_binary(Major), ".", integer_to_binary(Minor)])}};
version_atom(_) ->
    {error, {bad_request, <<"invalid HTTP version">>}}.

request_target(_Method, {abs_path, Path}) ->
    case is_valid_path(Path) of
        true -> {ok, {origin, Path}};
        false -> {error, {bad_request, <<"invalid request target">>}}
    end;
request_target(_Method, {absoluteURI, Scheme, Host, Port, Path})
  when (Scheme =:= http orelse Scheme =:= https), is_binary(Host), is_binary(Path) ->
    case is_valid_path(Path) andalso is_valid_host(Host) of
        true ->
            HostHeader = case Port of
                undefined -> Host;
                P when is_integer(P) -> <<Host/binary, ":", (integer_to_binary(P))/binary>>
            end,
            {ok, {absolute, Path, HostHeader}};
        false ->
            {error, {bad_request, <<"invalid absolute request target">>}}
    end;
request_target(<<"OPTIONS">>, '*') ->
    {ok, {asterisk, <<"*">>}};
request_target(_Method, '*') ->
    {error, {bad_request, <<"asterisk-form is only valid for OPTIONS">>}};
request_target(_Method, {scheme, _, _}) ->
    {error, {bad_request, <<"unsupported request target form">>}};
request_target(_Method, Bin) when is_binary(Bin) ->
    {error, {bad_request, <<"unsupported request target form">>}};
request_target(_Method, _Other) ->
    {error, {bad_request, <<"unsupported request target form">>}}.

%% Absolute-form: RFC 9112 3.2.2 — the target's authority replaces Host.
apply_target({origin, Path}, Headers) ->
    {Path, Headers};
apply_target({asterisk, Path}, Headers) ->
    {Path, Headers};
apply_target({absolute, Path, Host}, Headers) ->
    {Path, [{<<"host">>, Host} | [H || {K, _} = H <- Headers, K =/= <<"host">>]]}.

is_valid_path(<<"/", _/binary>> = Path) ->
    no_ctl_or_space(Path) andalso is_utf8(Path);
is_valid_path(_) ->
    false.

is_valid_host(<<>>) -> false;
is_valid_host(Host) -> no_ctl_or_space(Host) andalso is_utf8(Host).

no_ctl_or_space(<<>>) -> true;
no_ctl_or_space(<<C, _/binary>>) when C =< 16#20; C =:= 16#7F -> false;
no_ctl_or_space(<<_, Rest/binary>>) -> no_ctl_or_space(Rest).

is_utf8(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Bin -> true;
        _ -> false
    end.

%% MaxHeaderBytes bounds the raw header section: every field line including
%% its CRLF, plus the empty line that ends the section.
read_headers(Socket, Buffer, Acc, Count, Bytes, MaxHeaders, MaxHeaderBytes, Deadline) ->
    case next_packet(Socket, httph_bin, Buffer, MaxHeaderBytes - Bytes, Deadline) of
        {ok, {http_header, _, Name, _, Value0}, Rest} ->
            NewCount = Count + 1,
            NewBytes = Bytes + byte_size(Buffer) - byte_size(Rest),
            Key = normalize_header_name(Name),
            Value = trim_trailing_ows(Value0),
            case NewCount > MaxHeaders of
                true ->
                    {error, too_many_headers};
                false ->
                    case is_token(Key) andalso is_valid_field_value(Value) of
                        true ->
                            read_headers(Socket, Rest, [{Key, Value} | Acc], NewCount,
                                         NewBytes, MaxHeaders, MaxHeaderBytes, Deadline);
                        false ->
                            {error, {bad_request, <<"invalid header field">>}}
                    end
            end;
        {ok, http_eoh, Rest} ->
            {ok, lists:reverse(Acc), Rest};
        {ok, {http_error, _}, _Rest} ->
            {error, {bad_request, <<"malformed header line">>}};
        {ok, _Other, _Rest} ->
            {error, {bad_request, <<"unexpected data in header section">>}};
        {error, too_long} ->
            {error, headers_too_large};
        {error, {timeout, _Buffered}} ->
            {error, request_timeout};
        {error, closed} ->
            {error, peer_closed};
        {error, {invalid, _Reason}} ->
            {error, {bad_request, <<"malformed header line">>}};
        {error, {socket, Reason}} ->
            {error, {socket_error, format_reason(Reason)}}
    end.

%% field-value: no CTLs except HTAB (rejects obs-fold CRLF, bare CR/LF, NUL),
%% and it must be valid UTF-8 because it becomes a Gleam String.
is_valid_field_value(Value) ->
    valid_field_bytes(Value) andalso is_utf8(Value).

valid_field_bytes(<<>>) -> true;
valid_field_bytes(<<$\t, Rest/binary>>) -> valid_field_bytes(Rest);
valid_field_bytes(<<C, _/binary>>) when C < 16#20; C =:= 16#7F -> false;
valid_field_bytes(<<_, Rest/binary>>) -> valid_field_bytes(Rest).

trim_trailing_ows(Value) ->
    string:trim(Value, trailing, " \t").

is_token(<<>>) -> false;
is_token(Bin) -> token_chars(Bin).

token_chars(<<>>) -> true;
token_chars(<<C, Rest/binary>>) when C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9 ->
    token_chars(Rest);
token_chars(<<C, Rest/binary>>) ->
    case lists:member(C, "!#$%&'*+-.^_`|~") of
        true -> token_chars(Rest);
        false -> false
    end.

recv_before_deadline(Socket, DeadlineMs) ->
    RemainingMs = DeadlineMs - now_ms(),
    case RemainingMs =< 0 of
        true -> {error, timeout};
        false -> gen_tcp:recv(Socket, 0, RemainingMs)
    end.

now_ms() ->
    erlang:monotonic_time(millisecond).

monotonic_ms() ->
    now_ms().

normalize_header_name(Name) when is_atom(Name) ->
    string:lowercase(atom_to_binary(Name, utf8));
normalize_header_name(Name) when is_binary(Name) ->
    string:lowercase(Name).

method_to_binary(Method) when is_atom(Method) -> atom_to_binary(Method, utf8);
method_to_binary(Method) when is_binary(Method) -> Method.

%% --- HTTP Request Body ---
%% The connection handler registers the framing of the current request
%% (validated Content-Length, deadlines) before calling the application.
%% Every body read goes through this context so it can never read past the
%% declared length, never block past the body/request deadline, and the
%% handler can tell afterwards whether the body was fully consumed (an
%% unconsumed body forces the connection to close instead of being parsed
%% as the next request).

http_body_begin(Socket, Length, ExpectContinue, BodyTimeoutMs, DeadlineMs)
  when is_integer(Length), Length >= 0, is_boolean(ExpectContinue),
       is_integer(BodyTimeoutMs), BodyTimeoutMs > 0, is_integer(DeadlineMs) ->
    put({brazier_http_body, Socket}, #{length => Length,
                                      remaining => Length,
                                      expect_continue => ExpectContinue andalso Length > 0,
                                      timeout => BodyTimeoutMs,
                                      deadline => DeadlineMs,
                                      failed => false}),
    nil.

%% Body bytes the handler has read so far: declared length minus what is
%% still unread. 0 when no request body context is active (for example the
%% WebSocket upgrade middleware check).
http_body_consumed(Socket) ->
    case get({brazier_http_body, Socket}) of
        #{length := Length, remaining := Remaining} -> Length - Remaining;
        undefined -> 0
    end.

%% The route pattern a handler tags for the request it is serving. Handlers
%% run in the connection process (run_handler/2 does not spawn), so the
%% process dictionary scopes the tag to one request: reset before the
%% handler, taken after it.
http_route_reset() ->
    erase(?ROUTE_KEY),
    nil.

http_route_tag(Route) when is_binary(Route) ->
    put(?ROUTE_KEY, Route),
    nil.

http_route_take() ->
    case erase(?ROUTE_KEY) of
        undefined -> <<"unknown">>;
        Route when is_binary(Route) -> Route
    end.

%% The connection process's pid as text: one id per HTTP connection, shared
%% by every keep-alive request on it.
http_connection_id() ->
    list_to_binary(pid_to_list(self())).

http_body_end(Socket) ->
    erase({brazier_http_body, Socket}),
    nil.

%% {ok, {RemainingBytes, Failed}} | {error, nil} when no request is active.
http_body_state(Socket) ->
    case get({brazier_http_body, Socket}) of
        #{remaining := Remaining, failed := Failed} -> {ok, {Remaining, Failed}};
        undefined -> {error, nil}
    end.

http_body_read(Socket, Length) when is_integer(Length) ->
    Key = {brazier_http_body, Socket},
    case get(Key) of
        undefined ->
            brazier_log_ffi:error(<<"brazier.http">>, "read_body called outside an active HTTP request"),
            {error, <<"read_body called outside an active HTTP request">>};
        #{failed := true} ->
            {error, <<"request body unavailable after an earlier read failure">>};
        _Ctx when Length < 0 ->
            {error, <<"negative body length requested">>};
        #{remaining := Remaining} when Length > Remaining ->
            {error, iolist_to_binary(io_lib:format(
                "requested ~p body bytes but only ~p remain of the declared Content-Length",
                [Length, Remaining]))};
        _Ctx when Length =:= 0 ->
            {ok, <<>>};
        Ctx = #{remaining := Remaining} ->
            case take_buffer(Socket) of
                <<Data:Length/binary, Rest/binary>> ->
                    %% The body bytes already arrived with the head.
                    put(?BUFFER_KEY(Socket), Rest),
                    put(Key, Ctx#{remaining := Remaining - Length, expect_continue := false}),
                    {ok, Data};
                Buffered ->
                    recv_body(Socket, Key, Ctx, Buffered, Length)
            end
    end.

%% Receive the part of a body read that is not buffered yet. Buffered holds
%% fewer than Length bytes; any failure marks the body failed, which closes
%% the connection, so the partial bytes are not needed afterwards.
recv_body(Socket, Key, Ctx = #{remaining := Remaining, timeout := Timeout,
                               deadline := Deadline}, Buffered, Length) ->
    case maybe_send_continue(Socket, Ctx) of
        {error, Reason} ->
            put(Key, Ctx#{failed := true}),
            {error, format_reason(Reason)};
        {ok, Ctx1} ->
            Wait = min(Timeout, Deadline - now_ms()),
            case Wait =< 0 of
                true ->
                    put(Key, Ctx1#{failed := true}),
                    {error, <<"request_deadline_exceeded">>};
                false ->
                    case gen_tcp:recv(Socket, Length - byte_size(Buffered), Wait) of
                        {ok, Data} ->
                            put(Key, Ctx1#{remaining := Remaining - Length}),
                            {ok, <<Buffered/binary, Data/binary>>};
                        {error, timeout} ->
                            put(Key, Ctx1#{failed := true}),
                            {error, <<"body_read_timeout">>};
                        {error, Reason} ->
                            put(Key, Ctx1#{failed := true}),
                            {error, format_reason(Reason)}
                    end
            end
    end.

maybe_send_continue(Socket, Ctx = #{expect_continue := true}) ->
    case gen_tcp:send(Socket, <<"HTTP/1.1 100 Continue\r\n\r\n">>) of
        ok -> {ok, Ctx#{expect_continue := false}};
        {error, Reason} -> {error, Reason}
    end;
maybe_send_continue(_Socket, Ctx) ->
    {ok, Ctx}.

%% Run an application handler, converting a crash into an explicit error so
%% the connection can answer 500 and close. Returns
%% {error, {handler_crash, Reason, Stacktrace}} with both formatted; the
%% caller (transport/http.run_handler) logs it once, with the route.
run_handler(Fun, Arg) ->
    try Fun(Arg) of
        Result -> {ok, Result}
    catch
        Class:Reason:Stacktrace ->
            {error, {handler_crash,
                     iolist_to_binary(io_lib:format("~p:~p", [Class, Reason])),
                     iolist_to_binary(io_lib:format("~p", [Stacktrace]))}}
    end.

%% Close a connection after the server decided to end it (error response,
%% Connection: close, unread body). Closing a socket that still has unread
%% request bytes makes the kernel send RST, and the client may then lose the
%% response it has not read yet. Like cowboy's linger: half-close the write
%% side so the response is delivered with FIN, discard what the peer still
%% sends for at most TimeoutMs / MaxBytes, then close.
%% Returns linger_peer_closed | linger_timeout | linger_limit |
%% {linger_socket_error, Bin} (the Gleam LingerOutcome constructors).
linger_close(Socket, TimeoutMs, MaxBytes)
  when is_integer(TimeoutMs), TimeoutMs > 0, is_integer(MaxBytes), MaxBytes > 0 ->
    Result = case gen_tcp:shutdown(Socket, write) of
        ok -> linger_loop(Socket, now_ms() + TimeoutMs, MaxBytes);
        {error, closed} -> linger_peer_closed;
        {error, enotconn} -> linger_peer_closed;
        {error, Reason} -> {linger_socket_error, format_reason(Reason)}
    end,
    gen_tcp:close(Socket),
    Result.

linger_loop(_Socket, _Deadline, BytesLeft) when BytesLeft =< 0 ->
    linger_limit;
linger_loop(Socket, Deadline, BytesLeft) ->
    case recv_before_deadline(Socket, Deadline) of
        {ok, Data} -> linger_loop(Socket, Deadline, BytesLeft - byte_size(Data));
        {error, timeout} -> linger_timeout;
        {error, closed} -> linger_peer_closed;
        {error, Reason} -> {linger_socket_error, format_reason(Reason)}
    end.

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

%% Encode one unfragmented server frame as iodata: [Header, Payload].
%% The payload is never copied into a new binary; gen_tcp:send/2 hands
%% the list to the socket as an I/O vector, so a large refc binary in the
%% payload (a model JSON) goes out by reference.
%% Reference: cowlib cow_ws:frame/2 returns [Header, Payload] iodata.
ws_encode_frame_iodata(Opcode, Payload) when is_integer(Opcode) ->
    Len = iolist_size(Payload),
    Header = if
        Len < 126 ->
            <<1:1, 0:3, Opcode:4, 0:1, Len:7>>;
        Len < 65536 ->
            <<1:1, 0:3, Opcode:4, 0:1, 126:7, Len:16>>;
        true ->
            <<1:1, 0:3, Opcode:4, 0:1, 127:7, Len:64>>
    end,
    [Header, Payload].

%% A JSON value whose text the caller already holds: gleam_json's Json is
%% iodata, so the text is spliced into the enclosing document unchanged.
%% The caller guarantees the binary is one complete JSON value; the
%% transport only passes text the runtime decoded (patch.Snapshot) or
%% encoded (patch.diff_snapshots) itself.
%% Reference: Phoenix.Socket.V2.JSONSerializer embeds encoded payloads
%% as iodata rather than re-encoding them.
json_raw(Json) when is_binary(Json) ->
    Json.

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

%% Per-IP WebSocket slots are kept by the listener's connection owner; see
%% brazier_http_conns:ws_acquire_self/2.

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
ws_classify_message({brazier_session_revoked, SessionId, Reason})
  when is_binary(SessionId), is_binary(Reason) ->
    {session_revoked, SessionId, Reason};
ws_classify_message({brazier_http_drain, _} = Msg) ->
    case brazier_http_conns:is_drain_message(Msg) of
        true ->
            brazier_http_conns:mark_draining(),
            server_draining;
        false ->
            {unexpected_message, list_to_binary(io_lib:format("~0P", [Msg, 8]))}
    end;
%% The rebuild broadcast of brazier/dev, on the topic its handlers subscribe
%% to when live reload is on (brazier_dev_ffi:notify_browser_reload/0).
ws_classify_message({brazier_pubsub, Topic, brazier_dev_reload} = Msg) ->
    case Topic =:= brazier_dev_ffi:live_reload_topic() of
        true -> dev_reload;
        false -> {unexpected_message, list_to_binary(io_lib:format("~0P", [Msg, 8]))}
    end;
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

%% --- Helpers ---

format_reason(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
format_reason(Reason) when is_binary(Reason) ->
    Reason;
format_reason(Reason) ->
    list_to_binary(io_lib:format("~p", [Reason])).
