-module(brazier_http_listener_sup).
%% The supervisor of one Brazier HTTP listener (brazier/transport/server):
%%
%%   rest_for_one, intensity 3 per 10 s
%%   conns -> listen_socket -> acceptors
%%
%% (see brazier_http_conns, brazier_http_listen_socket and
%% brazier_http_acceptors_sup for each child).
%%
%% WHY THE CHILDREN ARE ADDED AFTER THE START. A supervisor whose init/1
%% lists children fails its start_link when one of them fails to start: it
%% exits with {shutdown, {failed_to_start_child, Id, Reason}}, and that exit
%% reaches the caller through the link. A caller that does not trap exits
%% (an app's main process starting a listener on a taken port) was killed
%% before start_link could return, and one that does got the reason only
%% inside a nested tuple (gleam_otp reports {shutdown, _} as "shutdown").
%% Here init/1 has no children, so the start cannot fail, and start_link/10
%% then adds the three children with supervisor:start_child/2, which returns
%% a child's start error to the caller and leaves the supervisor running. On
%% an error the partly started tree is stopped (unlinked first, so its exit
%% reaches nobody) and the error names the cause: a bind refusal reads
%% "cannot listen on port 80: eacces (permission denied)".
%%
%% A child added with start_child/2 is a child like one listed in init/1:
%% it is permanent, restarted in start order under rest_for_one, and stopped
%% in reverse start order. A restart of this whole tree is a new call of
%% start_link/10 (server.supervised's start function, run by the parent), so
%% the children are never lost.
%%
%% Reference: ranch:start_listener/5 starts the listener's supervisor with
%% supervisor:start_child(ranch_sup, Spec), so a failed start is an
%% {error, _} return and kills no caller, and its maybe_started/1 and
%% start_error/2 dig the listen error (eaddrinuse, eacces) out of the
%% nested failed_to_start_child reason and return it as {error, Reason}
%% (ranch master, read 2026-11-05). Brazier's start is linked to its caller
%% (no node-wide listener supervisor), so the supervisor here plays
%% ranch_sup's part for its own children.
-behaviour(supervisor).

-export([start_link/10]).
-export([init/1]).
%% For listener_start_failure_test: a cause the test machine's OS may never
%% produce (a non-root bind to port 1 succeeds on macOS).
-export([describe/2]).

%% How long the connection owner gets on top of its drain timeout to kill
%% the remaining handlers and collect their exits before this supervisor
%% kills it.
-define(CONNS_STOP_MARGIN_MS, 5000).
%% The socket owner closes its socket in terminate/2, which returns at once.
-define(LISTEN_SOCKET_SHUTDOWN_MS, 5000).
-define(INTENSITY, 3).
-define(PERIOD_S, 10).

%% Gleam shape: {ok, Pid} | {error, Description :: binary()}. The
%% supervisor is linked to the caller on success; on an error no process of
%% the tree is left and the caller got no exit signal.
start_link(Name, Port, Handler, MaxConns, MaxPerIp, Trusted, DrainMs, Backlog, SendTimeoutMs,
           Acceptors) ->
    true = brazier_http_conns:is_name(Name),
    true = is_integer(DrainMs) andalso DrainMs >= 0,
    %% INVARIANT: init/1 returns a fixed child-less spec and no name is
    %% registered, so the start cannot fail; a failure here is a crash.
    {ok, Sup} = supervisor:start_link(?MODULE, []),
    Children = [
        #{id => conns,
          start => {brazier_http_conns, start_link,
                    [Name, Port, Handler, MaxConns, MaxPerIp, Trusted, DrainMs]},
          restart => permanent,
          shutdown => DrainMs + ?CONNS_STOP_MARGIN_MS,
          type => worker},
        #{id => listen_socket,
          start => {brazier_http_listen_socket, start_link, [Name, Backlog, SendTimeoutMs]},
          restart => permanent,
          shutdown => ?LISTEN_SOCKET_SHUTDOWN_MS,
          type => worker},
        #{id => acceptors,
          start => {brazier_http_acceptors_sup, start_link, [Name, Acceptors]},
          restart => permanent,
          shutdown => infinity,
          type => supervisor}
    ],
    case start_children(Sup, Children) of
        ok ->
            {ok, Sup};
        {error, Id, Reason} ->
            brazier_log_ffi:info(<<"brazier.http_listener_sup">>,
                                 "~p failed to start (~p): stopping the partly started listener ~p",
                                 [Id, Reason, Sup]),
            nil = brazier_server_ffi:stop_supervisor(Sup),
            {error, describe(Id, Reason)}
    end.

init([]) ->
    {ok, {#{strategy => rest_for_one, intensity => ?INTENSITY, period => ?PERIOD_S}, []}}.

start_children(_Sup, []) ->
    ok;
start_children(Sup, [Child = #{id := Id} | Rest]) ->
    %% supervisor:start_child/2 returns a child's start error as
    %% {error, {Reason, ChildRecord}}. No child here returns ignore, and the
    %% ids are distinct in a fresh supervisor, so any other return (an
    %% {ok, undefined}, already_started, already_present) is a broken
    %% invariant and crashes.
    case supervisor:start_child(Sup, Child) of
        {ok, Pid} when is_pid(Pid) -> start_children(Sup, Rest);
        {error, {Reason, _ChildRecord}} when Reason =/= already_started -> {error, Id, Reason}
    end.

%% The one-line cause of a failed start, for server.start's error. A bind
%% refusal names the POSIX code and its text, as ranch reports it.
describe(listen_socket, {listen_failed, Port, Posix}) when is_atom(Posix) ->
    list_to_binary(io_lib:format("cannot listen on port ~b: ~s (~s)",
                                 [Port, Posix, inet:format_error(Posix)]));
describe(Id, Reason) ->
    list_to_binary(io_lib:format("the listener's ~s failed to start: ~0p", [Id, Reason])).
