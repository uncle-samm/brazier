-module(beacon_http_acceptors_sup).
%% Supervisor of the acceptor pool for one Beacon HTTP listener. Modelled
%% on ranch_acceptors_sup: acceptors are children restarted (and reported
%% by the supervisor) if they crash.
%%
%% Unlike ranch_acceptors_sup this supervisor does not own the listen
%% socket. A supervisor has no terminate callback, so a socket it owned
%% would only be closed by the runtime after the supervisor exited, which
%% is asynchronous, and a listener restarted at once could then fail with
%% eaddrinuse. The socket belongs to the sibling beacon_http_listen_socket,
%% which closes it in its terminate/2. This supervisor reads the socket
%% from the connection owner (beacon_http_conns), where its owner publishes
%% it. The listener tree is rest_for_one with the socket owner before this
%% supervisor, so a new socket always comes with new acceptors.
-behaviour(supervisor).

-export([start_link/2, start_link_gleam/2]).
-export([init/1]).

start_link(ConnsName, NumAcceptors) ->
    supervisor:start_link(?MODULE, {ConnsName, NumAcceptors}).

%% Gleam supervision start shape: {ok, {started, Pid, nil}} | {error, StartError}.
start_link_gleam(ConnsName, NumAcceptors) ->
    case start_link(ConnsName, NumAcceptors) of
        {ok, Pid} -> {ok, {started, Pid, nil}};
        {error, Reason} -> {error, {init_failed, format(Reason)}};
        ignore -> {error, {init_failed, <<"acceptor supervisor returned ignore">>}}
    end.

init({ConnsName, NumAcceptors}) ->
    true = is_atom(ConnsName),
    true = is_integer(NumAcceptors) andalso NumAcceptors > 0,
    case beacon_http_conns:listen_socket(ConnsName) of
        {ok, ListenSocket} ->
            beacon_log_ffi:info(<<"beacon.http_acceptors">>, "starting ~p acceptors on port ~p",
                                [NumAcceptors, beacon_http_conns:get_port(ConnsName)]),
            Children = [
                #{id => {acceptor, Id},
                  start => {beacon_http_acceptor, start_link, [ListenSocket, ConnsName, Id]},
                  %% transient: an acceptor whose listen socket closed
                  %% exits {shutdown, listen_socket_closed} and is not
                  %% restarted on that dead socket. The socket owner sees
                  %% the same close (the socket is linked to it) and exits,
                  %% and the listener restarts it and this pool behind it.
                  %% Any other exit is a crash and is restarted.
                  restart => transient,
                  shutdown => brutal_kill,
                  type => worker}
                || Id <- lists:seq(1, NumAcceptors)
            ],
            Intensity = 1 + ceil(math:log2(NumAcceptors)),
            {ok, {#{strategy => one_for_one, intensity => Intensity, period => 5},
                  Children}};
        {error, no_listen_socket} ->
            %% The socket owner starts before this supervisor and publishes
            %% the socket in its init, so this is a broken tree: crash, so
            %% start_link reports the error.
            beacon_log_ffi:error(<<"beacon.http_acceptors">>, "no listen socket published for ~p",
                                 [ConnsName]),
            erlang:error({no_listen_socket, ConnsName})
    end.

format(Reason) when is_binary(Reason) -> Reason;
format(Reason) -> list_to_binary(io_lib:format("~p", [Reason])).
