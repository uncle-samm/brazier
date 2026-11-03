-module(beacon_store_sup).
-behaviour(supervisor).

%% Supervisor of one replicated store replica (beacon_store_replica),
%% registered as beacon_rs_<name>_sup (key-value) or beacon_rls_<name>_sup
%% (list). A replica that crashes restarts as a new incarnation with an
%% empty state and pulls the state of its peers (sync_req on start), the
%% same full sync a node gets when it joins the cluster.

-export([start_link/1, init/1]).

start_link(Args = #{sup := Sup}) ->
    supervisor:start_link({local, Sup}, ?MODULE, Args).

init(Args = #{name := Name, kind := Kind}) ->
    beacon_log_ffi:info(<<"beacon.store">>, "Starting replicated store ~ts (~p)", [Name, Kind]),
    Child = #{id => replica,
              start => {beacon_store_replica, start_link, [Args]},
              type => worker,
              shutdown => 5000},
    {ok, {#{strategy => one_for_one, intensity => 3, period => 5}, [Child]}}.
