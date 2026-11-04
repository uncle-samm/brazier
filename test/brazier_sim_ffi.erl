-module(brazier_sim_ffi).
-export([
    new_metrics/0, increment/2, increment_by/3, record_latency/2, record_payload/2,
    mark_event_send_start/1, take_event_send_start/0, collect/1, destroy/1,
    monotonic_us/0, snapshot_memory/0, snapshot_processes/0,
    snapshot_pids/0, count_new_processes/1, describe_new_processes/1,
    message_queue_len/1,
    watch_teardown/1, unwatch_teardown/1, await_teardown/3, handle_ws_close/4,
    close_reporter/0, close_report_waiting/0
]).

%% Create a new metrics ETS table. Returns table reference.
%% Uses two tables: one set for counters, one bag for latency samples.
new_metrics() ->
    Counters = ets:new(sim_counters, [set, public, {write_concurrency, true}]),
    Latencies = ets:new(sim_latencies, [bag, public, {write_concurrency, true}]),
    %% Initialize all counters to 0
    ets:insert(Counters, {events_sent, 0}),
    ets:insert(Counters, {events_acked, 0}),
    ets:insert(Counters, {events_failed, 0}),
    ets:insert(Counters, {connections_opened, 0}),
    ets:insert(Counters, {connections_closed, 0}),
    ets:insert(Counters, {connections_failed, 0}),
    ets:insert(Counters, {bytes_sent, 0}),
    ets:insert(Counters, {bytes_received, 0}),
    ets:insert(Counters, {patches_received, 0}),
    ets:insert(Counters, {model_syncs_received, 0}),
    ets:insert(Counters, {mounts_received, 0}),
    ets:insert(Counters, {last_payload, <<>>}),
    {Counters, Latencies}.

%% Atomically increment a counter by 1.
increment({Counters, _Latencies}, Key) ->
    case validate_atom_name(Key) of
        ok ->
            AtomKey = binary_to_atom(Key, utf8),
            try
                ets:update_counter(Counters, AtomKey, 1),
                nil
            catch
                error:badarg ->
                    %% Counter didn't exist, create it
                    ets:insert(Counters, {AtomKey, 1}),
                    nil
            end;
        {error, Reason} ->
            error(Reason)
    end.

%% Atomically increment a counter by N.
increment_by({Counters, _Latencies}, Key, Amount) ->
    case validate_atom_name(Key) of
        ok ->
            AtomKey = binary_to_atom(Key, utf8),
            try
                ets:update_counter(Counters, AtomKey, Amount),
                nil
            catch
                error:badarg ->
                    ets:insert(Counters, {AtomKey, Amount}),
                    nil
            end;
        {error, Reason} ->
            error(Reason)
    end.

%% Validate that a name is safe for atom conversion.
%% Max 255 bytes, alphanumeric + underscore + hyphen only (no spaces, no special chars).
%% This prevents atom table exhaustion from arbitrary user-controlled input.
validate_atom_name(Name) when byte_size(Name) > 255 ->
    {error, <<"Name too long (max 255 bytes)">>};
validate_atom_name(Name) ->
    case re:run(Name, <<"^[a-zA-Z0-9_-]+$">>) of
        {match, _} -> ok;
        nomatch -> {error, <<"Invalid name: must be alphanumeric, underscore, or hyphen">>}
    end.

%% Record a latency sample (microseconds).
record_latency({_Counters, Latencies}, LatencyUs) ->
    ets:insert(Latencies, {latency, LatencyUs}),
    nil.

mark_event_send_start(SentAtUs) ->
    erlang:put(brazier_sim_event_send_start_us, SentAtUs),
    nil.

%% {ok, SentAtUs} or {error, nil} when no event is in flight. Monotonic
%% time is usually negative, so no value can mean "none".
take_event_send_start() ->
    case erlang:erase(brazier_sim_event_send_start_us) of
        undefined -> {error, nil};
        SentAtUs -> {ok, SentAtUs}
    end.

%% Store the latest received WebSocket payload for behavioral assertions.
record_payload({Counters, _Latencies}, Payload) ->
    ets:insert(Counters, {last_payload, Payload}),
    nil.

