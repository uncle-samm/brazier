-module(brazier_bench_ffi).
%% Load generators and timers for the benchmark suite (brazier/bench/suite).
%%
%% Every generator checks every answer it times: a failed request, a
%% missing acknowledgement or a lost delivery is an error, never a fast
%% number. Nothing sleeps: each step waits for the answer it times, bounded
%% by a deadline.
-export([now_us/0, now_ns/0, machine/0, load_average/0, utc_now/0,
         getenv/1, halt/1,
         http_round/6, http_fetch/3, gunzip/1, ws_round/6, pubsub_fanout/5,
         presence_fill/5, presence_release/2, presence_round/5, presence_list_sample/4,
         gc/0, expect_empty_mailbox/1, isolated/2, vm_census/0]).

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

%% Run Scenario (a fun returning {ok, Metrics} | {error, Reason}) in a
%% fresh process and return its result. The bench process keeps the
%% prepared fixtures and every earlier run's results, so its heap grows
%% run over run, and a scenario timed in it pays for collecting that heap:
%% the 1-subscriber fan-out p99 rose run over run (2.7 to 5.5 us across
%% five runs) in the bench process and held still on its own. Benchee runs
%% each scenario in its own process for the same reason. The scenario's
%% mailbox must be empty when it finishes, and so must the caller's after
%% the answer (see expect_empty_mailbox/1). The caller's waits need no
%% timeout of their own: every wait in a scenario is bounded, so the
%% process answers or exits, and the monitor reports the exit.
isolated(Name, Scenario) ->
    Caller = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        Result = case Scenario() of
            {ok, Metrics} ->
                case expect_empty_mailbox(Name) of
                    {ok, nil} -> {ok, Metrics};
                    {error, Stray} -> {error, Stray}
                end;
            {error, Reason} ->
                {error, Reason}
        end,
        Caller ! {self(), isolated_done, Result}
    end),
    receive
        {Pid, isolated_done, Result} ->
            receive
                {'DOWN', Ref, process, Pid, normal} ->
                    case {Result, expect_empty_mailbox(Name)} of
                        {{ok, _}, {error, Stray}} -> {error, Stray};
                        {_, _} -> Result
                    end;
                {'DOWN', Ref, process, Pid, Why} ->
                    {error, fmt("~ts: its process exited: ~0p", [Name, Why])}
            end;
        {'DOWN', Ref, process, Pid, Why} ->
            {error, fmt("~ts: its process died: ~0p", [Name, Why])}
    end.

%% What the VM holds, as [{Key, Count}]: printed after every run, so that
%% a scenario leaking processes, ports or tables (which would slow every
%% later run in the same VM) shows as a count that grows run over run.
vm_census() ->
    [{<<"processes">>, erlang:system_info(process_count)},
     {<<"ports">>, erlang:system_info(port_count)},
     {<<"ets_tables">>, length(ets:all())},
     {<<"memory_kb">>, erlang:memory(total) div 1024},
     {<<"binary_kb">>, erlang:memory(binary) div 1024},
     {<<"atoms">>, erlang:system_info(atom_count)}].

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

%% The 1, 5 and 15 minute load averages as <<"3.66 6.15 6.81">>, read from
%% the OS (sysctl vm.loadavg on macOS, /proc/loadavg on Linux).
%% {ok, Bin} | {error, Reason}: a baseline records the load it was taken
%% under, and an OS that does not say is an error, not a made-up number.
load_average() ->
    case os:type() of
        {unix, darwin} ->
            %% sysctl prints "{ 3.66 6.15 6.81 }".
            load_fields(list_to_binary(os:cmd("sysctl -n vm.loadavg")));
        {unix, linux} ->
            case file:read_file("/proc/loadavg") of
                {ok, Text} -> load_fields(Text);
                {error, Reason} -> {error, fmt("read /proc/loadavg: ~0p", [Reason])}
            end;
        Other ->
            {error, fmt("no load average on ~0p", [Other])}
    end.

load_fields(Text) ->
    Fields = [F || F <- string:lexemes(Text, " {}\n"), F =/= <<>>],
    case Fields of
        [One, Five, Fifteen | _] ->
            case lists:all(fun is_number_text/1, [One, Five, Fifteen]) of
                true -> {ok, iolist_to_binary(lists:join(<<" ">>, [One, Five, Fifteen]))};
                false -> {error, fmt("unreadable load average: ~0p", [Text])}
            end;
        _ ->
            {error, fmt("unreadable load average: ~0p", [Text])}
    end.

