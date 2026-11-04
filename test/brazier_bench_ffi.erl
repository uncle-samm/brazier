-module(brazier_bench_ffi).
%% Load generators and timers for the benchmark suite (brazier/bench/suite).
%%
%% Every generator checks every answer it times: a failed request, a
%% missing acknowledgement or a lost delivery is an error, never a fast
%% number. Nothing sleeps: each step waits for the answer it times, bounded
%% by a deadline.
-export([now_us/0, now_ns/0, machine/0, getenv/1, halt/1,
         http_round/4, ws_round/5, pubsub_fanout/5, gc/0,
         expect_empty_mailbox/1]).

now_us() -> erlang:monotonic_time(microsecond).

%% {ok, Value} | {error, nil}.
getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Exit the VM with Code once stdout is flushed (bench-check's verdict).
halt(Code) ->
    erlang:halt(Code, [{flush, true}]).

now_ns() -> erlang:monotonic_time(nanosecond).

%% Collect garbage in the calling process, so one scenario's heap does not
%% charge the next one's first round.
gc() ->
    true = erlang:garbage_collect(),
    nil.

%% {ok, nil} when the calling process's mailbox is empty, else {error, R}
%% naming the scenario and the first stray messages. A scenario that
%% leaves messages behind slows every later selective receive (each one
%% scans the whole queue), so later scenarios would measure the leak, not
%% the code. The messages are left in place: the run fails, it does not
%% tidy up.
expect_empty_mailbox(Scenario) ->
    case erlang:process_info(self(), message_queue_len) of
        {message_queue_len, 0} ->
            {ok, nil};
        {message_queue_len, Len} ->
            {messages, Messages} = erlang:process_info(self(), messages),
            {error, fmt("~ts left ~b stray message(s) in the bench process: ~0P",
                        [Scenario, Len, lists:sublist(Messages, 3), 12])}
    end.

%% What the numbers were measured on: [{Key, Value}] as binaries.
machine() ->
    {Family, Name} = os:type(),
    [{<<"otp_release">>, list_to_binary(erlang:system_info(otp_release))},
     {<<"erts_version">>, list_to_binary(erlang:system_info(version))},
     {<<"system_architecture">>, list_to_binary(erlang:system_info(system_architecture))},
     {<<"logical_processors">>, integer_to_binary(erlang:system_info(logical_processors_online))},
     {<<"schedulers_online">>, integer_to_binary(erlang:system_info(schedulers_online))},
     {<<"os">>, iolist_to_binary([atom_to_binary(Family), "/", atom_to_binary(Name)])},
     {<<"cpu">>, cpu_model(Family, Name)}].

%% The CPU model, read from the OS (sysctl on macOS, /proc/cpuinfo on
%% Linux). <<"unknown">> elsewhere, which machine fingerprints compare as
%% a value like any other.
cpu_model(unix, darwin) ->
    string:trim(list_to_binary(os:cmd("sysctl -n machdep.cpu.brand_string")));
cpu_model(unix, linux) ->
    case file:read_file("/proc/cpuinfo") of
        {ok, Info} ->
            Lines = binary:split(Info, <<"\n">>, [global]),
            case [string:trim(V) || L <- Lines,
                                    [K, V] <- [binary:split(L, <<":">>)],
                                    string:trim(K) =:= <<"model name">>] of
                [Model | _] -> Model;
                [] -> <<"unknown">>
            end;
        {error, _} -> <<"unknown">>
    end;
cpu_model(_, _) ->
    <<"unknown">>.

%% --- HTTP keep-alive ---

%% Clients concurrent keep-alive connections to Port, each sending Requests
%% sequential `GET /bench` requests and reading each response completely
%% (the server answers with a content-length) before the next one.
%% {ok, {ElapsedUs, LatenciesUs}} | {error, Reason}. Every response must be
%% a 200.
http_round(Port, Clients, Requests, TimeoutMs) ->
    Parent = self(),
    Start = now_us(),
    Pids = [spawn_monitor(fun() -> Parent ! {self(), http_client(Port, Requests, TimeoutMs)} end)
            || _ <- lists:seq(1, Clients)],
    case collect(Pids, Start, TimeoutMs, []) of
        {ok, Timed} ->
            case await_exits(Pids, TimeoutMs) of
                ok -> {ok, Timed};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

http_client(Port, Requests, TimeoutMs) ->
    case gen_tcp:connect("127.0.0.1", Port,
                         [binary, {active, false}, {packet, raw}, {nodelay, true}],
                         TimeoutMs) of
        {ok, Socket} ->
            Request = <<"GET /bench HTTP/1.1\r\nHost: bench\r\n\r\n">>,
            Result = http_loop(Socket, Request, Requests, TimeoutMs, []),
            ok = gen_tcp:close(Socket),
            Result;
        {error, Reason} ->
            {error, fmt("connect: ~0p", [Reason])}
    end.

http_loop(_Socket, _Request, 0, _TimeoutMs, Acc) ->
    {ok, Acc};
http_loop(Socket, Request, N, TimeoutMs, Acc) ->
    T0 = now_us(),
    case gen_tcp:send(Socket, Request) of
        ok ->
            case read_response(Socket, <<>>, TimeoutMs) of
                ok -> http_loop(Socket, Request, N - 1, TimeoutMs, [now_us() - T0 | Acc]);
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, fmt("send: ~0p", [Reason])}
    end.

