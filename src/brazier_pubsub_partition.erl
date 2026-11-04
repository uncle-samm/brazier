-module(brazier_pubsub_partition).
-behaviour(gen_server).

%% One partition of the node-local PubSub registry (Elixir Registry's
%% duplicate-key partition, which Phoenix.PubSub uses).
%%
%% The partition owns two public ETS tables:
%%   keys: duplicate_bag of {Topic, Pid} -- read by every broadcast
%%   pids: duplicate_bag of {Pid, Topic} -- cleanup index per subscriber
%%
%% Subscribers write their own rows from their own process
%% (brazier_pubsub_ffi:subscribe/1) and link to the partition first, exactly
%% as Registry.register/3 does. The partition traps exits, so a subscriber
%% exit arrives here as an 'EXIT' message and its rows are removed. The link
%% runs both ways: when the partition dies its tables die with it, and its
%% subscribers are stopped with it instead of silently missing broadcasts.
%%
%% The partition starts unnamed and registers its name as the last step of
%% init, after its tables exist: a subscriber that finds the name finds the
%% tables, and brazier_pubsub_ffi:subscribe/1 rechecks the name after its
%% link and its inserts so it never writes rows that a restarted partition
%% would not own (Registry resolves partitions the same way, through a
%% name that exists only once the partition is ready).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Index, Config) ->
    gen_server:start_link(?MODULE, {Index, Config}, []).

init({Index, Config}) ->
    process_flag(trap_exit, true),
    #{keys := KeysTables, pids := PidsTables, partition_names := Names} = Config,
    Keys = element(Index, KeysTables),
    Pids = element(Index, PidsTables),
    Keys = ets:new(Keys, [duplicate_bag, public, named_table,
                          {read_concurrency, true}, {write_concurrency, true}]),
    Pids = ets:new(Pids, [duplicate_bag, public, named_table, {write_concurrency, true}]),
    %% INVARIANT: only this partition's incarnations take this name, and the
    %% previous one is dead (the supervisor restarts a child after its
    %% exit), so the name is free; a crash here is a supervisor bug.
    true = register(element(Index, Names), self()),
    brazier_log_ffi:debug(<<"brazier.pubsub">>, "Partition ~b started", [Index]),
    {ok, #{index => Index, keys => Keys, pids => Pids}}.

handle_call(Request, From, State = #{index := Index}) ->
    brazier_log_ffi:warning(<<"brazier.pubsub">>, "Partition ~b received unexpected call ~p from ~p",
                           [Index, Request, From]),
    {reply, {error, unexpected_call}, State}.

handle_cast(Request, State = #{index := Index}) ->
    brazier_log_ffi:warning(<<"brazier.pubsub">>, "Partition ~b received unexpected cast ~p", [Index, Request]),
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State = #{index := Index, keys := Keys, pids := Pids}) ->
    Rows = ets:take(Pids, Pid),
    [true = ets:delete_object(Keys, {Topic, Pid}) || {_, Topic} <- Rows],
    brazier_log_ffi:debug(<<"brazier.pubsub">>, "Partition ~b removed ~b subscriptions of exited ~p (~p)",
                         [Index, length(Rows), Pid, Reason]),
    {noreply, State};
handle_info(Message, State = #{index := Index}) ->
    brazier_log_ffi:warning(<<"brazier.pubsub">>, "Partition ~b received unexpected message ~p",
                           [Index, Message]),
    {noreply, State}.

terminate(Reason, #{index := Index}) ->
    brazier_log_ffi:info(<<"brazier.pubsub">>, "Partition ~b stopping: ~p", [Index, Reason]),
    ok.
