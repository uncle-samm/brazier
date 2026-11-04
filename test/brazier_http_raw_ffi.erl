-module(brazier_http_raw_ffi).
%% Raw-socket HTTP/1.1 client for server conformance tests. It sends exact
%% bytes and parses responses itself so tests can observe framing,
%% pipelining and connection closure precisely.
-export([connect/1, send/2, recv_response/3, recv_raw/3, wait_closed/2, close/1,
         kill/1, acceptor_pids/1, acceptor_pool/2, sleep_then_send/3, crash/0]).

-define(BUF(S), {brazier_http_raw_buffer, S}).

connect(Port) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}, {packet, raw}], 2000) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, reason(Reason)}
    end.

send(Socket, Data) ->
    case gen_tcp:send(Socket, Data) of
        ok -> {ok, nil};
        {error, Reason} -> {error, reason(Reason)}
    end.

%% Send Data after DelayMs (used to drip bytes slowly).
sleep_then_send(Socket, DelayMs, Data) ->
    timer:sleep(DelayMs),
    send(Socket, Data).

close(Socket) ->
    ok = gen_tcp:close(Socket),
    nil.

%% Read one response. ExpectBody is false for HEAD requests. 1xx interim
%% responses are returned like any other (the caller reads again).
%% {ok, {Status, [{LowerName, Value}], Body}} | {error, Bin}
recv_response(Socket, TimeoutMs, ExpectBody) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    Buffer = take(Socket),
    case packet(Socket, http_bin, Buffer, Deadline) of
        {ok, {http_response, _Version, Status, _Phrase}, Rest} ->
            case headers(Socket, Rest, [], Deadline) of
                {ok, Headers, Rest1} ->
                    BodyLength = case ExpectBody andalso not bodyless(Status) of
                        false -> 0;
                        true -> content_length(Headers)
                    end,
                    case body(Socket, Rest1, BodyLength, Deadline) of
                        {ok, Body, Rest2} ->
                            put(?BUF(Socket), Rest2),
                            {ok, {Status, Headers, Body}};
                        {error, _} = E -> E
                    end;
                {error, _} = E -> E
            end;
        {ok, Other, _} ->
            {error, iolist_to_binary(io_lib:format("unexpected packet ~p", [Other]))};
        {error, _} = E ->
            E
    end.

%% Everything the server sends until it closes, or {error, timeout}.
recv_raw(Socket, TimeoutMs, Acc0) ->
    Acc = <<(take(Socket))/binary, Acc0/binary>>,
    case gen_tcp:recv(Socket, 0, TimeoutMs) of
        {ok, Data} -> recv_raw(Socket, TimeoutMs, <<Acc/binary, Data/binary>>);
        {error, closed} -> {ok, Acc};
        {error, timeout} -> {error, <<"timeout">>};
        {error, Reason} -> {error, reason(Reason)}
    end.

%% True when the server closes the connection within TimeoutMs without
%% sending anything else. Unexpected data is reported as an error.
wait_closed(Socket, TimeoutMs) ->
    case take(Socket) of
        <<>> ->
            case gen_tcp:recv(Socket, 0, TimeoutMs) of
                {error, closed} -> {ok, true};
                {error, econnreset} -> {ok, true};
                {error, timeout} -> {ok, false};
                {ok, Data} -> {error, <<"unexpected data: ", Data/binary>>};
                {error, Reason} -> {error, reason(Reason)}
            end;
        Leftover ->
            {error, <<"unexpected buffered data: ", Leftover/binary>>}
    end.

%% A request handler that crashes (exercises crash isolation).
crash() ->
    erlang:error(brazier_test_handler_crash).

kill(Pid) ->
    exit(Pid, kill),
    nil.

%% Acceptor pids under the listener supervisor's acceptor pool.
acceptor_pids(ListenerSup) ->
    Pools = [Pid || {_, Pid, supervisor, _} <- supervisor:which_children(ListenerSup),
                    is_pid(Pid)],
    lists:append([[Pid || {_, Pid, worker, _} <- supervisor:which_children(Pool), is_pid(Pid)]
                  || Pool <- Pools]).

%% The acceptor pool supervisor under ListenerSup that supervises Acceptor:
%% {ok, Pool} | {error, nil}.
acceptor_pool(ListenerSup, Acceptor) ->
    Pools = [Pid || {_, Pid, supervisor, _} <- supervisor:which_children(ListenerSup),
                    is_pid(Pid)],
    Owners = [Pool || Pool <- Pools,
                      lists:keymember(Acceptor, 2, supervisor:which_children(Pool))],
    case Owners of
        [Pool] -> {ok, Pool};
        _ -> {error, nil}
    end.

%% --- helpers ---

take(Socket) ->
    case erase(?BUF(Socket)) of
        undefined -> <<>>;
        Bin -> Bin
    end.

packet(Socket, Type, Buffer, Deadline) ->
    case erlang:decode_packet(Type, Buffer, []) of
        {ok, Packet, Rest} -> {ok, Packet, Rest};
        {more, _} ->
            case recv(Socket, 0, Deadline) of
                {ok, Data} -> packet(Socket, Type, <<Buffer/binary, Data/binary>>, Deadline);
                {error, _} = E -> E
            end;
        {error, Reason} -> {error, reason(Reason)}
    end.

headers(Socket, Buffer, Acc, Deadline) ->
    case packet(Socket, httph_bin, Buffer, Deadline) of
        {ok, {http_header, _, Name, _, Value}, Rest} ->
            headers(Socket, Rest, [{lower(Name), Value} | Acc], Deadline);
        {ok, http_eoh, Rest} ->
            {ok, lists:reverse(Acc), Rest};
        {ok, Other, _} ->
            {error, iolist_to_binary(io_lib:format("bad header ~p", [Other]))};
        {error, _} = E ->
            E
    end.

body(_Socket, Buffer, Length, _Deadline) when byte_size(Buffer) >= Length ->
    <<Body:Length/binary, Rest/binary>> = Buffer,
    {ok, Body, Rest};
body(Socket, Buffer, Length, Deadline) ->
    case recv(Socket, Length - byte_size(Buffer), Deadline) of
        {ok, Data} -> {ok, <<Buffer/binary, Data/binary>>, <<>>};
        {error, _} = E -> E
    end.

recv(Socket, Length, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true -> {error, <<"timeout">>};
        false ->
            case gen_tcp:recv(Socket, Length, Remaining) of
                {ok, Data} -> {ok, Data};
                {error, Reason} -> {error, reason(Reason)}
            end
    end.

bodyless(Status) -> Status < 200 orelse Status =:= 204 orelse Status =:= 304.

content_length(Headers) ->
    case lists:keyfind(<<"content-length">>, 1, Headers) of
        {_, Value} -> binary_to_integer(Value);
        false -> 0
    end.

lower(Name) when is_atom(Name) -> string:lowercase(atom_to_binary(Name, utf8));
lower(Name) when is_binary(Name) -> string:lowercase(Name).

reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(Reason) when is_binary(Reason) -> Reason;
reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
