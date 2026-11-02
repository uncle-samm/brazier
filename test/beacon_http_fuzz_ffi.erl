-module(beacon_http_fuzz_ffi).
%% Raw-socket fuzzing and keep-alive load drivers for the HTTP server.
%%
%% Fuzz inputs are mutations of a corpus of valid requests plus random
%% blobs, generated from a fixed seed so a failure is reproducible.
-export([cases/2, exchange/3, load/4, report/1]).

-define(CORPUS, [
    <<"GET / HTTP/1.1\r\nHost: test\r\n\r\n">>,
    <<"GET /a/b?x=1&y=%20 HTTP/1.1\r\nHost: test\r\nAccept: */*\r\n\r\n">>,
    <<"HEAD /head HTTP/1.1\r\nHost: test\r\n\r\n">>,
    <<"OPTIONS * HTTP/1.1\r\nHost: test\r\n\r\n">>,
    <<"GET http://test/abs HTTP/1.1\r\nHost: test\r\n\r\n">>,
    <<"GET /old HTTP/1.0\r\n\r\n">>,
    <<"POST /echo HTTP/1.1\r\nHost: test\r\nContent-Length: 5\r\n\r\nhello">>,
    <<"POST /echo HTTP/1.1\r\nHost: test\r\nContent-Length: 3\r\n"
      "Expect: 100-continue\r\n\r\nabc">>,
    <<"GET /one HTTP/1.1\r\nHost: test\r\n\r\nGET /two HTTP/1.1\r\nHost: test\r\n\r\n">>,
    <<"GET /close HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n">>,
    <<"POST /echo HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n\r\n"
      "5\r\nhello\r\n0\r\n\r\n">>,
    <<"GET / HTTP/1.1\r\nHost: test\r\nCookie: a=b; c=d\r\n"
      "X-Forwarded-For: 1.2.3.4\r\n\r\n">>
]).

%% Interesting bytes for insertion: delimiters, controls and high bytes.
-define(SPECIAL, [<<"\r">>, <<"\n">>, <<"\r\n">>, <<"\r\n\r\n">>, <<0>>, <<" ">>,
                  <<":">>, <<"\t">>, <<"%">>, <<"/../">>, <<255>>, <<128>>,
                  <<"Content-Length: 99999999999999999999\r\n">>,
                  <<"Content-Length: -1\r\n">>,
                  <<"Transfer-Encoding: chunked\r\n">>,
                  <<"Host: other\r\n">>]).

%% N fuzz inputs from Seed (a positive integer).
cases(Seed, N) ->
    State0 = rand:seed_s(exsss, {Seed, Seed * 7 + 1, Seed * 13 + 2}),
    {Cases, _} = lists:mapfoldl(fun(_, S) -> one_case(S) end, State0, lists:seq(1, N)),
    Cases.

one_case(S0) ->
    {Pick, S1} = rand:uniform_s(10, S0),
    case Pick of
        1 -> random_blob(S1);
        2 -> long_line(S1);
        _ ->
            {Base, S2} = pick(?CORPUS, S1),
            {Rounds, S3} = rand:uniform_s(4, S2),
            mutate_n(Base, Rounds, S3)
    end.

random_blob(S0) ->
    {Len, S1} = rand:uniform_s(2048, S0),
    {Bytes, S2} = rand:bytes_s(Len, S1),
    {Bytes, S2}.

long_line(S0) ->
    {Len, S1} = rand:uniform_s(20000, S0),
    {<<"GET /", (binary:copy(<<"a">>, Len))/binary, " HTTP/1.1\r\nHost: test\r\n\r\n">>, S1}.

mutate_n(Bin, 0, S) -> {Bin, S};
mutate_n(Bin, N, S0) ->
    {Bin1, S1} = mutate(Bin, S0),
    mutate_n(Bin1, N - 1, S1).

mutate(<<>>, S0) ->
    pick(?SPECIAL, S0);
mutate(Bin, S0) ->
    Size = byte_size(Bin),
    {Op, S1} = rand:uniform_s(7, S0),
    {Pos, S2} = rand:uniform_s(Size, S1),
    At = Pos - 1,
    <<Before:At/binary, After/binary>> = Bin,
    case Op of
        1 ->
            %% Flip one byte.
            <<Byte, Rest/binary>> = After,
            {Mask, S3} = rand:uniform_s(255, S2),
            {<<Before/binary, (Byte bxor Mask), Rest/binary>>, S3};
        2 ->
            %% Insert a special token.
            {Token, S3} = pick(?SPECIAL, S2),
            {<<Before/binary, Token/binary, After/binary>>, S3};
        3 ->
            %% Delete a range.
            {Len, S3} = rand:uniform_s(byte_size(After), S2),
            <<_:Len/binary, Rest/binary>> = After,
            {<<Before/binary, Rest/binary>>, S3};
        4 ->
            %% Duplicate a range.
            {Len, S3} = rand:uniform_s(byte_size(After), S2),
            <<Chunk:Len/binary, _/binary>> = After,
            {<<Before/binary, Chunk/binary, After/binary>>, S3};
        5 ->
            %% Truncate.
            {Before, S2};
        6 ->
            %% Insert random bytes.
            {Len, S3} = rand:uniform_s(16, S2),
            {Bytes, S4} = rand:bytes_s(Len, S3),
            {<<Before/binary, Bytes/binary, After/binary>>, S4};
        7 ->
            %% Splice another request onto the end.
            {Other, S3} = pick(?CORPUS, S2),
            {<<Bin/binary, Other/binary>>, S3}
    end.