read_response(Socket, Acc, TimeoutMs) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [<<"HTTP/1.1 200 ", _/binary>> = Head, Body] ->
            read_body(Socket, byte_size(Body), content_length(Head), TimeoutMs);
        [Head, _Body] ->
            {error, fmt("non-200 response: ~ts", [Head])};
        [_] ->
            case gen_tcp:recv(Socket, 0, TimeoutMs) of
                {ok, Data} -> read_response(Socket, <<Acc/binary, Data/binary>>, TimeoutMs);
                {error, Reason} -> {error, fmt("recv head: ~0p", [Reason])}
            end
    end.

read_body(_Socket, Have, Length, _TimeoutMs) when Have =:= Length -> ok;
read_body(Socket, Have, Length, TimeoutMs) when Have < Length ->
    case gen_tcp:recv(Socket, 0, TimeoutMs) of
        {ok, Data} -> read_body(Socket, Have + byte_size(Data), Length, TimeoutMs);
        {error, Reason} -> {error, fmt("recv body: ~0p", [Reason])}
    end;
read_body(_Socket, Have, Length, _TimeoutMs) ->
    {error, fmt("body longer than its content-length (~b > ~b)", [Have, Length])}.

content_length(Head) ->
    Lines = binary:split(Head, <<"\r\n">>, [global]),
    [Value] = [V || L <- Lines,
                    [K, V] <- [binary:split(L, <<": ">>)],
                    string:lowercase(K) =:= <<"content-length">>],
    binary_to_integer(Value).

%% --- WebSocket events ---

%% Conns joined WebSocket connections to Host:Port, each sending Events
%% events one at a time and timing each from its send to the patch that
%% acknowledges it (brazier_stress_ffi checks every answer). All
%% connections join before any sends, so the round times only events.
%% Every connection closes with the 1000 handshake afterwards.
%% {ok, {ElapsedUs, LatenciesUs}} | {error, Reason}.
ws_round(Host, Port, Conns, Events, TimeoutMs) ->
    Parent = self(),
    Go = make_ref(),
    Pids = [spawn_monitor(fun() -> ws_client(Parent, Go, Host, Port, Events, TimeoutMs) end)
            || _ <- lists:seq(1, Conns)],
    case await_joined(Pids, TimeoutMs) of
        ok ->
            Start = now_us(),
            [Pid ! Go || {Pid, _} <- Pids],
            Timed = collect(Pids, Start, TimeoutMs, []),
            Closed = await_closed(Pids, TimeoutMs, ok),
            case {Timed, Closed} of
                {{ok, _}, ok} -> Timed;
                {{ok, _}, {error, Reason}} -> {error, Reason};
                {{error, _}, _} -> Timed
            end;
        {error, Reason} ->
            [exit(Pid, kill) || {Pid, _} <- Pids],
            {error, Reason}
    end.

ws_client(Parent, Go, Host, Port, Events, TimeoutMs) ->
    case brazier_stress_ffi:connect_and_join(Host, Port, 0, TimeoutMs) of
        {ok, {Conn, 0}} ->
            Parent ! {self(), joined},
            receive Go -> ok end,
            case brazier_stress_ffi:timed_events(Conn, 1, Events, TimeoutMs) of
                {ok, {Conn1, Latencies}} ->
                    Parent ! {self(), {ok, Latencies}},
                    Parent ! {self(), closed, brazier_stress_ffi:close_handshake(Conn1, TimeoutMs)};
                {error, Reason} ->
                    Parent ! {self(), {error, Reason}}
            end;
        {error, Reason} ->
            Parent ! {self(), {error, Reason}}
    end.

await_joined([], _TimeoutMs) -> ok;
await_joined([{Pid, Ref} | Rest], TimeoutMs) ->
    receive
        {Pid, joined} -> await_joined(Rest, TimeoutMs);
        {Pid, {error, Reason}} -> {error, <<"join: ", Reason/binary>>};
        {'DOWN', Ref, process, Pid, Why} -> {error, fmt("client died joining: ~0p", [Why])}
    after TimeoutMs ->
        {error, <<"a client did not join in time">>}
    end.

await_closed([], _TimeoutMs, Result) -> Result;
await_closed([{Pid, Ref} | Rest], TimeoutMs, Result) ->
    receive
        {Pid, closed, {ok, nil}} ->
            case await_exits([{Pid, Ref}], TimeoutMs) of
                ok -> await_closed(Rest, TimeoutMs, Result);
                {error, Reason} -> await_closed(Rest, TimeoutMs, {error, Reason})
            end;
        {Pid, closed, {error, Reason}} ->
            await_closed(Rest, TimeoutMs, {error, <<"close: ", Reason/binary>>});
        {'DOWN', Ref, process, Pid, Why} ->
            await_closed(Rest, TimeoutMs, {error, fmt("client died closing: ~0p", [Why])})
    after TimeoutMs ->
        {error, <<"a client did not close in time">>}
    end.

