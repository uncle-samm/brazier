-module(brazier_http_conns).
%% Connection owner for one Brazier HTTP listener.
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
%%   {{ws_ip, IpText}, N}              live WebSockets per client IP
%%   {{ws_pid, Pid}, IpText}           WebSocket slot owned by a handler pid
%%   {port, Port}                      bound listen port (survives acceptor restarts)
%%   {listen_socket, Socket}           the listen socket, published by its owner
%%                                     brazier_http_listen_socket for the acceptors
%% Slot removal uses ets:take/2 so a concurrent early release and 'EXIT'
%% can never double-decrement.
%%
%% WEBSOCKET SLOTS. A handler that upgrades to a WebSocket also takes a
%% per-client-IP WebSocket slot (ws_acquire_self/2). The client IP is the
%% one the transport resolved, which behind a trusted proxy is the forwarded
%% client, so it is counted apart from the connection's peer IP above. The
%% handler releases its slot when the socket closes (ws_release_self/0), and
%% this process releases it on the handler's 'EXIT' in any case, so a crashed
%% or killed handler never leaks one. The slots live and die with this
%% listener: no node-wide process holds them, and two listeners never share
%% a count.
%%
%% The children map is Pid => StartedAt (native monotonic time). When a
%% handler exits, this process emits [brazier, http, connection, closed]
%% with the connection's lifetime as `duration` and a bounded `reason`:
%% normal, shutdown, handoff_failed, crash or killed (see close_reason/1).
%%
%% DRAIN. When this process terminates in an orderly way (its listener is
%% stopped, or restarted because an earlier child of the application tree
%% restarted), the acceptors have already stopped and the listen socket
%% owner has closed the socket: no connection is added. terminate/2 then sends every handler
%% {brazier_http_drain, self()} instead of an exit signal, and each handler
%% finishes what it is doing (drain_requested/0, mark_draining/0):
%%   * a WebSocket sends close 1001 (going away) and exits;
%%   * an HTTP request in flight completes, its response says
%%     `connection: close`, and the connection closes;
%%   * an idle keep-alive connection closes at once;
%%   * a handler still waiting for its socket exits.
%% A drained handler exits with `shutdown`. terminate/2 waits for the 'EXIT'
%% of every handler (event-driven, no polling) until the drain deadline,
%% then kills the rest and logs how many it killed. The deadline is the
%% listener's drain_timeout_ms (DrainMs); this process's own supervisor
%% shutdown timeout leaves room for it.
%%
%% Reference (knowledge, not code read here): Plug.Cowboy.Drainer waits for
%% the connection count to reach zero with a deadline; Cowboy's connection
%% processes finish their current request when their parent exits.
-behaviour(gen_server).

