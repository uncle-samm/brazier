-module(brazier_presence_ffi).

%% FFI of brazier/presence: lifecycle of a tracker's supervisor, calls to its
%% shards and reads from their ETS tables (see brazier_presence_shard).
%%
%% A topic always maps to the shard erlang:phash2(Topic, PoolSize) + 1, so
%% every node sends a topic's entries through the same shard index.
%% Errors are returned as brazier/presence.PresenceError values.
%%
%% Shards hold metas decoded with the tracker's decoder, so every read and
%% every track carries the fingerprint of the handle's decoder, and one that
%% is not the tracker's is refused (see fingerprint/1).

-export([names/2, start/2, start_link/2, stop/1, running/1, call/3, call_all/2, list/4,
         get_by_key/5, shard_pid/2, shard_index/2, decode_diff/3, fingerprint/1]).

%% Key of the one row of a shard's table that is not an entry:
%% {{?FINGERPRINT_KEY, Fingerprint}}. Entry keys are 4-tuples, so no entry
%% select matches it.
-define(FINGERPRINT_KEY, brazier_presence_decoder).

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
%%
%% A shard's rows hold the meta as readers return it (see
%% brazier_presence_shard), so a read is one select that builds the
%% brazier/presence/sync.Entry records, {entry, Key, [Meta]}, and one walk
%% over them that allocates nothing unless a key has several metas or a
%% meta did not decode. Its cost per entry does not grow with the room.

%% The entries on Topic, ordered by key: {ok, [Entry]} | {error, PresenceError}.
list(Name, Names, Fingerprint, Topic) ->
    Table = shard_name(Names, Topic),
    case select(Name, Table, Fingerprint,
                [{{{Topic, '$1', '_', '_'}, '$2'}, [], [{{entry, '$1', ['$2']}}]}]) of
        {ok, Rows} -> entries(Name, Rows);
        {error, Reason} -> {error, Reason}
    end.

%% The entry of Key on Topic: {ok, Entry} | {error, PresenceError}.
get_by_key(Name, Names, Fingerprint, Topic, Key) ->
    Table = shard_name(Names, Topic),
    case select(Name, Table, Fingerprint, [{{{Topic, Key, '_', '_'}, '$1'}, [], ['$1']}]) of
        {ok, []} ->
            {error, not_tracked};
        {ok, Metas} ->
            case undecodable(Metas) of
                none -> {ok, {entry, Key, Metas}};
                {Node, Reason} -> decode_failed(Name, Key, Node, Reason)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% The table dies with its shard; reads in that window see it missing.
%% The table's fingerprint row tells whether the caller's handle was built
%% with the decoder the shard decodes with (see check_fingerprint/3).
select(Name, Table, Fingerprint, Spec) ->
    try ets:member(Table, {?FINGERPRINT_KEY, Fingerprint}) of
        true -> {ok, ets:select(Table, Spec)};
        false -> fingerprint_mismatch(Name)
    catch
        error:badarg ->
            brazier_log_ffi:warning(<<"brazier.presence">>, "Table ~p is missing: its shard is not running",
                                   [Table]),
            {error, tracker_down}
    end.

%% Rows {entry, Key, [Meta]}, one per meta, consecutive per key. Returned
%% as they are when every key is distinct and every meta decoded.
entries(Name, Rows) ->
    case scan(Rows, none, distinct) of
        distinct -> {ok, Rows};
        repeated -> {ok, regroup(Rows)};
        {undecodable, Key, Node, Reason} -> decode_failed(Name, Key, Node, Reason)
    end.

%% Keys are binaries, so the first row never matches the atom `none`.
scan([], _Previous, Seen) ->
    Seen;
scan([{entry, Key, [{undecodable, Node, Reason}]} | _], _Previous, _Seen) ->
    {undecodable, Key, Node, Reason};
scan([{entry, Key, [_Meta]} | Rest], Key, _Seen) ->
    scan(Rest, Key, repeated);
scan([{entry, Key, [_Meta]} | Rest], _Previous, Seen) ->
    scan(Rest, Key, Seen).

%% One entry per key, its metas in row order (pid, then tag).
regroup([{entry, Key, [Meta]} | Rest]) ->
    regroup(Rest, Key, [Meta], []).

regroup([{entry, Key, [Meta]} | Rest], Key, Metas, Acc) ->
    regroup(Rest, Key, [Meta | Metas], Acc);
regroup([{entry, Next, [Meta]} | Rest], Key, Metas, Acc) ->
    regroup(Rest, Next, [Meta], [{entry, Key, lists:reverse(Metas)} | Acc]);
regroup([], Key, Metas, Acc) ->
    lists:reverse([{entry, Key, lists:reverse(Metas)} | Acc]).

