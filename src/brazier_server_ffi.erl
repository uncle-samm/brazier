-module(brazier_server_ffi).
%% Small process helpers for brazier/transport/server.
-export([stop_supervisor/1]).

-define(STOP_TIMEOUT_MS, 15000).

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
        brazier_log_ffi:error(<<"brazier.server">>, "listener supervisor ~p ignored shutdown for ~pms, killing",
                             [Pid, ?STOP_TIMEOUT_MS]),
        exit(Pid, kill),
        receive
            {'DOWN', Ref, process, Pid, _} -> nil
        end
    end.
