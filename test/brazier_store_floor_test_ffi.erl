-module(brazier_store_floor_test_ffi).

%% Test helpers for cluster/store_floor_test: reading a key-value replica's
%% backoff and incarnation, suspending it, sending it a floor of its own
%% node from a cluster member, and collecting the warnings and errors one
%% node logs across several rpc calls.

-export([backoff/1, peer_digests/1, incarnation/1, suspend/1, resume/1, send_stale_floor/3,
         backoff_window/2, start_capture/0, stop_capture/1, log/2]).

%% This node's key-value replica of store Name. A test helper: a replica
%% that is not running crashes the test.
replica(Name) ->
    {ok, Pid} = brazier_store_test_ffi:replica_pid(Name),
    Pid.

%% The replica's backoff: {Node, Attempt, MsUntilRetry} for every peer a
%% refused merge put in backoff, sorted. sys:get_state/1 is answered once
%% the replica has handled the messages before it.
backoff(Name) ->
    #{backoff := Backoff} = sys:get_state(replica(Name)),
    Now = erlang:monotonic_time(millisecond),
    lists:sort([{Node, Attempt, RetryAt - Now} || {Node, {Attempt, RetryAt}} <- maps:to_list(Backoff)]).

%% The nodes whose replica's last digest the replica holds, sorted.
peer_digests(Name) ->
    #{peer_digests := Digests} = sys:get_state(replica(Name)),
    lists:sort(maps:keys(Digests)).

%% The incarnation of the running replica.
incarnation(Name) ->
    #{replica := {replica, _Node, Incarnation}} = sys:get_state(replica(Name)),
    Incarnation.

suspend(Name) ->
    ok = sys:suspend(replica(Name)),
    nil.

resume(Name) ->
    ok = sys:resume(replica(Name)),
    nil.

%% Deliver to this node's replica, as a delta broadcast by the cluster
%% member From, a floor of this node Above incarnations past the running
%% one, as a later incarnation of this node would publish it. Returns the
%% floor.
send_stale_floor(Name, From, Above) when is_atom(From), is_integer(Above), Above >= 1 ->
    Pid = replica(Name),
    {_Server, _Sup, _Table, Topic} = brazier_store_replica:names(key_value, Name),
    Floor = incarnation(Name) + Above,
    Later = {replica, atom_to_binary(node(), utf8), Floor},
    {ok, {_State, Delta}} = 'brazier@store@crdt':raise_floor('brazier@store@crdt':new(), Later),
    Pid ! {brazier_pubsub, Topic, {brazier_store, delta, From, Delta}},
    Floor.

%% The replica's retry window after Attempt refusals with sync interval
%% Interval (brazier_store_replica caps it at max(Interval, 60s)).
backoff_window(Attempt, Interval) ->
    brazier_cluster_manager:backoff_window(Attempt, Interval, max(Interval, 60000)).

%% Collect the warnings and errors logged on this node until stop_capture/1,
%% in a process of its own, so the capture outlives the rpc call that
%% starts it. The peer nodes run with logger_level none: the primary level
%% is warning while the capture runs, and the default handler is silenced,
%% so nothing is printed.
start_capture() ->
    Caller = self(),
    Ref = make_ref(),
    Pid = spawn(fun() -> capture(Caller, Ref) end),
    Monitor = erlang:monitor(process, Pid),
    receive
        {Ref, ready} ->
            true = erlang:demonitor(Monitor, [flush]),
            Pid;
        {'DOWN', Monitor, process, Pid, Reason} ->
            erlang:error({capture_not_started, Reason})
    after 5000 ->
        erlang:error(capture_not_started)
    end.

capture(Caller, Ref) ->
    Id = list_to_atom("brazier_store_floor_capture_" ++ integer_to_list(erlang:unique_integer([positive]))),
    #{level := PrimaryLevel} = logger:get_primary_config(),
    DefaultLevel = case logger:get_handler_config(default) of
        {ok, #{level := Level}} ->
            ok = logger:update_handler_config(default, level, none),
            {restore, Level};
        {error, {not_found, default}} ->
            none_installed
    end,
    ok = logger:add_handler(Id, ?MODULE, #{level => warning, config => #{collector => self()}}),
    ok = logger:set_primary_config(level, warning),
    Caller ! {Ref, ready},
    collect(Id, PrimaryLevel, DefaultLevel, []).

collect(Id, PrimaryLevel, DefaultLevel, Lines) ->
    receive
        {brazier_store_floor_captured, Line} ->
            collect(Id, PrimaryLevel, DefaultLevel, [Line | Lines]);
        {stop, From, Ref} ->
            ok = logger:set_primary_config(level, PrimaryLevel),
            ok = logger:remove_handler(Id),
            case DefaultLevel of
                {restore, Level} -> ok = logger:update_handler_config(default, level, Level);
                none_installed -> ok
            end,
            From ! {Ref, lists:reverse(drain(Lines))}
    end.

%% Lines the handler sent before it was removed.
drain(Lines) ->
    receive
        {brazier_store_floor_captured, Line} -> drain([Line | Lines])
    after 0 ->
        Lines
    end.

%% The lines a capture collected, as {Level, Text, AtMs}, in order.
stop_capture(Pid) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! {stop, self(), Ref},
    receive
        {Ref, Lines} ->
            true = erlang:demonitor(Ref, [flush]),
            Lines;
        {'DOWN', Ref, process, Pid, Reason} ->
            erlang:error({capture_died, Reason})
    after 5000 ->
        erlang:error(capture_not_stopped)
    end.

%% logger handler callback: runs in the logging process.
log(#{level := Level, msg := Msg, meta := Meta}, #{config := #{collector := Collector}}) ->
    Collector ! {brazier_store_floor_captured,
                 {atom_to_binary(Level, utf8), format(Msg, Meta),
                  erlang:monotonic_time(millisecond)}},
    ok.

format({string, String}, _Meta) ->
    unicode:characters_to_binary(String);
format({report, Report}, #{report_cb := Callback}) when is_function(Callback, 1) ->
    {Format, Args} = Callback(Report),
    unicode:characters_to_binary(io_lib:format(Format, Args));
format({report, Report}, _Meta) ->
    unicode:characters_to_binary(io_lib:format("~p", [Report]));
format({Format, Args}, _Meta) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).
