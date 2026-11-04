-module(brazier_store_sup).
-behaviour(supervisor).

%% Supervisor of one replicated store replica (brazier_store_replica),
%% registered as brazier_rs_<name>_sup (key-value) or brazier_rls_<name>_sup
%% (list). A replica that crashes restarts as a new incarnation with an
%% empty state and pulls the state of its peers (sync_req on start), the
%% same full sync a node gets when it joins the cluster.

-export([start_link/1, init/1]).

start_link(Args = #{sup := Sup}) ->
    supervisor:start_link({local, Sup}, ?MODULE, Args).

init(Args = #{name := Name, kind := Kind}) ->
    brazier_log_ffi:info(<<"brazier.store">>, "Starting replicated store ~ts (~p)", [Name, Kind]),
    Child = #{id => replica,
              start => {brazier_store_replica, start_link, [Args]},
              type => worker,
              shutdown => 5000},
    {ok, {#{strategy => one_for_one, intensity => 3, period => 5}, [Child]}}.