is_number_text(Text) ->
    case string:to_float(Text) of
        {F, <<>>} when is_float(F) -> true;
        _ -> false
    end.

%% The current UTC time as an RFC 3339 binary, for the baseline's record.
utc_now() ->
    list_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second),
                                                   [{offset, "Z"}])).

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
%% sequential copies of Request (a complete HTTP/1.1 request) and reading
%% each response completely before the next one. Every response is checked
%% against Expect = {Status, BodyBytes, Headers}: its status, its body
%% length, and each {LowercaseName, Value} in Headers present with exactly
%% that value. The body is counted, not kept, so a 10 MB response costs the
%% client a read, not a copy.
%% {ok, {ElapsedUs, LatenciesUs}} | {error, Reason}.
http_round(Port, Clients, Requests, Request, Expect, TimeoutMs) ->
    Parent = self(),
    Start = now_us(),
    Pids = [spawn_monitor(fun() ->
                Parent ! {self(), http_client(Port, Requests, Request, Expect, TimeoutMs)}
            end) || _ <- lists:seq(1, Clients)],
    case collect(Pids, Start, TimeoutMs, []) of
        {ok, Timed} ->
            case await_exits(Pids, TimeoutMs) of
                ok -> {ok, Timed};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% One request on a fresh connection, the whole response kept:
%% {ok, {Status, [{LowercaseName, Value}], Body}} | {error, Reason}.
%% Scenarios probe with it before they time anything, to check the body
%% itself and to learn what the timed responses must look like.
http_fetch(Port, Request, TimeoutMs) ->
    case connect(Port, TimeoutMs) of
        {ok, Socket} ->
            Result = case gen_tcp:send(Socket, Request) of
                ok -> read_response(Socket, <<>>, keep, TimeoutMs);
                {error, Reason} -> {error, fmt("send: ~0p", [Reason])}
            end,
            ok = gen_tcp:close(Socket),
            Result;
        {error, Reason} ->
            {error, Reason}
    end.

%% zlib:gunzip/1 as a result: {ok, Bin} | {error, Reason}.
gunzip(Data) ->
    try zlib:gunzip(Data) of
        Plain -> {ok, Plain}
    catch
        error:Why -> {error, fmt("gunzip: ~0p", [Why])}
    end.

connect(Port, TimeoutMs) ->
    case gen_tcp:connect("127.0.0.1", Port,
                         [binary, {active, false}, {packet, raw}, {nodelay, true}],
                         TimeoutMs) of
        {ok, Socket} -> {ok, Socket};
        {error, Reason} -> {error, fmt("connect: ~0p", [Reason])}
    end.

http_client(Port, Requests, Request, Expect, TimeoutMs) ->
    case connect(Port, TimeoutMs) of
        {ok, Socket} ->
            Result = http_loop(Socket, Request, Expect, Requests, TimeoutMs, []),
            ok = gen_tcp:close(Socket),
            Result;
        {error, Reason} ->
            {error, Reason}
    end.

http_loop(_Socket, _Request, _Expect, 0, _TimeoutMs, Acc) ->
    {ok, Acc};
http_loop(Socket, Request, Expect, N, TimeoutMs, Acc) ->
    T0 = now_us(),
    case gen_tcp:send(Socket, Request) of
        ok ->
            case read_response(Socket, <<>>, count, TimeoutMs) of
                {ok, Response} ->
                    Elapsed = now_us() - T0,
                    case expected(Response, Expect) of
                        ok -> http_loop(Socket, Request, Expect, N - 1, TimeoutMs, [Elapsed | Acc]);
                        {error, Reason} -> {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, fmt("send: ~0p", [Reason])}
    end.

expected({Status, Headers, BodyBytes}, {Status, BodyBytes, Wanted}) ->
    case [{Name, Value} || {Name, Value} <- Wanted,
                           proplists:get_value(Name, Headers) =/= Value] of
        [] -> ok;
        Missing -> {error, fmt("response lacks ~0p (has ~0p)", [Missing, Headers])}
    end;
expected({Status, _Headers, BodyBytes}, {WantStatus, WantBytes, _Wanted}) ->
    {error, fmt("expected a ~b with a ~b-byte body, got a ~b with ~b bytes",
                [WantStatus, WantBytes, Status, BodyBytes])}.

