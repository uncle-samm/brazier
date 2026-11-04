-module(brazier_pubsub_sup).
-behaviour(supervisor).

%% Supervision tree of Brazier PubSub, a port of Phoenix.PubSub's pg adapter.
%%
%%   brazier_pubsub_sup (rest_for_one)
%%     1. pg scope brazier_pubsub_pg          -- cross-node worker membership
%%     2. brazier_pubsub_partition_sup        -- one_for_one over the local
%%                                              registry partitions
%%     3. brazier_pubsub_worker_sup           -- one_for_one over the
%%                                              forwarding workers
%%
%% rest_for_one: workers deliver into the partitions and join the pg scope,
%% so a restart of either restarts the workers after it.
%%
%% The configuration is written to persistent_term inside init/1. Name
%% registration happens before init/1 runs, so only the process that won the
%% registration ever writes it, and a concurrent start that lost cannot
%% overwrite the running configuration.

-export([start_link/1, init/1]).

-define(SUP, brazier_pubsub_sup).
-define(PARTITION_SUP, brazier_pubsub_partition_sup).
-define(WORKER_SUP, brazier_pubsub_worker_sup).
-define(SCOPE, brazier_pubsub_pg).
-define(CONFIG_KEY, {brazier_pubsub, config}).

%% Config is a map with the validated keys partitions, pool_size,
%% max_forward_queue and max_topics_per_subscriber.
start_link(Config) ->
    supervisor:start_link({local, ?SUP}, ?MODULE, {root, Config}).

init({root, Config}) ->
    #{partitions := Partitions, pool_size := PoolSize} = Config,
    Persisted = Config#{
        keys => list_to_tuple([keys_table(I) || I <- lists:seq(1, Partitions)]),
        pids => list_to_tuple([pids_table(I) || I <- lists:seq(1, Partitions)]),
        partition_names => list_to_tuple([partition_name(I) || I <- lists:seq(1, Partitions)])
    },
    ok = persistent_term:put(?CONFIG_KEY, Persisted),
    brazier_log_ffi:info(<<"brazier.pubsub">>, "Starting PubSub: ~b partitions, pool size ~b",
                        [Partitions, PoolSize]),
    Children = [
        #{id => pg_scope,
          start => {pg, start_link, [?SCOPE]},
          type => worker},
        #{id => partition_sup,
          start => {supervisor, start_link, [{local, ?PARTITION_SUP}, ?MODULE, {partitions, Persisted}]},
          type => supervisor},
        #{id => worker_sup,
          start => {supervisor, start_link, [{local, ?WORKER_SUP}, ?MODULE, {workers, Persisted}]},
          type => supervisor}
    ],
    {ok, {#{strategy => rest_for_one, intensity => 3, period => 5}, Children}};
init({partitions, Config}) ->
    #{partitions := Partitions} = Config,
    Children = [
        #{id => {partition, I},
          start => {brazier_pubsub_partition, start_link, [I, Config]},
          type => worker}
     || I <- lists:seq(1, Partitions)
    ],
    %% One crash per partition inside the period is tolerated before the
    %% whole registry is considered broken and escalates.
    {ok, {#{strategy => one_for_one, intensity => max(3, Partitions), period => 5}, Children}};
init({workers, Config}) ->
    #{pool_size := PoolSize} = Config,
    Children = [
        #{id => {worker, Shard},
          start => {brazier_pubsub_worker, start_link, [Shard, Config]},
          type => worker}
     || Shard <- lists:seq(0, PoolSize - 1)
    ],
    {ok, {#{strategy => one_for_one, intensity => max(3, PoolSize), period => 5}, Children}}.

%% Atom names are built once per partition at start, from a bounded
%% partition count (validated in brazier/pubsub), never per message.
keys_table(I) -> list_to_atom("brazier_pubsub_keys_" ++ integer_to_list(I)).
pids_table(I) -> list_to_atom("brazier_pubsub_pids_" ++ integer_to_list(I)).
partition_name(I) -> list_to_atom("brazier_pubsub_partition_" ++ integer_to_list(I)).
