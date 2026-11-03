-module(beacon_app_tree_test_ffi).

%% Helpers for the root supervision tree tests (app_tree_test). They run on
%% peer nodes, so the tree owns PubSub and the session scope there.

-export([children/1, await_restart/3, crash/2, http_status/1,
         snapshot/0, leftovers/1, whereis_name/1, receive_broadcast/2]).

-define(MAX_POLLS, 100000).

%% The root supervisor's children in start order (static_supervisor gives
%% child N the id N). Crashes if a child is not running.
children(Sup) ->
    Rows = lists:keysort(1, supervisor:which_children(Sup)),
    [case Child of
         Pid when is_pid(Pid) -> Pid;
         Other -> erlang:error({child_not_running, Id, Other})
     end || {Id, Child, _Type, _Modules} <- Rows].

%% Wait until child Index (0-based) runs with a pid other than Old. Each
%% check is a call to the supervisor (no sleeping): the killed child's EXIT
%% may reach the supervisor after a call, so a stale answer means asking
%% again. The bound turns a supervisor that never restarts it into a crash.
await_restart(Sup, Index, Old) ->
    await_restart(Sup, Index, Old, ?MAX_POLLS).

await_restart(_Sup, Index, Old, 0) ->
    erlang:error({child_not_restarted, Index, Old});
await_restart(Sup, Index, Old, N) ->
    Rows = lists:keysort(1, supervisor:which_children(Sup)),
    case lists:keyfind(Index, 1, Rows) of
        {Index, Pid, _, _} when is_pid(Pid), Pid =/= Old -> nil;
        _ ->
            erlang:yield(),
            await_restart(Sup, Index, Old, N - 1)
    end.

%% Crash child Pid of Sup and return once it is gone: a worker is killed, a
%% supervisor is terminated with an abnormal reason after stopping its own
%% children (the way a child supervisor fails).
crash(Sup, Pid) ->
    Type = case lists:keyfind(Pid, 2, supervisor:which_children(Sup)) of
        {_Id, Pid, T, _Modules} -> T;
        false -> erlang:error({not_a_child, Pid, Sup})
    end,
    Ref = erlang:monitor(process, Pid),
    case Type of
        worker -> exit(Pid, kill);
        supervisor -> ok = sys:terminate(Pid, test_crash, 5000)
    end,
    receive
        {'DOWN', Ref, process, Pid, _} -> nil
    after 5000 ->
        erlang:error({not_stopped, Pid})
    end.

%% GET / over a fresh connection to 127.0.0.1 (an address, so no resolver
%% port is opened). {ok, Status} | {error, Reason}.
http_status(Port) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000) of
        {ok, Sock} ->
            Req = <<"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n">>,
            Result = case gen_tcp:send(Sock, Req) of
                ok -> read_status(Sock, <<>>);
                {error, Reason} -> {error, format(Reason)}
            end,
            ok = gen_tcp:close(Sock),
            Result;
        {error, Reason} ->
            {error, format(Reason)}
    end.

read_status(Sock, Acc) ->
    case binary:match(Acc, <<"\r\n">>) of
        {Pos, _} ->
            <<Line:Pos/binary, _/binary>> = Acc,
            case binary:split(Line, <<" ">>, [global]) of
                [_Version, Code | _] -> {ok, binary_to_integer(Code)};
                _ -> {error, <<"malformed status line">>}
            end;
        nomatch ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Data} -> read_status(Sock, <<Acc/binary, Data/binary>>);
                {error, Reason} -> {error, format(Reason)}
            end
    end.

%% Every process and port on this node.
snapshot() ->
    {erlang:processes(), erlang:ports()}.

%% Processes and ports that exist now but not in Before, described (the
%% calling process excluded).
leftovers({Procs, Ports}) ->
    NewProcs = [P || P <- erlang:processes(), P =/= self(),
                     not lists:member(P, Procs)],
    NewPorts = [P || P <- erlang:ports(), not lists:member(P, Ports)],
    [describe_process(P) || P <- NewProcs] ++ [describe_port(P) || P <- NewPorts].

describe_process(Pid) ->
    Info = erlang:process_info(Pid, [registered_name, initial_call,
                                     current_function, dictionary]),
    format({Pid, case Info of
                     undefined -> exited;
                     Items -> proplists:delete(dictionary, Items) ++
                                  [{proc_lib_initial,
                                    proplists:get_value('$initial_call',
                                       proplists:get_value(dictionary, Items))}]
                 end}).

describe_port(Port) ->
    format({Port, erlang:port_info(Port, name)}).

whereis_name(Name) ->
    case whereis(binary_to_atom(Name)) of
        undefined -> {error, nil};
        Pid -> {ok, Pid}
    end.

%% The next PubSub delivery on Topic: {ok, Msg} | {error, nil}.
receive_broadcast(Topic, Timeout) ->
    receive
        {beacon_pubsub, Topic, Msg} -> {ok, Msg}
    after Timeout ->
        {error, nil}
    end.

format(Term) ->
    iolist_to_binary(io_lib:format("~p", [Term])).