%% Read one response. Mode `keep` returns the body, `count` its length.
%% The length is the content-length; a 204 or 304 without one has none.
read_response(Socket, Acc, Mode, TimeoutMs) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [Head, Body] ->
            case parse_head(Head) of
                {ok, {Status, Headers}} ->
                    case body_length(Status, Headers) of
                        {ok, Length} ->
                            case read_body(Socket, Body, byte_size(Body), Length, Mode, TimeoutMs) of
                                {ok, Read} -> {ok, {Status, Headers, Read}};
                                {error, Reason} -> {error, Reason}
                            end;
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        [_] ->
            case gen_tcp:recv(Socket, 0, TimeoutMs) of
                {ok, Data} -> read_response(Socket, <<Acc/binary, Data/binary>>, Mode, TimeoutMs);
                {error, Reason} -> {error, fmt("recv head: ~0p", [Reason])}
            end
    end.

parse_head(Head) ->
    case binary:split(Head, <<"\r\n">>, [global]) of
        [<<"HTTP/1.1 ", Code:3/binary, _/binary>> | Lines] ->
            Headers = [{string:lowercase(K), V} || L <- Lines,
                                                   [K, V] <- [binary:split(L, <<": ">>)]],
            {ok, {binary_to_integer(Code), Headers}};
        _ ->
            {error, fmt("not an HTTP/1.1 response: ~0p", [Head])}
    end.

body_length(Status, Headers) ->
    case [V || {<<"content-length">>, V} <- Headers] of
        [Value] -> {ok, binary_to_integer(Value)};
        [] when Status =:= 204; Status =:= 304 -> {ok, 0};
        Other -> {error, fmt("a ~b response with content-length ~0p", [Status, Other])}
    end.

read_body(_Socket, Body, Have, Length, Mode, _TimeoutMs) when Have =:= Length ->
    case Mode of
        keep -> {ok, Body};
        count -> {ok, Have}
    end;
read_body(Socket, Body, Have, Length, Mode, TimeoutMs) when Have < Length ->
    case gen_tcp:recv(Socket, 0, TimeoutMs) of
        {ok, Data} ->
            Kept = case Mode of
                keep -> <<Body/binary, Data/binary>>;
                count -> <<>>
            end,
            read_body(Socket, Kept, Have + byte_size(Data), Length, Mode, TimeoutMs);
        {error, Reason} ->
            {error, fmt("recv body: ~0p", [Reason])}
    end;
read_body(_Socket, _Body, Have, Length, _Mode, _TimeoutMs) ->
    {error, fmt("body longer than its content-length (~b > ~b)", [Have, Length])}.

%% --- WebSocket events ---

