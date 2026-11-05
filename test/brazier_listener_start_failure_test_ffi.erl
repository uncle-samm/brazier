-module(brazier_listener_start_failure_test_ffi).
%% Helpers for listener_start_failure_test: what the OS says about a port,
%% the calling process's links, trap flag and mailbox, the listener
%% registry's keepers, and the start error's wording.
-export([listen_probe/1, links/0, traps_exits/0, mailbox_size/0, keepers/0,
         describe_listen_failure/2, describe_acceptors_failure/0]).

%% {ok, nil} when Port can be bound as the listener binds it (the socket is
%% closed again), else {error, Posix} as text.
listen_probe(Port) ->
    case gen_tcp:listen(Port, [binary, {active, false}, {reuseaddr, true}]) of
        {ok, Socket} ->
            ok = gen_tcp:close(Socket),
            {ok, nil};
        {error, Posix} when is_atom(Posix) ->
            {error, atom_to_binary(Posix)}
    end.

links() ->
    {links, Links} = process_info(self(), links),
    lists:sort(Links).

traps_exits() ->
    {trap_exit, Flag} = process_info(self(), trap_exit),
    Flag.

mailbox_size() ->
    {message_queue_len, Size} = process_info(self(), message_queue_len),
    Size.

%% The keeper pids brazier_http_conns has registered, one per live listener
%% name.
keepers() ->
    lists:sort([Pid || {{brazier_http_conns, keeper, _}, Pid} <- persistent_term:get()]).

describe_listen_failure(Port, Posix) ->
    brazier_http_listener_sup:describe(listen_socket,
                                       {listen_failed, Port, binary_to_atom(Posix)}).

describe_acceptors_failure() ->
    brazier_http_listener_sup:describe(acceptors, {no_listen_socket, listener}).
