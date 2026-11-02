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

%% Members of a Beacon PubSub topic (pg group in the beacon_pg scope).
pg_members(Topic) ->
    pg:get_members(beacon_pg, Topic).

%% Wait until a topic has no members. pg removes a dead member when its own
%% DOWN message is processed, which can trail the DOWN the test receives, so
%% this waits on pg's group monitor (explicit leave notifications) instead of
%% polling. Returns the members still present at the deadline ([] on success).
await_pg_empty(Topic, TimeoutMs) ->
    {Ref, Members} = pg:monitor(beacon_pg, Topic),
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    Result = await_pg_leaves(Ref, Topic, Members, Deadline),
    ok = pg:demonitor(beacon_pg, Ref),
    Result.

await_pg_leaves(_Ref, _Topic, [], _Deadline) ->
    [];
await_pg_leaves(Ref, Topic, Members, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Ref, leave, Topic, Left} ->
            await_pg_leaves(Ref, Topic, Members -- Left, Deadline);
        {Ref, join, Topic, Joined} ->
            await_pg_leaves(Ref, Topic, Members ++ Joined, Deadline)
    after Remaining ->
        Members
    end.
