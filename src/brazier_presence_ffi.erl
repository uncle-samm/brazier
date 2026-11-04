-module(brazier_presence_ffi).

%% FFI of brazier/presence: lifecycle of a tracker's supervisor, calls to its
%% shards and reads from their ETS tables (see brazier_presence_shard).
%%
%% A topic always maps to the shard erlang:phash2(Topic, PoolSize) + 1, so
%% every node sends a topic's entries through the same shard index.
%% Errors are returned as brazier/presence.PresenceError values.

-export([names/2, start/2, start_link/2, stop/1, running/1, call/3, call_all/2, list/2,
         get_by_key/3, shard_pid/2, shard_index/2, decode_diff/2]).

%% Bound on a shard call. A shard serves calls between heartbeats, so a
%% call that takes longer than this means the shard is stuck.
-define(CALL_TIMEOUT_MS, 5000).
%% Bound on stop/1; the supervisor's shutdown of each shard is 5s.
-define(STOP_TIMEOUT_MS, 15000).

%% The Gleam record brazier/presence.Names(sup, shards). Atoms are built
%% once per tracker from a validated name ([a-z0-9_], 1 to 32 bytes) and a
%% bounded pool size, never per message.
names(Name, PoolSize) ->
    Prefix = "brazier_presence_" ++ binary_to_list(Name),
    Shards = list_to_tuple([list_to_atom(Prefix ++ "_" ++ integer_to_list(I))
                            || I <- lists:seq(1, PoolSize)]),
    {names, list_to_atom(Prefix ++ "_sup"), Shards}.

%% --- Lifecycle ---

%% Start the tracker unlinked from the caller.
start(Config, Names) ->
    case brazier_presence_sup:start_link(config_map(Config, Names)) of
        {ok, Pid} ->
            true = unlink(Pid),
            {ok, nil};
        {error, Reason} ->
            start_error(Config, Reason)
    end.

%% Start the tracker linked to the caller, for a supervisor to own.
start_link(Config, Names) ->
    case brazier_presence_sup:start_link(config_map(Config, Names)) of
        {ok, Pid} -> {ok, Pid};
        {error, Reason} -> start_error(Config, Reason)
    end.

start_error(Config, {already_started, Pid}) ->
    Name = element(2, Config),
    brazier_log_ffi:error(<<"brazier.presence">>, "Tracker ~ts is already running as ~p", [Name, Pid]),
    {error, {start_failed, <<"a tracker named ", Name/binary, " is already running">>}};
start_error(Config, Reason) ->
    brazier_log_ffi:error(<<"brazier.presence">>, "Tracker ~ts failed to start: ~p",
                         [element(2, Config), Reason]),
    {error, {start_failed, format(Reason)}}.

%% Whether the tracker's supervisor is registered on this node.
running({names, Sup, _Shards}) ->
    whereis(Sup) =/= undefined.

stop({names, Sup, _Shards}) ->
    case whereis(Sup) of
        undefined ->
            {error, tracker_down};
        Pid ->
            brazier_log_ffi:info(<<"brazier.presence">>, "Stopping ~p", [Sup]),
            %% proc_lib:stop/3: a supervisor ignores shutdown signals from
            %% any process but its parent.
            try proc_lib:stop(Pid, shutdown, ?STOP_TIMEOUT_MS) of
                ok ->
                    brazier_log_ffi:info(<<"brazier.presence">>, "Stopped ~p", [Sup]),
                    {ok, nil}
            catch
                exit:noproc ->
                    brazier_log_ffi:warning(<<"brazier.presence">>, "~p was already stopping", [Sup]),
                    {error, tracker_down};
                exit:Reason ->
                    brazier_log_ffi:error(<<"brazier.presence">>, "~p did not stop: ~p", [Sup, Reason]),
                    {error, {stop_failed, format(Reason)}}
            end
    end.

%% --- Shard calls ---

call(Names, Topic, Request) ->
    call_shard(shard_name(Names, Topic), Request).

