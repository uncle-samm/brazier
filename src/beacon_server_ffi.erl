-module(beacon_server_ffi).
%% Small process helpers for beacon/transport/server.
-export([whereis/1, stop_supervisor/1]).

-define(STOP_TIMEOUT_MS, 15000).

whereis(Name) when is_atom(Name) ->
    case erlang:whereis(Name) of
        undefined -> {error, nil};
        Pid -> {ok, Pid}
    end.

%% Synchronously stop a supervisor that is linked to the caller.
%% The link is removed first so the caller is not taken down (or sent an
%% 'EXIT' message when trapping exits) by the shutdown.
stop_supervisor(Pid) when is_pid(Pid) ->
    Ref = erlang:monitor(process, Pid),
    true = unlink(Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _Reason} -> nil
    after ?STOP_TIMEOUT_MS ->
        beacon_log_ffi:error(<<"beacon.server">>, "listener supervisor ~p ignored shutdown for ~pms, killing",
                             [Pid, ?STOP_TIMEOUT_MS]),
        exit(Pid, kill),
        receive
            {'DOWN', Ref, process, Pid, _} -> nil
        end
    end.