%% Conns joined WebSocket connections to Host:Port, each sending Events
%% events one at a time and timing each from its send to the patch that
%% acknowledges it (brazier_stress_ffi checks every answer). All
%% connections join before any sends, so the round times only events.
%% Every connection closes with the 1000 handshake afterwards. Each join
%% carries Build (`{some, Hash}`), the page build a page rendered by this
%% server sends, so the bench joins as a real client does.
%% {ok, {ElapsedUs, LatenciesUs}} | {error, Reason}.
ws_round(Host, Port, Conns, Events, Build, TimeoutMs) ->
    Parent = self(),
    Go = make_ref(),
    Pids = [spawn_monitor(fun() -> ws_client(Parent, Go, Host, Port, Events, Build, TimeoutMs) end)
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

ws_client(Parent, Go, Host, Port, Events, Build, TimeoutMs) ->
    case brazier_stress_ffi:connect_and_join(Host, Port, 0, Build, TimeoutMs) of
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

%% --- Presence ---

%% Holders processes each track KeysPerHolder keys on Topic through
%% brazier/presence.track (a tracker counts entries per process, so a big
%% room needs many processes). {ok, Holders} once every track has
%% succeeded | {error, Reason}, with every holder already stopped.
presence_fill(Presence, Topic, Holders, KeysPerHolder, TimeoutMs) ->
    Parent = self(),
    Pids = [spawn_monitor(fun() -> holder(Parent, Presence, Topic, H, KeysPerHolder) end)
            || H <- lists:seq(1, Holders)],
    case await_tracked(Pids, TimeoutMs) of
        ok ->
            {ok, Pids};
        {error, Reason} ->
            _ = presence_release(Pids, TimeoutMs),
            {error, Reason}
    end.

holder(Parent, Presence, Topic, H, Keys) ->
    Tracked = lists:foldl(fun
        (K, ok) ->
            Key = iolist_to_binary(io_lib:format("holder-~b-~b", [H, K])),
            case 'brazier@presence':track(Presence, Topic, Key, Key) of
                {ok, _Ref} -> ok;
                {error, Reason} -> {error, fmt("track ~ts: ~0p", [Key, Reason])}
            end;
        (_K, Failed) ->
            Failed
    end, ok, lists:seq(1, Keys)),
    Parent ! {self(), Tracked},
    receive stop -> ok end.

await_tracked([], _TimeoutMs) -> ok;
await_tracked([{Pid, Ref} | Rest], TimeoutMs) ->
    receive
        {Pid, ok} -> await_tracked(Rest, TimeoutMs);
        {Pid, {error, Reason}} -> {error, Reason};
        {'DOWN', Ref, process, Pid, Why} -> {error, fmt("holder died: ~0p", [Why])}
    after TimeoutMs ->
        {error, <<"a holder did not finish tracking in time">>}
    end.

%% Stop the holders and await their exit. Their entries leave the tracker
%% when the shard sees them go.
presence_release(Holders, TimeoutMs) ->
    [Pid ! stop || {Pid, _} <- Holders],
    case await_exits(Holders, TimeoutMs) of
        ok -> {ok, nil};
        {error, Reason} -> {error, Reason}
    end.

%% Ops times, the calling process tracks a fresh key on Topic and waits for
%% the diff that joins it, then untracks it and waits for the diff that
%% removes it. The caller must be subscribed to DiffTopic. Each diff must
%% name exactly that key of this process.
%% {ok, {TrackNs, UntrackNs}} | {error, Reason}.
presence_round(Presence, Topic, DiffTopic, Ops, TimeoutMs) ->
    presence_round(Presence, Topic, DiffTopic, 1, Ops, TimeoutMs, [], []).

presence_round(_Presence, _Topic, _DiffTopic, N, Ops, _TimeoutMs, Tracks, Untracks) when N > Ops ->
    {ok, {lists:reverse(Tracks), lists:reverse(Untracks)}};
presence_round(Presence, Topic, DiffTopic, N, Ops, TimeoutMs, Tracks, Untracks) ->
    Key = iolist_to_binary(io_lib:format("bench-~b", [N])),
    T0 = now_ns(),
    case 'brazier@presence':track(Presence, Topic, Key, Key) of
        {ok, _Ref} ->
            case await_diff(DiffTopic, Topic, Key, join, TimeoutMs) of
                ok ->
                    T1 = now_ns(),
                    case 'brazier@presence':untrack(Presence, Topic, Key) of
                        {ok, nil} ->
                            case await_diff(DiffTopic, Topic, Key, leave, TimeoutMs) of
                                ok ->
                                    T2 = now_ns(),
                                    presence_round(Presence, Topic, DiffTopic, N + 1, Ops, TimeoutMs,
                                                   [T1 - T0 | Tracks], [T2 - T1 | Untracks]);
                                {error, Reason} -> {error, Reason}
                            end;
                        {error, Reason} ->
                            {error, fmt("untrack ~ts: ~0p", [Key, Reason])}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, fmt("track ~ts: ~0p", [Key, Reason])}
    end.

%% What one presence.list may allocate, in words: its result is about 34
%% words an entry (the key, the meta and the list cells;
%% brazier_presence_ffi builds nothing else), so 64 leaves room to spare. A
%% sample's heap holds two lists (the warm-up and the timed one) and the
%% base. A list that allocates past it fails the bench instead of being
%% timed with a collection: the old list, which decoded every row on every
%% read, needed about 100 words an entry, and its samples of the 10000 room
%% fail here.
-define(LIST_WORDS_PER_ENTRY, 64).
-define(LIST_BASE_WORDS, 2000).

