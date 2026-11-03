-module(beacon_effect_test_ffi).
-export([effect_guardian/1, pg_members/1, await_pg_empty/2]).

%% Lifecycle-test helpers.

%% The guardian pid that beacon_effect_ffi:spawn_owned/1 records in the
%% worker's process dictionary.
effect_guardian(Worker) ->
    case erlang:process_info(Worker, dictionary) of
        {dictionary, Dict} ->
            case lists:keyfind(beacon_effect_guardian, 1, Dict) of
                {beacon_effect_guardian, Guardian} -> {ok, Guardian};
                false -> {error, nil}
            end;
        undefined ->
            {error, nil}
    end.

%% Local subscribers of a Beacon PubSub topic.
pg_members(Topic) ->
    {ok, Pids} = beacon_pubsub_ffi:local_subscribers(Topic),
    Pids.

%% Wait until a topic has no local subscribers. Every listed subscriber
%% must already be dead (the caller saw its DOWN). Its rows are removed by
%% the registry partition that owns it, a gen_server, when that partition
%% handles the subscriber's 'EXIT'. That can trail the DOWN the caller
%% received: the two signals reach different processes.
%%
%% No polling: a sys debug hook installed on the partition reports the
%% moment it has handled that 'EXIT'. sys:install/2 is a synchronous call,
%% so once it returns either the 'EXIT' was already handled (the rows are
%% gone, which is checked right after) or the hook will see it. Returns
%% the subscribers still present at the deadline ([] on success).
await_pg_empty(Topic, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    await_removed(Topic, pg_members(Topic), Deadline).

await_removed(_Topic, [], _Deadline) ->
    [];
await_removed(Topic, [Pid | _], Deadline) ->
    case is_process_alive(Pid) of
        true -> erlang:error({subscriber_still_alive, Topic, Pid});
        false -> ok
    end,
    {ok, Partition} = beacon_pubsub_ffi:partition_for(Pid),
    Self = self(),
    Ref = make_ref(),
    Hook = fun
        (waiting, {in, {'EXIT', Exited, _Reason}}, _ProcState) when Exited =:= Pid ->
            removing;
        (removing, {noreply, _State}, _ProcState) ->
            Self ! {Ref, removed},
            done;
        (HookState, _Event, _ProcState) ->
            HookState
    end,
    ok = sys:install(Partition, {Hook, waiting}),
    case lists:member(Pid, pg_members(Topic)) of
        false ->
            ok = sys:remove(Partition, Hook),
            await_removed(Topic, pg_members(Topic), Deadline);
        true ->
            Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
            receive
                {Ref, removed} -> await_removed(Topic, pg_members(Topic), Deadline)
            after Remaining ->
                ok = sys:remove(Partition, Hook),
                pg_members(Topic)
            end
    end.