pick(List, S0) ->
    {I, S1} = rand:uniform_s(length(List), S0),
    {lists:nth(I, List), S1}.

%% Send Data, half-close, and read until the server closes.
%% {ok, Bytes} | {error, Reason}. A reset after or instead of the response
%% counts as a close: the server may close with unread input pending.
exchange(Port, Data, TimeoutMs) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}, {packet, raw}], 2000) of
        {error, Reason} ->
            {error, fmt("connect: ~p", [Reason])};
        {ok, Socket} ->
            %% The server may already have closed (e.g. after an early 400),
            %% so a failed send is not itself an error: read what it sent.
            _ = gen_tcp:send(Socket, Data),
            _ = gen_tcp:shutdown(Socket, write),
            Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
            Result = drain(Socket, Deadline, <<>>),
            ok = gen_tcp:close(Socket),
            Result
    end.

drain(Socket, Deadline, Acc) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true -> {error, fmt("server did not close; got ~p", [Acc])};
        false ->
            case gen_tcp:recv(Socket, 0, Remaining) of
                {ok, Data} -> drain(Socket, Deadline, <<Acc/binary, Data/binary>>);
                {error, closed} -> {ok, Acc};
                {error, econnreset} -> {ok, Acc};
                {error, timeout} -> {error, fmt("server did not close; got ~p", [Acc])};
                {error, Reason} -> {error, fmt("recv: ~p", [Reason])}
            end
    end.

%% Clients concurrent keep-alive connections, each sending Requests
%% sequential GETs on one socket and checking every response body.
%% {ok, {TotalRequests, ElapsedMicroseconds}} | {error, Reason}.
load(Port, Clients, Requests, TimeoutMs) ->
    Parent = self(),
    Ref = make_ref(),
    Start = erlang:monotonic_time(microsecond),
    Pids = [spawn_link(fun() -> Parent ! {Ref, self(), client(Port, C, Requests)} end)
            || C <- lists:seq(1, Clients)],
    Results = [receive {Ref, Pid, R} -> R after TimeoutMs -> {error, <<"client timed out">>} end
               || Pid <- Pids],
    Elapsed = erlang:monotonic_time(microsecond) - Start,
    case [E || {error, _} = E <- Results] of
        [] -> {ok, {Clients * Requests, Elapsed}};
        [{error, Reason} | _] -> {error, Reason}
    end.

client(Port, C, Requests) ->
    case beacon_http_raw_ffi:connect(Port) of
        {error, Reason} -> {error, Reason};
        {ok, Socket} ->
            Result = client_loop(Socket, C, 1, Requests),
            beacon_http_raw_ffi:close(Socket),
            Result
    end.

client_loop(_Socket, _C, N, Requests) when N > Requests -> ok;
client_loop(Socket, C, N, Requests) ->
    Path = iolist_to_binary(io_lib:format("/load/~p/~p", [C, N])),
    Request = <<"GET ", Path/binary, " HTTP/1.1\r\nHost: test\r\n\r\n">>,
    Expected = <<Path/binary, "|test">>,
    case beacon_http_raw_ffi:send(Socket, Request) of
        {error, Reason} -> {error, fmt("client ~p request ~p send: ~s", [C, N, Reason])};
        {ok, nil} ->
            case beacon_http_raw_ffi:recv_response(Socket, 5000, true) of
                {ok, {200, _Headers, Expected}} ->
                    client_loop(Socket, C, N + 1, Requests);
                {ok, Other} ->
                    {error, fmt("client ~p request ~p: unexpected ~p", [C, N, Other])};
                {error, Reason} ->
                    {error, fmt("client ~p request ~p recv: ~s", [C, N, Reason])}
            end
    end.

%% Print a line to the console, bypassing eunit output capture.
report(Line) ->
    io:format(user, "~ts~n", [Line]),
    nil.

fmt(Format, Args) ->
    iolist_to_binary(io_lib:format(Format, Args)).
