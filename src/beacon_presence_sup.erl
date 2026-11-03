-module(beacon_presence_sup).
-behaviour(supervisor).

%% Supervisor of one presence tracker: one_for_one over its pool_size
%% shards (beacon_presence_shard), registered as
%% beacon_presence_<name>_sup. A shard that crashes restarts with a new
%% version and an empty state. Peers see the new version and drop the old
%% replica with its entries; tracked processes monitor their shard and
%% track again (WS8b wires that into the runtime).

-export([start_link/1, init/1]).

start_link(Config) ->
    #{sup_name := SupName} = Config,
    supervisor:start_link({local, SupName}, ?MODULE, Config).

init(Config) ->
    #{name := Name, pool_size := PoolSize} = Config,
    beacon_log_ffi:info(<<"beacon.presence">>, "Starting tracker ~ts with ~b shards", [Name, PoolSize]),
    Children = [
        #{id => {shard, I},
          start => {beacon_presence_shard, start_link, [I, Config]},
          type => worker,
          %% Shards broadcast graceful_permdown in terminate/2.
          shutdown => 5000}
     || I <- lists:seq(1, PoolSize)
    ],
    {ok, {#{strategy => one_for_one, intensity => max(3, PoolSize), period => 5}, Children}}.
