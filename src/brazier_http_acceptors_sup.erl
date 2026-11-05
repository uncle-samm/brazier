-module(brazier_http_acceptors_sup).
%% Supervisor of the acceptor pool for one Brazier HTTP listener. Modelled
%% on ranch_acceptors_sup: acceptors are children restarted (and reported
%% by the supervisor) if they crash.
%%
%% Unlike ranch_acceptors_sup this supervisor does not own the listen
%% socket. A supervisor has no terminate callback, so a socket it owned
%% would only be closed by the runtime after the supervisor exited, which
%% is asynchronous, and a listener restarted at once could then fail with
%% eaddrinuse. The socket belongs to the sibling brazier_http_listen_socket,
%% which closes it in its terminate/2. This supervisor reads the socket
%% from the connection owner (brazier_http_conns), where its owner publishes
%% it. The listener tree (brazier_http_listener_sup) is rest_for_one with
%% the socket owner before this
%% supervisor, so a new socket always comes with new acceptors.
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).

start_link(ConnsName, NumAcceptors) ->
    supervisor:start_link(?MODULE, {ConnsName, NumAcceptors}).

init({ConnsName, NumAcceptors}) ->
    true = brazier_http_conns:is_name(ConnsName),
    true = is_integer(NumAcceptors) andalso NumAcceptors > 0,
    case brazier_http_conns:listen_socket(ConnsName) of
        {ok, ListenSocket} ->
            brazier_log_ffi:info(<<"brazier.http_acceptors">>, "starting ~p acceptors on port ~p",
                                [NumAcceptors, brazier_http_conns:get_port(ConnsName)]),
            Children = [
                #{id => {acceptor, Id},
                  start => {brazier_http_acceptor, start_link, [ListenSocket, ConnsName, Id]},
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
            brazier_log_ffi:error(<<"brazier.http_acceptors">>, "no listen socket published for ~p",
                                 [ConnsName]),
            erlang:error({no_listen_socket, ConnsName})
    end.
