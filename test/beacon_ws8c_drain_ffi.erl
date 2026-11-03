%% Test helpers for ws8c_drain_test: a raw HTTP/1.1 client that reads one
%% response at a time, trace-based synchronization (no sleeps), and OS
%% signal and environment plumbing for peer nodes.
-module(beacon_ws8c_drain_ffi).
-export([connect/1, send/2, read_response/2, await_closed/2,
         trace_receive/1, await_drain_received/2,
         trace_install/1, await_install/2,
         sigterm_self/0, signal_handlers/0, putenv/2, unsetenv/1]).

connect(Port) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}, {packet, raw}], 5000) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, format(Reason)}
    end.

send(Socket, Bytes) ->
    case gen_tcp:send(Socket, Bytes) of
        ok -> {ok, nil};
        {error, Reason} -> {error, format(Reason)}
    end.

%% One response: {ok, {Status, [{LowerName, Value}], Body}}. The body is
%% read by Content-Length (every Beacon response carries one).
read_response(Socket, Timeout) ->
    read_status(Socket, <<>>, Timeout).

read_status(Socket, Buf, Timeout) ->
    case erlang:decode_packet(http_bin, Buf, []) of
        {ok, {http_response, _Version, Status, _Phrase}, Rest} ->
            read_headers(Socket, Rest, Status, [], Timeout);
        {more, _} ->
            with_more(Socket, Timeout, fun(Data) ->
                read_status(Socket, <<Buf/binary, Data/binary>>, Timeout)
            end);
        Other ->
            {error, format({bad_status_line, Other})}
    end.

read_headers(Socket, Buf, Status, Headers, Timeout) ->
    case erlang:decode_packet(httph_bin, Buf, []) of
        {ok, {http_header, _, Name, _, Value}, Rest} ->
            Lower = string:lowercase(header_name(Name)),
            read_headers(Socket, Rest, Status, [{Lower, Value} | Headers], Timeout);
        {ok, http_eoh, Rest} ->
            Length = case lists:keyfind(<<"content-length">>, 1, Headers) of
                {_, L} -> binary_to_integer(L);
                false -> 0
            end,
            read_body(Socket, Rest, Length, Status, lists:reverse(Headers), Timeout);
        {more, _} ->
            with_more(Socket, Timeout, fun(Data) ->
                read_headers(Socket, <<Buf/binary, Data/binary>>, Status, Headers, Timeout)
            end);
        Other ->
            {error, format({bad_header, Other})}
    end.

read_body(_Socket, Buf, Length, Status, Headers, _Timeout) when byte_size(Buf) >= Length ->
    <<Body:Length/binary, _/binary>> = Buf,
    {ok, {Status, Headers, Body}};
read_body(Socket, Buf, Length, Status, Headers, Timeout) ->
    with_more(Socket, Timeout, fun(Data) ->
        read_body(Socket, <<Buf/binary, Data/binary>>, Length, Status, Headers, Timeout)
    end).

with_more(Socket, Timeout, Next) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} -> Next(Data);
        {error, Reason} -> {error, format(Reason)}
    end.

header_name(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
header_name(Name) when is_binary(Name) -> Name.

%% The server closed the connection without sending anything more.
await_closed(Socket, Timeout) ->
    Result = case gen_tcp:recv(Socket, 0, Timeout) of
        {error, closed} -> {ok, nil};
        {ok, Data} -> {error, format({unexpected_bytes, Data})};
        {error, Reason} -> {error, format(Reason)}
    end,
    gen_tcp:close(Socket),
    Result.

%% Trace the messages Pid receives, so the test can wait for the drain
%% message to reach a handler.
trace_receive(Pid) ->
    1 = erlang:trace(Pid, true, ['receive']),
    nil.

await_drain_received(Pid, Timeout) ->
    receive
        {trace, Pid, 'receive', {beacon_http_drain, _Conns}} ->
            erlang:trace(Pid, false, ['receive']),
            {ok, nil};
        {trace, Pid, 'receive', _Other} ->
            await_drain_received(Pid, Timeout)
    after Timeout ->
        {error, <<"the handler never received the drain message">>}
    end.

%% Trace Pid's call of beacon_signal_handler:install/1, so the test sends
%% SIGTERM only once the Beacon handler is installed.
%% trace_pattern only matches loaded code, and a fresh peer loads the
%% module on its first call: load it first, and require exactly one match.
trace_install(Pid) ->
    {module, beacon_signal_handler} = code:ensure_loaded(beacon_signal_handler),
    1 = erlang:trace_pattern({beacon_signal_handler, install, 1},
                             [{'_', [], [{return_trace}]}], [local]),
    1 = erlang:trace(Pid, true, [call]),
    nil.

await_install(Pid, Timeout) ->
    receive
        {trace, Pid, return_from, {beacon_signal_handler, install, 1}, Result} ->
            erlang:trace(Pid, false, [call]),
            erlang:trace_pattern({beacon_signal_handler, install, 1}, false, [local]),
            case Result of
                {ok, nil} -> {ok, nil};
                Other -> {error, format(Other)}
            end;
        {trace, Pid, call, _} ->
            await_install(Pid, Timeout)
    after Timeout ->
        {error, <<"wait_forever never installed its SIGTERM handler">>}
    end.

%% A real SIGTERM to this node's OS process.
sigterm_self() ->
    _ = os:cmd("kill -TERM " ++ os:getpid()),
    nil.

signal_handlers() ->
    [atom_to_binary(H, utf8) || H <- gen_event:which_handlers(erl_signal_server)].

putenv(Name, Value) ->
    true = os:putenv(binary_to_list(Name), binary_to_list(Value)),
    nil.

unsetenv(Name) ->
    true = os:unsetenv(binary_to_list(Name)),
    nil.

format(Term) ->
    iolist_to_binary(io_lib:format("~p", [Term])).
