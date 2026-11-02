-module(beacon_effect_test_ffi).
-export([effect_guardian/1, pg_members/1]).

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
