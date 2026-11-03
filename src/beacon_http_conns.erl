-module(beacon_http_conns).
%% Connection owner for one Beacon HTTP listener.
%%
%% Modelled on ranch_conns_sup: this process traps exits and is the linked
%% parent of every connection handler process. It enforces the global and
%% per-IP connection caps at accept time and releases a slot when the
%% handler exits for ANY reason (normal return, crash, kill). Releasing is
%% idempotent: a handler may release its own slot early (for example a
%% WebSocket cleanup) and the later 'EXIT' is then a no-op.
%%
%% Slot bookkeeping lives in a public ETS table owned by this process:
%%   {global, N}                       live connections
%%   {{ip, Ip}, N}                     live connections per peer IP
%%   {{pid, Pid}, Ip, CountedPerIp}    slot owned by a handler pid
%%   {port, Port}                      bound listen port (survives acceptor restarts)
%% Slot removal uses ets:take/2 so a concurrent early release and 'EXIT'
%% can never double-decrement.
%%
%% The children map is Pid => StartedAt (native monotonic time). When a
%% handler exits, this process emits [beacon, http, connection, closed]
%% with the connection's lifetime as `duration` and a bounded `reason`:
%% normal, shutdown, handoff_failed, crash or killed (see close_reason/1).
-behaviour(gen_server).

