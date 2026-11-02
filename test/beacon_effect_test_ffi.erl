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

%% Wait until a topic has no local subscribers. The registry partition
%% removes a dead subscriber when it handles the subscriber's 'EXIT', which
%% can trail the DOWN the test receives, so this polls the registry until
%% the deadline. Returns the subscribers still present at the deadline
%% ([] on success).
await_pg_empty(Topic, TimeoutMs) ->
    await_pg_empty_until(Topic, erlang:monotonic_time(millisecond) + TimeoutMs).

await_pg_empty_until(Topic, Deadline) ->
    case pg_members(Topic) of
        [] ->
            [];
        Members ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    Members;
                false ->
                    receive after 5 -> await_pg_empty_until(Topic, Deadline) end
            end
    end.