%% Collect all metrics into a Gleam-friendly structure.
%% Returns: {EventsSent, EventsAcked, EventsFailed,
%%           ConnOpened, ConnClosed, ConnFailed, Latencies}
collect({Counters, Latencies}) ->
    Get = fun(Key) ->
        case ets:lookup(Counters, Key) of
            [{_, Val}] -> Val;
            [] -> 0
        end
    end,
    LatencyList = [L || {latency, L} <- ets:tab2list(Latencies)],
    {
        Get(events_sent),
        Get(events_acked),
        Get(events_failed),
        Get(connections_opened),
        Get(connections_closed),
        Get(connections_failed),
        LatencyList,
        Get(bytes_sent),
        Get(bytes_received),
        Get(patches_received),
        Get(model_syncs_received),
        Get(mounts_received),
        Get(last_payload)
    }.

%% Delete metrics tables.
destroy({Counters, Latencies}) ->
    ets:delete(Counters),
    ets:delete(Latencies),
    nil.

%% Get monotonic time in microseconds (for latency measurement).
monotonic_us() ->
    erlang:monotonic_time(microsecond).

%% Get total BEAM memory in bytes.
snapshot_memory() ->
    erlang:memory(total).

%% Get total process count.
snapshot_processes() ->
    erlang:system_info(process_count).

%% Every live pid, to name the processes a leak check finds.
snapshot_pids() ->
    erlang:processes().

%% Count the processes alive now that were not in Before.
count_new_processes(Before) ->
    length(new_processes(Before)).

new_processes(Before) ->
    Old = sets:from_list(Before, [{version, 2}]),
    [P || P <- erlang:processes(), not sets:is_element(P, Old)].

%% Describe the processes alive now that were not in Before: registered
%% name or initial call, current function and queue length.
describe_new_processes(Before) ->
    New = new_processes(Before),
    Info = [{P, erlang:process_info(P, [registered_name, initial_call,
                                        current_function, dictionary,
                                        message_queue_len])} || P <- New],
    Lines = [describe_process(P, I) || {P, I} <- Info, I =/= undefined],
    iolist_to_binary(lists:join(<<"; ">>, Lines)).

describe_process(Pid, Info) ->
    Dict = proplists:get_value(dictionary, Info),
    Initial = case proplists:get_value('$initial_call', Dict) of
        undefined -> proplists:get_value(initial_call, Info);
        Call -> Call
    end,
    io_lib:format("~p name=~0p initial=~0p current=~0p queue=~b", [
        Pid,
        proplists:get_value(registered_name, Info),
        Initial,
        proplists:get_value(current_function, Info),
        proplists:get_value(message_queue_len, Info)
    ]).

%% --- Server teardown watch -------------------------------------------------
%%
%% A sim test that measures leaks must wait until the server has torn down
%% every connection it served, not sleep and hope. Every upgraded WebSocket
%% connection emits [brazier, ws, close] exactly once, from its own handler
%% process, before it shuts its runtime down. The telemetry handler below
%% runs in that process and reports it, with the processes linked to it
%% (its per-connection runtime), to the test. The test then monitors each
%% one and waits for it to exit.
%%
%% Only handlers whose parent is ConnsPid (the watched listener's
%% connection owner) are reported, so connections of other listeners in the
%% same VM are never counted.