-export([
    new_name/0, start_link/6, start_link_gleam/6,
    start_connection/2, release_self/0, release_pid/2,
    count_self/0, count/1, count_for_ip/2, count_for_ip_text/2, children/1,
    get_port/1, set_port/2, forget_port/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([connection_init/3]).

-define(PDICT_KEY, '$beacon_http_conn').
-define(SHOOT_TIMEOUT_MS, 5000).
-define(SHUTDOWN_GRACE_MS, 5000).

%% Each listener gets one registered name so siblings in the supervision
%% tree (the acceptors) can find the current conns process across restarts.
%% One atom is created per listener start; listeners are long-lived.
new_name() ->
    list_to_atom("beacon_http_conns_" ++ integer_to_list(erlang:unique_integer([positive]))).

start_link(Name, Port, Handler, MaxConns, MaxPerIp, TrustedCidrs) ->
    gen_server:start_link({local, Name}, ?MODULE,
                          {Port, Handler, MaxConns, MaxPerIp, TrustedCidrs}, []).

%% Gleam supervision start shape: {ok, {started, Pid, Name}} | {error, StartError}.
start_link_gleam(Name, Port, Handler, MaxConns, MaxPerIp, TrustedCidrs) ->
    case start_link(Name, Port, Handler, MaxConns, MaxPerIp, TrustedCidrs) of
        {ok, Pid} -> {ok, {started, Pid, Name}};
        {error, Reason} -> {error, {init_failed, format(Reason)}};
        ignore -> {error, {init_failed, <<"connection owner returned ignore">>}}
    end.

%% Called by an acceptor. Returns {ok, HandlerPid} | {error, Limit}.
start_connection(Conns, Ip) ->
    gen_server:call(Conns, {start_connection, Ip}).

get_port(Conns) -> gen_server:call(Conns, get_port).
set_port(Conns, Port) -> gen_server:call(Conns, {set_port, Port}).
count(Conns) -> gen_server:call(Conns, count).
count_for_ip(Conns, Ip) -> gen_server:call(Conns, {count_for_ip, Ip}).
children(Conns) -> gen_server:call(Conns, children).

%% Gleam-shaped: {ok, Count} | {error, nil} for an unparseable address.
count_for_ip_text(Conns, IpText) when is_binary(IpText) ->
    case beacon_ip_ffi:parse_ip_tuple_result(IpText) of
        {ok, Ip} -> {ok, count_for_ip(Conns, Ip)};
        {error, nil} -> {error, nil}
    end.

%% Release the calling handler's slot. Must run inside a handler process.
release_self() ->
    case get(?PDICT_KEY) of
        {_Conns, Tid} ->
            release_pid(Tid, self()),
            global_count(Tid);
        undefined ->
            beacon_log_ffi:error(<<"beacon.http_conns">>, "release called outside a connection process ~p",
                                 [self()]),
            erlang:error(not_a_connection_process)
    end.

count_self() ->
    case get(?PDICT_KEY) of
        {_Conns, Tid} -> global_count(Tid);
        undefined ->
            beacon_log_ffi:error(<<"beacon.http_conns">>, "count called outside a connection process ~p",
                                 [self()]),
            erlang:error(not_a_connection_process)
    end.

%% Idempotent slot release. Returns true when this call released the slot.
release_pid(Tid, Pid) ->
    case ets:take(Tid, {pid, Pid}) of
        [{{pid, Pid}, Ip, CountedPerIp}] ->
            _ = ets:update_counter(Tid, global, -1),
            case CountedPerIp of
                true -> decrement_ip(Tid, Ip);
                false -> ok
            end,
            true;
        [] ->
            false
    end.

%% Decrement a per-IP counter and drop the row once it reaches zero so the
%% table stays bounded by the number of IPs with live connections.
decrement_ip(Tid, Ip) ->
    case ets:update_counter(Tid, {ip, Ip}, -1) of
        N when N =< 0 ->
            _ = ets:select_delete(Tid, [{{{ip, Ip}, '$1'}, [{'=<', '$1', 0}], [true]}]),
            ok;
        _ ->
            ok
    end.

global_count(Tid) ->
    ets:lookup_element(Tid, global, 2).

self_name() ->
    {registered_name, Name} = process_info(self(), registered_name),
    Name.

%% Drop the remembered bound port of a listener that has been stopped for
%% good. Returns true when an entry was removed.
forget_port(Name) when is_atom(Name) ->
    persistent_term:erase({?MODULE, bound_port, Name}).

%% --- gen_server ---

init({Port, Handler, MaxConns, MaxPerIp, TrustedCidrs}) ->
    process_flag(trap_exit, true),
    true = is_function(Handler, 1),
    true = is_integer(MaxConns) andalso MaxConns > 0,
    true = is_integer(MaxPerIp) andalso MaxPerIp > 0,
    Tid = ets:new(beacon_http_conns, [set, public, {write_concurrency, true},
                                      {read_concurrency, true}]),
    true = is_integer(Port) andalso Port >= 0 andalso Port =< 65535,
    %% After a restart of this process, reuse the port that was actually
    %% bound the first time (the configured port may be 0).
    BoundPort = persistent_term:get({?MODULE, bound_port, self_name()}, Port),
    true = ets:insert(Tid, [{global, 0}, {port, BoundPort}]),
    beacon_log_ffi:info(<<"beacon.http_conns">>, "started port=~p max_connections=~p max_connections_per_ip=~p",
                        [BoundPort, MaxConns, MaxPerIp]),
    {ok, #{tid => Tid, handler => Handler, max => MaxConns, max_per_ip => MaxPerIp,
           trusted => TrustedCidrs, children => #{}}}.

handle_call({start_connection, Ip}, _From, State) ->
    #{tid := Tid, max := Max, max_per_ip := MaxPerIp, trusted := Trusted,
      handler := Handler, children := Children} = State,
    Global = ets:update_counter(Tid, global, 1),
    case Global > Max of
        true ->
            _ = ets:update_counter(Tid, global, -1),
            {reply, {error, max_connections}, State};
        false ->
            CountPerIp = not beacon_ip_ffi:cidrs_match(Ip, Trusted),
            PerIpOk = case CountPerIp of
                false -> true;
                true ->
                    PerIp = ets:update_counter(Tid, {ip, Ip}, 1, {{ip, Ip}, 0}),
                    case PerIp > MaxPerIp of
                        true ->
                            decrement_ip(Tid, Ip),
                            false;
                        false -> true
                    end
            end,
            case PerIpOk of
                false ->
                    _ = ets:update_counter(Tid, global, -1),
                    {reply, {error, max_connections_per_ip}, State};
                true ->
                    Pid = spawn_link(?MODULE, connection_init, [self(), Tid, Handler]),
                    true = ets:insert(Tid, {{pid, Pid}, Ip, CountPerIp}),
                    StartedAt = erlang:monotonic_time(),
                    {reply, {ok, Pid}, State#{children := Children#{Pid => StartedAt}}}
            end
    end;
handle_call(get_port, _From, State = #{tid := Tid}) ->
    {reply, ets:lookup_element(Tid, port, 2), State};
handle_call({set_port, Port}, _From, State = #{tid := Tid}) when is_integer(Port), Port > 0 ->
    true = ets:insert(Tid, {port, Port}),
    Key = {?MODULE, bound_port, self_name()},
    case persistent_term:get(Key, undefined) of
        Port -> ok;
        _ -> persistent_term:put(Key, Port)
    end,
    {reply, ok, State};
handle_call(count, _From, State = #{tid := Tid}) ->
    {reply, global_count(Tid), State};
handle_call({count_for_ip, Ip}, _From, State = #{tid := Tid}) ->
    N = case ets:lookup(Tid, {ip, beacon_ip_ffi:normalize(Ip)}) of
        [{_, C}] -> C;
        [] -> 0
    end,
    {reply, N, State};
handle_call(children, _From, State = #{children := Children}) ->
    {reply, maps:keys(Children), State};
handle_call(Other, From, State) ->
    beacon_log_ffi:error(<<"beacon.http_conns">>, "unexpected call ~p from ~p", [Other, From]),
    {reply, {error, unexpected_call}, State}.

handle_cast(Other, State) ->
    beacon_log_ffi:error(<<"beacon.http_conns">>, "unexpected cast ~p", [Other]),
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State = #{tid := Tid, children := Children}) ->
    case maps:take(Pid, Children) of
        {StartedAt, Rest} ->
            %% false: the handler already released its slot early.
            _ = release_pid(Tid, Pid),
            log_exit(Pid, Reason),
            emit_closed(StartedAt, close_reason(Reason)),
            {noreply, State#{children := Rest}};
        error ->
            beacon_log_ffi:warning(<<"beacon.http_conns">>, "EXIT from unknown process ~p: ~p", [Pid, Reason]),
            {noreply, State}
    end;
handle_info(Other, State) ->
    beacon_log_ffi:warning(<<"beacon.http_conns">>, "unexpected message ~p", [Other]),
    {noreply, State}.

terminate(Reason, #{children := Children, tid := Tid}) ->
    Pids = maps:keys(Children),
    beacon_log_ffi:info(<<"beacon.http_conns">>, "terminating (~p), shutting down ~p connections",
                        [Reason, length(Pids)]),
    [exit(Pid, shutdown) || Pid <- Pids],
    Remaining = await_exits(Children, Tid,
                            erlang:monotonic_time(millisecond) + ?SHUTDOWN_GRACE_MS),
    case maps:size(Remaining) of
        0 -> ok;
        N ->
            beacon_log_ffi:error(<<"beacon.http_conns">>, "~p connections ignored shutdown, killing", [N]),
            maps:foreach(fun(Pid, StartedAt) ->
                exit(Pid, kill),
                emit_closed(StartedAt, <<"killed">>)
            end, Remaining)
    end.

await_exits(Remaining, _Tid, _Deadline) when map_size(Remaining) =:= 0 ->
    Remaining;
await_exits(Remaining, Tid, Deadline) ->
    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {'EXIT', Pid, Reason} when is_map_key(Pid, Remaining) ->
            %% false: the handler already released its slot early.
            _ = release_pid(Tid, Pid),
            {StartedAt, Rest} = maps:take(Pid, Remaining),
            emit_closed(StartedAt, close_reason(Reason)),
            await_exits(Rest, Tid, Deadline)
    after Timeout ->
        Remaining
    end.

%% [beacon, http, connection, closed]. Runs in this process: telemetry
%% catches a crashing handler, so it can never take the owner down.
emit_closed(StartedAt, Reason) ->
    beacon_telemetry_ffi:http_connection(closed, erlang:monotonic_time() - StartedAt, Reason).

%% A bounded label for a handler's exit reason. Crash reasons are logged by
%% log_exit/2 and never become metadata (they may hold request data).
close_reason(normal) -> <<"normal">>;
close_reason(shutdown) -> <<"shutdown">>;
close_reason({shutdown, handoff_aborted}) -> <<"handoff_failed">>;
close_reason({shutdown, _}) -> <<"shutdown">>;
close_reason(killed) -> <<"killed">>;
close_reason(_) -> <<"crash">>.

log_exit(_Pid, normal) -> ok;
log_exit(_Pid, shutdown) -> ok;
log_exit(_Pid, {shutdown, _}) -> ok;
log_exit(Pid, Reason) ->
    beacon_log_ffi:error(<<"beacon.http_conns">>, "connection ~p exited abnormally: ~p", [Pid, Reason]).

%% --- connection process ---

connection_init(Conns, Tid, Handler) ->
    put(?PDICT_KEY, {Conns, Tid}),
    receive
        {beacon_http_shoot, Socket} ->
            _ = Handler(Socket),
            ok;
        {beacon_http_abort, Reason} ->
            beacon_log_ffi:warning(<<"beacon.http_conns">>, "connection ~p aborted before start: ~p",
                                   [self(), Reason]),
            exit({shutdown, handoff_aborted})
    after ?SHOOT_TIMEOUT_MS ->
        beacon_log_ffi:error(<<"beacon.http_conns">>, "connection ~p never received its socket", [self()]),
        exit(socket_handoff_timeout)
    end.

format(Reason) when is_binary(Reason) -> Reason;
format(Reason) -> list_to_binary(io_lib:format("~p", [Reason])).
