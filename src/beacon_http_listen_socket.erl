-module(beacon_http_listen_socket).
%% Owner of one Beacon HTTP listener's listen socket.
%%
%% WHY A PROCESS OF ITS OWN. A port is closed by the runtime when its owner
%% exits, but that close is asynchronous: the owner's exit (and so its
%% supervisor's view of "stopped") can come before the OS releases the
%% address. A listener restarted at once (a rest_for_one restart of the
%% application tree, or a stop followed by a start on the same port) then
%% fails with eaddrinuse. Under load that was 366 of 20000 rebinds in a
%% plain-Erlang reproduction, and 0 of 20000 with an explicit gen_tcp:close
%% before the owner exits. A supervisor has no terminate callback, so it
%% cannot close the socket itself.
%%
%% This gen_server opens the socket in init/1, traps exits, and closes the
%% socket in terminate/2. gen_tcp:close/1 returns once the port is closed,
%% so by the time this process is reported down the address is free again.
%%
%% Reference: ranch_acceptors_sup keeps the listen socket in its process
%% dictionary and never closes it (ranch master, read 2026-11-03), so ranch
%% has the same asynchronous close. Thousand Island gives the socket to a
%% dedicated `ThousandIsland.Listener` GenServer that starts before the
%% acceptor pool under a rest_for_one supervisor; that is the structure used
%% here, with the explicit close in terminate/2 added.
%%
%% The listener tree (beacon/transport/server.gleam) is rest_for_one:
%%   conns -> listen socket (this) -> acceptors
%% Children stop in reverse order, so a stopping listener stops the
%% acceptors first, then closes the listen socket, then drains the
%% connections. Restarting this process restarts the acceptors too, so no
%% acceptor ever accepts on a closed socket.
%%
%% The bound port and the socket are published to the connection owner
%% (beacon_http_conns), which every sibling can reach by its registered
%% name. A restart rebinds the port bound first, so a port-0 listener keeps
%% its port.
-behaviour(gen_server).

-export([start_link/3, start_link_gleam/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(ConnsName, Backlog, SendTimeoutMs) ->
    gen_server:start_link(?MODULE, {ConnsName, Backlog, SendTimeoutMs}, []).

%% Gleam supervision start shape: {ok, {started, Pid, nil}} | {error, StartError}.
start_link_gleam(ConnsName, Backlog, SendTimeoutMs) ->
    case start_link(ConnsName, Backlog, SendTimeoutMs) of
        {ok, Pid} -> {ok, {started, Pid, nil}};
        {error, Reason} -> {error, {init_failed, format(Reason)}};
        ignore -> {error, {init_failed, <<"listen socket owner returned ignore">>}}
    end.

init({ConnsName, Backlog, SendTimeoutMs}) ->
    true = is_atom(ConnsName),
    true = is_integer(Backlog) andalso Backlog > 0,
    true = is_integer(SendTimeoutMs) andalso SendTimeoutMs > 0,
    %% Trap exits so a shutdown from the supervisor runs terminate/2, and so
    %% the socket's own exit (it is linked to its owner) arrives as a message.
    process_flag(trap_exit, true),
    Port = beacon_http_conns:get_port(ConnsName),
    Opts = [
        binary,
        {active, false},
        {packet, raw},
        {reuseaddr, true},
        {backlog, Backlog},
        {nodelay, true},
        {send_timeout, SendTimeoutMs},
        {send_timeout_close, true}
    ],
    case gen_tcp:listen(Port, Opts) of
        {ok, Socket} ->
            case inet:port(Socket) of
                {ok, BoundPort} ->
                    ok = beacon_http_conns:set_listen_socket(ConnsName, Socket, BoundPort),
                    beacon_log_ffi:info(<<"beacon.http_listen_socket">>, "listening on port ~p", [BoundPort]),
                    {ok, #{socket => Socket, port => BoundPort}};
                {error, Reason} ->
                    beacon_log_ffi:error(<<"beacon.http_listen_socket">>, "could not read bound port: ~p",
                                         [Reason]),
                    ok = gen_tcp:close(Socket),
                    {stop, {bound_port_unavailable, Reason}}
            end;
        {error, Reason} ->
            beacon_log_ffi:error(<<"beacon.http_listen_socket">>, "failed to listen on port ~p: ~p",
                                 [Port, Reason]),
            {stop, {listen_failed, Port, Reason}}
    end.

handle_call(Other, From, State) ->
    beacon_log_ffi:error(<<"beacon.http_listen_socket">>, "unexpected call ~p from ~p", [Other, From]),
    {reply, {error, unexpected_call}, State}.

handle_cast(Other, State) ->
    beacon_log_ffi:error(<<"beacon.http_listen_socket">>, "unexpected cast ~p", [Other]),
    {noreply, State}.

%% The socket closed under us (it is linked to this process). Stop loudly:
%% the supervisor restarts this process and the acceptors behind it.
handle_info({'EXIT', Socket, Reason}, State = #{socket := Socket, port := Port}) ->
    beacon_log_ffi:error(<<"beacon.http_listen_socket">>, "listen socket on port ~p closed: ~p",
                         [Port, Reason]),
    {stop, {listen_socket_closed, Reason}, State#{socket := closed}};
handle_info(Other, State) ->
    beacon_log_ffi:warning(<<"beacon.http_listen_socket">>, "unexpected message ~p", [Other]),
    {noreply, State}.

terminate(Reason, #{socket := closed, port := Port}) ->
    beacon_log_ffi:info(<<"beacon.http_listen_socket">>, "stopped (~p), port ~p was already closed",
                        [Reason, Port]);
terminate(Reason, #{socket := Socket, port := Port}) ->
    %% Synchronous: the port is closed when this returns, so whoever sees
    %% this process exit can bind the port again.
    ok = gen_tcp:close(Socket),
    beacon_log_ffi:info(<<"beacon.http_listen_socket">>, "closed listen socket on port ~p (~p)",
                        [Port, Reason]).

format(Reason) when is_binary(Reason) -> Reason;
format(Reason) -> list_to_binary(io_lib:format("~p", [Reason])).