-export([
    new_name/0, start_link/7, start_link_gleam/7,
    start_connection/2, release_self/0, release_pid/2,
    drain_requested/0, mark_draining/0, is_drain_message/1, owner/0, owner_if_any/0,
    count_self/0, count/1, count_for_ip/2, count_for_ip_text/2, children/1,
    ws_acquire_self/2, ws_release_self/0, ws_count_for_ip/2,
    get_port/1, set_listen_socket/3, listen_socket/1, forget_port/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([connection_init/3]).

-define(PDICT_KEY, '$brazier_http_conn').
-define(SHOOT_TIMEOUT_MS, 5000).
-define(DRAINING_KEY, '$brazier_http_draining').

%% Each listener gets one registered name so siblings in the supervision
%% tree (the acceptors) can find the current conns process across restarts.
%% One atom is created per listener start; listeners are long-lived.
new_name() ->
    list_to_atom("brazier_http_conns_" ++ integer_to_list(erlang:unique_integer([positive]))).

start_link(Name, Port, Handler, MaxConns, MaxPerIp, TrustedCidrs, DrainMs) ->
    gen_server:start_link({local, Name}, ?MODULE,
                          {Port, Handler, MaxConns, MaxPerIp, TrustedCidrs, DrainMs}, []).

%% Gleam supervision start shape: {ok, {started, Pid, Name}} | {error, StartError}.
start_link_gleam(Name, Port, Handler, MaxConns, MaxPerIp, TrustedCidrs, DrainMs) ->
    case start_link(Name, Port, Handler, MaxConns, MaxPerIp, TrustedCidrs, DrainMs) of
        {ok, Pid} -> {ok, {started, Pid, Name}};
        {error, Reason} -> {error, {init_failed, format(Reason)}};
        ignore -> {error, {init_failed, <<"connection owner returned ignore">>}}
    end.

%% Called by an acceptor. Returns {ok, HandlerPid} | {error, Limit}.
start_connection(Conns, Ip) ->
    gen_server:call(Conns, {start_connection, Ip}).

get_port(Conns) -> gen_server:call(Conns, get_port).
%% Called by brazier_http_listen_socket once it has bound: records the bound
%% port (reused by every later bind of this listener) and the socket.
set_listen_socket(Conns, Socket, Port) -> gen_server:call(Conns, {set_listen_socket, Socket, Port}).
%% The current listen socket, for the acceptors. {ok, Socket} | {error, no_listen_socket}.
listen_socket(Conns) -> gen_server:call(Conns, listen_socket).
count(Conns) -> gen_server:call(Conns, count).
count_for_ip(Conns, Ip) -> gen_server:call(Conns, {count_for_ip, Ip}).
children(Conns) -> gen_server:call(Conns, children).

%% Gleam-shaped: {ok, Count} | {error, nil} for an unparseable address.
count_for_ip_text(Conns, IpText) when is_binary(IpText) ->
    case brazier_ip_ffi:parse_ip_tuple_result(IpText) of
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
            brazier_log_ffi:error(<<"brazier.http_conns">>, "release called outside a connection process ~p",
                                 [self()]),
            erlang:error(not_a_connection_process)
    end.

count_self() ->
    case get(?PDICT_KEY) of
        {_Conns, Tid} -> global_count(Tid);
        undefined ->
            brazier_log_ffi:error(<<"brazier.http_conns">>, "count called outside a connection process ~p",
                                 [self()]),
            erlang:error(not_a_connection_process)
    end.

%% Whether this handler's connection owner asked it to drain. Takes a
%% waiting drain message from the mailbox without blocking and remembers it,
%% so the answer stays true once the message is consumed. Must run inside a
%% handler process.
drain_requested() ->
    case get(?DRAINING_KEY) of
        true -> true;
        undefined ->
            {Conns, _Tid} = connection_context(),
            receive
                {brazier_http_drain, Conns} -> mark_draining(), true
            after 0 -> false
            end
    end.

%% Remember that the drain message was consumed (by a receive loop that
%% classifies its own messages, such as a WebSocket's). The handler then
%% exits with `shutdown`.
mark_draining() ->
    put(?DRAINING_KEY, true),
    nil.

%% Whether Msg is the drain message of this handler's connection owner.
is_drain_message({brazier_http_drain, From}) ->
    case get(?PDICT_KEY) of
        {From, _Tid} -> true;
        _ -> false
    end;
is_drain_message(_) ->
    false.

%% The connection owner of the calling handler: the sender of its drain
%% message.
owner() ->
    {Conns, _Tid} = connection_context(),
    Conns.

%% The connection owner when the caller is a connection handler, `none`
%% otherwise (a test reading from a socket of its own).
owner_if_any() ->
    case get(?PDICT_KEY) of
        {Conns, _Tid} -> Conns;
        undefined -> none
    end.

connection_context() ->
    case get(?PDICT_KEY) of
        {_Conns, _Tid} = Context -> Context;
        undefined ->
            brazier_log_ffi:error(<<"brazier.http_conns">>, "drain checked outside a connection process ~p",
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
    decrement_counter(Tid, {ip, Ip}).

%% A concurrent increment between the decrement and the delete is safe: the
%% delete only matches a row still at zero, and update_counter/4 recreates a
%% deleted row.
decrement_counter(Tid, Key) ->
    case ets:update_counter(Tid, Key, -1) of
        N when N =< 0 ->
            _ = ets:select_delete(Tid, [{{Key, '$1'}, [{'=<', '$1', 0}], [true]}]),
            ok;
        _ ->
            ok
    end.

%% Take a WebSocket slot for client IP IpText for the calling handler.
%% {ok, Count} when taken, {error, Held} when IpText already holds Max (the
%% caller then holds nothing). A handler holds at most one slot: a second
%% acquire is a bug and crashes.
ws_acquire_self(IpText, Max) when is_binary(IpText), is_integer(Max), Max > 0 ->
    {_Conns, Tid} = connection_context(),
    case ets:insert_new(Tid, {{ws_pid, self()}, IpText}) of
        true -> ok;
        false ->
            brazier_log_ffi:error(<<"brazier.http_conns">>,
                                 "connection ~p already holds a WebSocket slot", [self()]),
            erlang:error(ws_slot_already_held)
    end,
    Key = {ws_ip, IpText},
    Count = ets:update_counter(Tid, Key, 1, {Key, 0}),
    case Count > Max of
        true ->
            true = ets:delete(Tid, {ws_pid, self()}),
            decrement_counter(Tid, Key),
            {error, Count - 1};
        false ->
            {ok, Count}
    end.

%% Release the calling handler's WebSocket slot. Idempotent: {ok, IpText}
%% when this call released it, {error, nil} when none was held.
ws_release_self() ->
    {_Conns, Tid} = connection_context(),
    case release_ws_pid(Tid, self()) of
        {ok, IpText} -> {ok, IpText};
        none -> {error, nil}
    end.

release_ws_pid(Tid, Pid) ->
    case ets:take(Tid, {ws_pid, Pid}) of
        [{{ws_pid, Pid}, IpText}] ->
            decrement_counter(Tid, {ws_ip, IpText}),
            {ok, IpText};
        [] ->
            none
    end.

%% Live WebSockets of one client IP on the listener whose owner is Conns.
ws_count_for_ip(Conns, IpText) when is_binary(IpText) ->
    gen_server:call(Conns, {ws_count_for_ip, IpText}).

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

init({Port, Handler, MaxConns, MaxPerIp, TrustedCidrs, DrainMs}) ->
    process_flag(trap_exit, true),
    true = is_function(Handler, 1),
    true = is_integer(MaxConns) andalso MaxConns > 0,
    true = is_integer(MaxPerIp) andalso MaxPerIp > 0,
    true = is_integer(DrainMs) andalso DrainMs >= 0,
    Tid = ets:new(brazier_http_conns, [set, public, {write_concurrency, true},
                                      {read_concurrency, true}]),
    true = is_integer(Port) andalso Port >= 0 andalso Port =< 65535,
    %% After a restart of this process, reuse the port that was actually
    %% bound the first time (the configured port may be 0).
    BoundPort = persistent_term:get({?MODULE, bound_port, self_name()}, Port),
    true = ets:insert(Tid, [{global, 0}, {port, BoundPort}]),
    brazier_log_ffi:info(<<"brazier.http_conns">>,
                        "started port=~p max_connections=~p max_connections_per_ip=~p drain_timeout_ms=~p",
                        [BoundPort, MaxConns, MaxPerIp, DrainMs]),
    {ok, #{tid => Tid, handler => Handler, max => MaxConns, max_per_ip => MaxPerIp,
           trusted => TrustedCidrs, drain_ms => DrainMs, children => #{}}}.

handle_call({start_connection, Ip}, _From, State) ->
    #{tid := Tid, max := Max, max_per_ip := MaxPerIp, trusted := Trusted,
      handler := Handler, children := Children} = State,
    Global = ets:update_counter(Tid, global, 1),
    case Global > Max of
        true ->
            _ = ets:update_counter(Tid, global, -1),
            {reply, {error, max_connections}, State};
        false ->
            CountPerIp = not brazier_ip_ffi:cidrs_match(Ip, Trusted),
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
handle_call({set_listen_socket, Socket, Port}, _From, State = #{tid := Tid})
        when is_integer(Port), Port > 0 ->
    true = ets:insert(Tid, [{port, Port}, {listen_socket, Socket}]),
    Key = {?MODULE, bound_port, self_name()},
    case persistent_term:get(Key, undefined) of
        Port -> ok;
        _ -> persistent_term:put(Key, Port)
    end,
    {reply, ok, State};
handle_call(listen_socket, _From, State = #{tid := Tid}) ->
    Reply = case ets:lookup(Tid, listen_socket) of
        [{listen_socket, Socket}] -> {ok, Socket};
        [] -> {error, no_listen_socket}
    end,
    {reply, Reply, State};
handle_call(count, _From, State = #{tid := Tid}) ->
    {reply, global_count(Tid), State};
handle_call({count_for_ip, Ip}, _From, State = #{tid := Tid}) ->
    N = case ets:lookup(Tid, {ip, brazier_ip_ffi:normalize(Ip)}) of
        [{_, C}] -> C;
        [] -> 0
    end,
    {reply, N, State};
handle_call({ws_count_for_ip, IpText}, _From, State = #{tid := Tid}) ->
    N = case ets:lookup(Tid, {ws_ip, IpText}) of
        [{_, C}] -> C;
        [] -> 0
    end,
    {reply, N, State};
handle_call(children, _From, State = #{children := Children}) ->
    {reply, maps:keys(Children), State};
handle_call(Other, From, State) ->
    brazier_log_ffi:error(<<"brazier.http_conns">>, "unexpected call ~p from ~p", [Other, From]),
    {reply, {error, unexpected_call}, State}.

handle_cast(Other, State) ->
    brazier_log_ffi:error(<<"brazier.http_conns">>, "unexpected cast ~p", [Other]),
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State = #{tid := Tid, children := Children}) ->
    case maps:take(Pid, Children) of
        {StartedAt, Rest} ->
            %% false / none: the handler already released its slot early.
            _ = release_pid(Tid, Pid),
            _ = release_ws_pid(Tid, Pid),
            log_exit(Pid, Reason),
            emit_closed(StartedAt, close_reason(Reason)),
            {noreply, State#{children := Rest}};
        error ->
            brazier_log_ffi:warning(<<"brazier.http_conns">>, "EXIT from unknown process ~p: ~p", [Pid, Reason]),
            {noreply, State}
    end;
handle_info(Other, State) ->
    brazier_log_ffi:warning(<<"brazier.http_conns">>, "unexpected message ~p", [Other]),
    {noreply, State}.

terminate(Reason, #{children := Children, tid := Tid, drain_ms := DrainMs}) ->
    Pids = maps:keys(Children),
    brazier_log_ffi:info(<<"brazier.http_conns">>,
                        "terminating (~p), draining ~p connections for up to ~pms",
                        [Reason, length(Pids), DrainMs]),
    Started = erlang:monotonic_time(millisecond),
    [Pid ! {brazier_http_drain, self()} || Pid <- Pids],
    Remaining = await_exits(Children, Tid, Started + DrainMs),
    case maps:size(Remaining) of
        0 ->
            brazier_log_ffi:info(<<"brazier.http_conns">>, "drained ~p connections in ~pms",
                                [length(Pids), erlang:monotonic_time(millisecond) - Started]);
        N ->
            brazier_log_ffi:error(<<"brazier.http_conns">>,
                                 "~p of ~p connections did not finish within the ~pms drain timeout, killing",
                                 [N, length(Pids), DrainMs]),
            kill_all(Remaining)
    end.

%% Kill the handlers left after the deadline and wait for their 'EXIT' (a
%% kill cannot be ignored), so no handler outlives this process.
kill_all(Remaining) ->
    maps:foreach(fun(Pid, _StartedAt) -> exit(Pid, kill) end, Remaining),
    maps:foreach(fun(Pid, StartedAt) ->
        receive
            %% A handler that finished on its own after the deadline
            %% reports its own reason; a killed one reports `killed`.
            {'EXIT', Pid, Reason} -> emit_closed(StartedAt, close_reason(Reason))
        end
    end, Remaining).

await_exits(Remaining, _Tid, _Deadline) when map_size(Remaining) =:= 0 ->
    Remaining;
await_exits(Remaining, Tid, Deadline) ->
    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {'EXIT', Pid, Reason} when is_map_key(Pid, Remaining) ->
            %% false / none: the handler already released its slot early.
            _ = release_pid(Tid, Pid),
            _ = release_ws_pid(Tid, Pid),
            {StartedAt, Rest} = maps:take(Pid, Remaining),
            emit_closed(StartedAt, close_reason(Reason)),
            await_exits(Rest, Tid, Deadline)
    after Timeout ->
        Remaining
    end.

%% [brazier, http, connection, closed]. Runs in this process: telemetry
%% catches a crashing handler, so it can never take the owner down.
emit_closed(StartedAt, Reason) ->
    brazier_telemetry_ffi:http_connection(closed, erlang:monotonic_time() - StartedAt, Reason).

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
    brazier_log_ffi:error(<<"brazier.http_conns">>, "connection ~p exited abnormally: ~p", [Pid, Reason]).

%% --- connection process ---

connection_init(Conns, Tid, Handler) ->
    put(?PDICT_KEY, {Conns, Tid}),
    receive
        {brazier_http_shoot, Socket} ->
            _ = Handler(Socket),
            case get(?DRAINING_KEY) of
                true -> exit(shutdown);
                undefined -> ok
            end;
        {brazier_http_drain, Conns} ->
            brazier_log_ffi:info(<<"brazier.http_conns">>, "connection ~p drained before its socket arrived",
                                [self()]),
            exit(shutdown);
        {brazier_http_abort, Reason} ->
            brazier_log_ffi:warning(<<"brazier.http_conns">>, "connection ~p aborted before start: ~p",
                                   [self(), Reason]),
            exit({shutdown, handoff_aborted})
    after ?SHOOT_TIMEOUT_MS ->
        brazier_log_ffi:error(<<"brazier.http_conns">>, "connection ~p never received its socket", [self()]),
        exit(socket_handoff_timeout)
    end.

format(Reason) when is_binary(Reason) -> Reason;
format(Reason) -> list_to_binary(io_lib:format("~p", [Reason])).