undecodable([{undecodable, Node, Reason} | _]) -> {Node, Reason};
undecodable([_ | Rest]) -> undecodable(Rest);
undecodable([]) -> none.

%% A meta the shard could not decode (it logged why when it stored it)
%% fails every read that would return it.
decode_failed(Name, Key, Node, Reason) ->
    brazier_log_ffi:error(<<"brazier.presence">>, "Tracker ~ts cannot decode the meta of ~ts from ~ts: ~ts",
                         [Name, Key, Node, Reason]),
    {error, {meta_decode_failed, Reason}}.

fingerprint_mismatch(Name) ->
    brazier_log_ffi:error(<<"brazier.presence">>, "Tracker ~ts was started with another decoder than the "
                         "one of this handle: build every handle from the config the tracker "
                         "was started with", [Name]),
    {error, {meta_decode_failed, <<"the handle's decoder is not the decoder tracker ",
                                   Name/binary, " was started with">>}}.

%% The fingerprint of a tracker's decoder. A handle and the shards each
%% compute it from the decoder of their config, and the shards decode
%% remote metas with theirs, so a read through a handle whose decoder
%% differs would return values of another type: it is refused instead.
%% 32 bits: it guards against a handle built from another config, not
%% against an adversary, who cannot pick a handle's decoder.
fingerprint(Decoder) ->
    erlang:phash2(Decoder, 1 bsl 32).

%% Whether a request's fingerprint is the shard's: ok | {error, PresenceError}.
check_fingerprint(_Name, Fingerprint, Fingerprint) when is_integer(Fingerprint) ->
    ok;
check_fingerprint(Name, _Given, _Own) ->
    fingerprint_mismatch(Name).

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

%% A diff of tracker Name: {brazier_presence_diff, Name, Fingerprint, Topic,
%% Joins, Leaves} with entries {Key, Pid, Meta} (see brazier_presence_shard).
%% Returns {ok, {Topic, [Entry], [Entry]}}, each side grouped by key in key
%% order, or {error, PresenceError}.
decode_diff(Name, Fingerprint, {brazier_presence_diff, Name, Own, Topic, Joins, Leaves})
  when is_binary(Topic), is_list(Joins), is_list(Leaves) ->
    case check_fingerprint(Name, Fingerprint, Own) of
        ok ->
            case diff_entries(Name, Joins) of
                {ok, JoinEntries} ->
                    case diff_entries(Name, Leaves) of
                        {ok, LeaveEntries} -> {ok, {Topic, JoinEntries, LeaveEntries}};
                        {error, Reason} -> {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end;
decode_diff(_Name, _Fingerprint, _Message) ->
    {error, invalid_message}.

%% A shard reports a diff's entries in the order it changed them; group
%% them by key (keysort is stable, so a key's metas keep that order).
diff_entries(Name, Entries) ->
    case diff_rows(Entries, []) of
        {ok, Rows} -> entries(Name, lists:keysort(2, Rows));
        error -> {error, invalid_message}
    end.

diff_rows([{Key, Pid, Meta} | Rest], Acc) when is_binary(Key), is_pid(Pid) ->
    case Meta of
        {meta, _Value, Ref, _RefPrev, Node} when is_binary(Ref), is_binary(Node) ->
            diff_rows(Rest, [{entry, Key, [Meta]} | Acc]);
        {undecodable, Node, Reason} when is_binary(Node), is_binary(Reason) ->
            diff_rows(Rest, [{entry, Key, [Meta]} | Acc]);
        _ ->
            error
    end;
diff_rows([], Acc) ->
    {ok, lists:reverse(Acc)};
diff_rows(_Entries, _Acc) ->
    error.

%% --- Helpers ---

%% The Gleam record brazier/presence.ShardConfig as the map shards use.
config_map({shard_config, Name, PoolSize, BroadcastPeriod, MaxSilent, DownPeriod,
            PermdownPeriod, ClockSamples, MaxDeltaSizes, MaxTopicsPerPid,
            MaxEntriesPerShard, MaxTransferEntries, Decoder},
           {names, Sup, Shards}) ->
    Topics = list_to_tuple([<<"brazier_presence:", Name/binary, ":",
                              (integer_to_binary(I))/binary>>
                            || I <- lists:seq(1, PoolSize)]),
    Fingerprint = fingerprint(Decoder),
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
      max_transfer_entries => MaxTransferEntries,
      decoder => Decoder,
      fingerprint => Fingerprint,
      fingerprint_row => {{?FINGERPRINT_KEY, Fingerprint}}}.

format(Term) ->
    unicode:characters_to_binary(io_lib:format("~p", [Term])).
