-module(brazier_listener_rebind_test_ffi).
%% Helpers for listener_rebind_test: find the listen socket owner and the
%% connection owner of a listener, close a listen socket from outside, and
%% make one HTTP exchange.
-export([listen_socket_owner/1, connection_owner/1, children_running/1,
         close_listen_socket/1, answer_ok/1, http_status/1, kill/1]).

%% The listener supervisor's worker started from Module:init/1.
worker_from(ListenerSup, Module) ->
    Workers = [Pid || {_, Pid, worker, _} <- supervisor:which_children(ListenerSup),
                      is_pid(Pid), initial_call(Pid) =:= {Module, init, 1}],
    case Workers of
        [Pid] -> Pid;
        Other -> erlang:error({expected_one_worker, Module, Other})
    end.

initial_call(Pid) ->
    case erlang:process_info(Pid, dictionary) of
        {dictionary, Dict} -> proplists:get_value('$initial_call', Dict);
        undefined -> undefined
    end.

listen_socket_owner(ListenerSup) -> worker_from(ListenerSup, brazier_http_listen_socket).
connection_owner(ListenerSup) -> worker_from(ListenerSup, brazier_http_conns).

%% Whether every child of the listener supervisor is running (a child whose
%% restart failed shows as `restarting` or `undefined`).
children_running(ListenerSup) ->
    lists:all(fun({_, Child, _, _}) -> is_pid(Child) end,
              supervisor:which_children(ListenerSup)).

%% Close the owner's listen socket from this process, as a failing driver
%% would: the owner gets the socket's 'EXIT'.
close_listen_socket(Owner) ->
    #{socket := Socket} = sys:get_state(Owner),
    true = erlang:port_close(Socket),
    nil.

%% Listener handler: read the (one-packet) request, answer 200, close.
%% Reading first means the close never resets a connection with unread data.
answer_ok(Socket) ->
    {ok, _Request} = gen_tcp:recv(Socket, 0, 5000),
    Response = <<"HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok">>,
    ok = gen_tcp:send(Socket, Response),
    ok = gen_tcp:close(Socket),
    nil.

%% GET / to 127.0.0.1:Port. {ok, Status} | {error, Reason}.
http_status(Port) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000) of
        {ok, Sock} ->
            Result = case gen_tcp:send(Sock, <<"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n">>) of
                ok -> read_status(Sock, <<>>);
                {error, Reason} -> {error, format(Reason)}
            end,
            ok = gen_tcp:close(Sock),
            Result;
        {error, Reason} ->
            {error, format(Reason)}
    end.

read_status(Sock, Acc) ->
    case binary:split(Acc, <<"\r\n">>) of
        [Line, _] ->
            case binary:split(Line, <<" ">>, [global]) of
                [_Version, Code | _] -> {ok, binary_to_integer(Code)};
                _ -> {error, <<"malformed status line">>}
            end;
        [_] ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, More} -> read_status(Sock, <<Acc/binary, More/binary>>);
                {error, Reason} -> {error, format(Reason)}
            end
    end.

kill(Pid) ->
    exit(Pid, kill),
    nil.

format(Reason) -> list_to_binary(io_lib:format("~p", [Reason])).