%% Wait for {Pid, {ok, Latencies}} from every client; the round ends when
%% the last one answers.
collect([], Start, _TimeoutMs, Acc) ->
    {ok, {now_us() - Start, lists:append(Acc)}};
collect([{Pid, Ref} | Rest], Start, TimeoutMs, Acc) ->
    receive
        {Pid, {ok, Latencies}} -> collect(Rest, Start, TimeoutMs, [Latencies | Acc]);
        {Pid, {error, Reason}} -> {error, Reason};
        {'DOWN', Ref, process, Pid, Why} -> {error, fmt("client died: ~0p", [Why])}
    after TimeoutMs ->
        {error, <<"a client did not finish in time">>}
    end.

%% Wait for every finished client's monitor to fire with `normal`. Each
%% client's 'DOWN' must be received: one left in the mailbox slows every
%% later selective receive in this process (see expect_empty_mailbox/1).
await_exits([], _TimeoutMs) -> ok;
await_exits([{Pid, Ref} | Rest], TimeoutMs) ->
    receive
        {'DOWN', Ref, process, Pid, normal} -> await_exits(Rest, TimeoutMs);
        {'DOWN', Ref, process, Pid, Why} -> {error, fmt("client exited: ~0p", [Why])}
    after TimeoutMs ->
        {error, <<"a finished client did not exit in time">>}
    end.

%% --- PubSub fan-out ---

%% Subscribers processes subscribe to Topic; then Warmup + Broadcasts
%% broadcasts go out one at a time through brazier/pubsub.try_broadcast,
%% each timed from the call until every subscriber has received it (each
%% one answers the coordinator). The first Warmup are discarded, so the
%% measured broadcasts reach subscribers that have already run.
%% {ok, LatenciesNs} | {error, Reason}. The subscribers are stopped, and
%% their exit awaited, before it returns.
pubsub_fanout(Topic, Subscribers, Warmup, Broadcasts, TimeoutMs) ->
    Parent = self(),
    Subs = [spawn_monitor(fun() -> subscriber(Parent, Topic) end)
            || _ <- lists:seq(1, Subscribers)],
    Result = case await_subscribed(Subs, TimeoutMs) of
        ok ->
            case fanout(Topic, Subscribers, 1, Warmup + Broadcasts, TimeoutMs, []) of
                {ok, Latencies} -> {ok, lists:nthtail(Warmup, Latencies)};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end,
    [Pid ! stop || {Pid, _} <- Subs],
    case {Result, await_exits(Subs, TimeoutMs)} of
        {{ok, _}, {error, StopReason}} -> {error, <<"subscriber stop: ", StopReason/binary>>};
        {_, _} -> Result
    end.

subscriber(Parent, Topic) ->
    case 'brazier@pubsub':try_subscribe(Topic) of
        {ok, nil} ->
            Parent ! {self(), subscribed},
            subscriber_loop(Parent, Topic);
        {error, Reason} ->
            Parent ! {self(), {error, fmt("subscribe: ~0p", [Reason])}}
    end.

subscriber_loop(Parent, Topic) ->
    receive
        {brazier_pubsub, Topic, {bench, N}} ->
            Parent ! {delivered, N},
            subscriber_loop(Parent, Topic);
        stop ->
            ok
    end.

await_subscribed([], _TimeoutMs) -> ok;
await_subscribed([{Pid, Ref} | Rest], TimeoutMs) ->
    receive
        {Pid, subscribed} -> await_subscribed(Rest, TimeoutMs);
        {Pid, {error, Reason}} -> {error, Reason};
        {'DOWN', Ref, process, Pid, Why} -> {error, fmt("subscriber died: ~0p", [Why])}
    after TimeoutMs ->
        {error, <<"a subscriber did not subscribe in time">>}
    end.

fanout(_Topic, _Subscribers, N, Broadcasts, _TimeoutMs, Acc) when N > Broadcasts ->
    {ok, lists:reverse(Acc)};
fanout(Topic, Subscribers, N, Broadcasts, TimeoutMs, Acc) ->
    T0 = now_ns(),
    case 'brazier@pubsub':try_broadcast(Topic, {bench, N}) of
        {ok, nil} ->
            case await_deliveries(N, Subscribers, TimeoutMs) of
                ok -> fanout(Topic, Subscribers, N + 1, Broadcasts, TimeoutMs, [now_ns() - T0 | Acc]);
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, fmt("broadcast: ~0p", [Reason])}
    end.

await_deliveries(_N, 0, _TimeoutMs) -> ok;
await_deliveries(N, Remaining, TimeoutMs) ->
    receive
        {delivered, N} -> await_deliveries(N, Remaining - 1, TimeoutMs)
    after TimeoutMs ->
        {error, fmt("broadcast ~b: ~b subscribers did not receive it", [N, Remaining])}
    end.

fmt(Format, Args) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).