%% Attach the watch. Returns {HandlerId, Tag, Alias}; reports arrive as
%% {Tag, HandlerPid, LinkedPids}. The handler sends them to an alias of the
%% caller (erlang:alias/0), so unwatch_teardown/1 can make sure none arrives
%% after it (see test/brazier/monitored.gleam, listening).
watch_teardown(ConnsPid) ->
    Tag = make_ref(),
    Alias = erlang:alias(),
    Id = iolist_to_binary(io_lib:format("brazier-sim-teardown-~p", [Tag])),
    ok = telemetry:attach(Id, [brazier, ws, close], fun ?MODULE:handle_ws_close/4,
                          #{test => Alias, tag => Tag, conns => ConnsPid}),
    {Id, Tag, Alias}.

handle_ws_close(_Event, _Measurements, _Metadata, #{test := Test, tag := Tag, conns := Conns}) ->
    case erlang:process_info(self(), [parent, links]) of
        [{parent, Conns}, {links, Links}] ->
            Linked = [P || P <- Links, is_pid(P), P =/= Conns],
            Test ! {Tag, self(), Linked},
            ok;
        _ ->
            ok
    end.

%% Remove the watch: detach its handler, deactivate the alias so a report
%% from a handler call already under way is dropped by the runtime, and
%% remove the reports still in the mailbox. Runs in the process that
%% attached the watch, the only one allowed to unalias it. teardown.watching
%% runs it however the body ends.
unwatch_teardown({Id, Tag, Alias}) ->
    ok = telemetry:detach(Id),
    true = erlang:unalias(Alias),
    flush_closes(Tag).

flush_closes(Tag) ->
    receive
        {Tag, _Handler, _Linked} -> flush_closes(Tag)
    after 0 -> nil
    end.

%% For teardown_test: the teardown watch handlers attached now, as a fun
%% that calls them from a new child of the caller (a connection handler as
%% the watch sees one when the caller is the watched connection owner) and
%% returns, with how many it called, once the child has exited.
close_reporter() ->
    Handlers = [{F, C} || #{id := <<"brazier-sim-teardown-", _/binary>>, function := F,
                            config := C} <- telemetry:list_handlers([brazier, ws, close])],
    fun() ->
        {Pid, Ref} = spawn_monitor(fun() ->
            [ok = F([brazier, ws, close], #{}, #{}, C) || {F, C} <- Handlers]
        end),
        receive
            {'DOWN', Ref, process, Pid, normal} -> length(Handlers)
        end
    end.

%% For teardown_test: whether the caller's mailbox holds a close report.
close_report_waiting() ->
    {messages, Messages} = erlang:process_info(self(), messages),
    lists:any(fun({Tag, Handler, Linked}) ->
                      is_reference(Tag) andalso is_pid(Handler) andalso is_list(Linked);
                 (_) ->
                      false
              end, Messages).

%% Wait for N close reports, then for every reported process to exit, all
%% within TimeoutMs. Returns {ok, nil} or {error, Description}. The watch
%% stays attached: unwatch_teardown/1 removes it.
await_teardown({_Id, Tag, _Alias}, N, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    case collect_closes(Tag, N, Deadline, []) of
        {ok, Pids} -> await_exits(Pids, Deadline);
        {error, Got} ->
            {error, iolist_to_binary(io_lib:format(
                "~b of ~b connections reported [brazier, ws, close] within ~b ms",
                [Got, N, TimeoutMs]))}
    end.

collect_closes(_Tag, 0, _Deadline, Acc) ->
    {ok, lists:usort(lists:append(Acc))};
collect_closes(Tag, N, Deadline, Acc) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Tag, Handler, Linked} ->
            collect_closes(Tag, N - 1, Deadline, [[Handler | Linked] | Acc])
    after Remaining ->
        {error, length(Acc)}
    end.

await_exits(Pids, Deadline) ->
    Monitors = maps:from_list([{erlang:monitor(process, P), P} || P <- Pids]),
    await_downs(Monitors, Deadline).

await_downs(Monitors, _Deadline) when map_size(Monitors) =:= 0 ->
    {ok, nil};
await_downs(Monitors, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {'DOWN', Ref, process, _Pid, _Reason} when is_map_key(Ref, Monitors) ->
            await_downs(maps:remove(Ref, Monitors), Deadline)
    after Remaining ->
        Alive = maps:values(Monitors),
        [erlang:demonitor(R, [flush]) || R <- maps:keys(Monitors)],
        Described = [{P, erlang:process_info(P, [current_function, initial_call, message_queue_len])}
                     || P <- Alive],
        {error, iolist_to_binary(io_lib:format(
            "~b server processes still alive at the deadline: ~0p",
            [length(Alive), Described]))}
    end.

%% Get message queue length for a process.
message_queue_len(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Len} -> Len;
        undefined -> -1
    end.