%% Send Request to every shard. Stops at the first error.
call_all({names, _Sup, Shards}, Request) ->
    lists:foldl(fun
        (Shard, {ok, nil}) -> call_shard(Shard, Request);
        (_Shard, Error) -> Error
    end, {ok, nil}, tuple_to_list(Shards)).

call_shard(Shard, Request) ->
    try
        gen_server:call(Shard, Request, ?CALL_TIMEOUT_MS)
    catch
        exit:{noproc, _} ->
            brazier_log_ffi:warning(<<"brazier.presence">>, "Shard ~p is not running", [Shard]),
            {error, tracker_down};
        exit:{timeout, _} ->
            brazier_log_ffi:error(<<"brazier.presence">>, "Shard ~p did not answer within ~b ms",
                                 [Shard, ?CALL_TIMEOUT_MS]),
            {error, tracker_timeout};
        exit:Reason ->
            brazier_log_ffi:error(<<"brazier.presence">>, "Shard ~p exited during a call: ~p",
                                 [Shard, Reason]),
            {error, tracker_down}
    end.

%% --- Reads (ETS, no call) ---

%% Entries on Topic as {Key, Pid, NodeBin, StoredMeta}, ordered by key.
list(Names, Topic) ->
    select(shard_name(Names, Topic),
           [{{{Topic, '$1', '$2', '_'}, '$3', '$4'}, [], [{{'$1', '$2', '$3', '$4'}}]}]).

get_by_key(Names, Topic, Key) ->
    select(shard_name(Names, Topic),
           [{{{Topic, Key, '$1', '_'}, '$2', '$3'}, [], [{{{const, Key}, '$1', '$2', '$3'}}]}]).

%% The table dies with its shard; reads in that window see it missing.
select(Table, Spec) ->
    try
        {ok, ets:select(Table, Spec)}
    catch
        error:badarg ->
            brazier_log_ffi:warning(<<"brazier.presence">>, "Table ~p is missing: its shard is not running",
                                   [Table]),
            {error, tracker_down}
    end.

%% The shard process for Topic. Tracked processes monitor it.
shard_pid(Names, Topic) ->
    case whereis(shard_name(Names, Topic)) of
        undefined -> {error, tracker_down};
        Pid -> {ok, Pid}
    end.

shard_index({names, _Sup, Shards}, Topic) ->
    erlang:phash2(Topic, tuple_size(Shards)) + 1.

shard_name(Names = {names, _Sup, Shards}, Topic) ->
    element(shard_index(Names, Topic), Shards).

%% --- Diffs ---

decode_diff(Name, {brazier_presence_diff, Name, Topic, Joins, Leaves})
  when is_binary(Topic), is_list(Joins), is_list(Leaves) ->
    {ok, {Topic, Joins, Leaves}};
decode_diff(_Name, _Message) ->
    {error, invalid_message}.

%% --- Helpers ---

%% The Gleam record brazier/presence.ShardConfig as the map shards use.
config_map({shard_config, Name, PoolSize, BroadcastPeriod, MaxSilent, DownPeriod,
            PermdownPeriod, ClockSamples, MaxDeltaSizes, MaxTopicsPerPid,
            MaxEntriesPerShard, MaxTransferEntries},
           {names, Sup, Shards}) ->
    Topics = list_to_tuple([<<"brazier_presence:", Name/binary, ":",
                              (integer_to_binary(I))/binary>>
                            || I <- lists:seq(1, PoolSize)]),
    #{name => Name,
      pool_size => PoolSize,
      sup_name => Sup,
      shard_names => Shards,
      shard_topics => Topics,
      broadcast_period => BroadcastPeriod,
      max_silent_periods => MaxSilent,
      down_period => DownPeriod,
      permdown_period => PermdownPeriod,
      clock_sample_periods => ClockSamples,
      max_delta_sizes => MaxDeltaSizes,
      max_topics_per_pid => MaxTopicsPerPid,
      max_entries_per_shard => MaxEntriesPerShard,
      max_transfer_entries => MaxTransferEntries}.

format(Term) ->
    unicode:characters_to_binary(io_lib:format("~p", [Term])).