%% Time one brazier/presence.list of Topic, checked to return Entries
%% entries, in a fresh process whose heap holds everything the list
%% allocates, and prove with a trace session that no garbage collection ran
%% in it: {ok, Ns} | {error, Reason}.
%%
%% Timed in the bench process, a list pays for collecting whatever that
%% heap holds when the list's result does not fit: presence.list.10.p99 sat
%% at about 9.5 or 14.5 us from run to run, as the collection did or did not
%% land among a round's slowest 1%. That measures the bench's heap, not the
%% list. In a fresh, sized process every sample does the same work, so a
%% slower select, walk or allocation moves every sample and the median,
%% while a list that allocates more than its heap fails the run loudly.
%% (brazier_crdt_test_ffi:reductions/1 measures the same way, with
%% reductions in place of time.)
%%
%% The process lists once untimed before the timed list: the first list of
%% a new process runs on cold caches (its own heap, the table's pages, the
%% code, on whichever scheduler it landed), which put the 10-entry room's
%% median at about 8 us and its p99 at about 35 us, against 2.5 and 6 us
%% for the warm list. The warm list is what a session that lists repeatedly
%% pays, and its cost is the code's.
presence_list_sample(Presence, Topic, Entries, TimeoutMs) ->
    Words = ?LIST_BASE_WORDS + 2 * Entries * ?LIST_WORDS_PER_ENTRY,
    Parent = self(),
    Ref = make_ref(),
    {Pid, Monitor} = spawn_opt(fun() ->
        receive {Ref, go} -> ok end,
        Warm = 'brazier@presence':list(Presence, Topic),
        T0 = now_ns(),
        Listed = 'brazier@presence':list(Presence, Topic),
        T1 = now_ns(),
        Parent ! {Ref, listed, T1 - T0, listed_count(Warm), listed_count(Listed)}
    end, [monitor, {min_heap_size, Words}, {min_bin_vheap_size, Words}]),
    Session = trace:session_create(?MODULE, Parent, []),
    1 = trace:process(Session, Pid, true, [garbage_collection]),
    Pid ! {Ref, go},
    Sampled =
        receive
            {Ref, listed, Ns, WarmCount, Count} ->
                %% The process exits once it has sent its answer.
                receive {'DOWN', Monitor, process, Pid, _} -> ok end,
                case {WarmCount, Count} of
                    {{ok, Entries}, {ok, Entries}} -> {ok, Ns};
                    {{ok, Other}, _} -> {error, fmt("the warm-up list returned ~b entries, expected ~b", [Other, Entries])};
                    {{error, Reason}, _} -> {error, fmt("the warm-up list: ~0p", [Reason])};
                    {_, {ok, Other}} -> {error, fmt("list returned ~b entries, expected ~b", [Other, Entries])};
                    {_, {error, Reason}} -> {error, fmt("list: ~0p", [Reason])}
                end;
            {'DOWN', Monitor, process, Pid, Why} ->
                {error, fmt("the list's process died: ~0p", [Why])}
        after TimeoutMs ->
            true = exit(Pid, kill),
            receive {'DOWN', Monitor, process, Pid, _} -> ok end,
            {error, fmt("list did not answer within ~b ms", [TimeoutMs])}
        end,
    Delivered = erlang:trace_delivered(Pid),
    receive {trace_delivered, Pid, Delivered} -> ok end,
    true = trace:session_destroy(Session),
    case {Sampled, collections(Pid, 0)} of
        {{ok, _}, 0} ->
            Sampled;
        {{ok, _}, Collections} ->
            {error, fmt("~b garbage collection event(s) ran during a list of ~b entries in a heap "
                        "of ~b words: the list allocates more than ~b words an entry",
                        [Collections, Entries, Words, ?LIST_WORDS_PER_ENTRY])};
        {{error, _}, _} ->
            Sampled
    end.

listed_count({ok, Listed}) -> {ok, length(Listed)};
listed_count({error, Reason}) -> {error, Reason}.

%% The trace events of Pid (its session traces garbage collection only),
%% removed from the mailbox.
collections(Pid, Count) ->
    receive
        {trace, Pid, _Event, _Info} ->
            collections(Pid, Count + 1)
    after 0 ->
        Count
    end.

await_diff(DiffTopic, Topic, Key, Side, TimeoutMs) ->
    Self = self(),
    receive
        {brazier_pubsub, DiffTopic, {brazier_presence_diff, _Name, _Fingerprint, Topic, Joins, Leaves}} ->
            case {Side, Joins, Leaves} of
                {join, [{Key, Self, _Meta}], []} -> ok;
                {leave, [], [{Key, Self, _Meta}]} -> ok;
                _ -> {error, fmt("expected the ~p of ~ts, got joins ~0p, leaves ~0p",
                                 [Side, Key, Joins, Leaves])}
            end
    after TimeoutMs ->
        {error, fmt("no ~p diff for ~ts in time", [Side, Key])}
    end.

fmt(Format, Args) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).
