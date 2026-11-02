-module(beacon_session_ffi).
-export([
    session_ets_new/1,
    session_ets_insert_new/5,
    session_ets_lookup/2,
    session_ets_cas/4,
    session_ets_touch/3,
    session_ets_delete/2,
    session_ets_delete_if_version/3,
    session_ets_expired_ids/3,
    session_ets_size/1,
    table_name/1,
    now_ms/0,
    generate_session_id/0,
    binding_fingerprint/1,
    constant_time_equal/2,
    bind_process/3,
    bound_process_count/2,
    notify_revoked/3,
    start_sweeper/3
]).

%% Session rows are stored as:
%%   {Id, Version, CreatedAtMs, LastSeenMs, Session}
%% where Session is the Gleam `Session(id, data)` record and all times are
%% erlang:monotonic_time(millisecond). Version increases on every data write
%% so updates can be applied with an atomic compare-and-swap (select_replace).
%%
%% SECURITY: Atom creation constraint.
%% Session store names come from developer code at compile time, not from runtime
%% user input. The validate_atom_name/1 guard restricts names to alphanumeric/
%% underscore/hyphen (max 255 bytes). Each distinct store creates one atom.

-define(PG_SCOPE, beacon_session_pg).

session_ets_new(Name) ->
    case validate_atom_name(Name) of
        ok ->
            TableName = binary_to_atom(<<"beacon_session_", Name/binary>>, utf8),
            ets:new(TableName, [
                set, public, named_table,
                {read_concurrency, true}, {write_concurrency, true}
            ]);
        {error, Reason} ->
            error(Reason)
    end.

%% Validate that a name is safe for atom conversion.
%% Max 255 bytes, alphanumeric + underscore + hyphen only (no spaces, no special chars).
%% This prevents atom table exhaustion from arbitrary user-controlled input.
validate_atom_name(Name) when byte_size(Name) > 255 ->
    {error, <<"Name too long (max 255 bytes)">>};
validate_atom_name(Name) ->
    case re:run(Name, <<"^[a-zA-Z0-9_-]+$">>) of
        {match, _} -> ok;
        nomatch -> {error, <<"Invalid name: must be alphanumeric, underscore, or hyphen">>}
    end.

table_name(Table) ->
    atom_to_binary(ets:info(Table, name), utf8).

now_ms() ->
    erlang:monotonic_time(millisecond).

%% Insert a brand new row. Returns false if the id already exists (a 256-bit
%% random collision), so the caller can crash loudly instead of overwriting.
session_ets_insert_new(Table, Id, Version, NowMs, Session) ->
    ets:insert_new(Table, {Id, Version, NowMs, NowMs, Session}).

%% Returns {ok, {Version, CreatedAtMs, LastSeenMs, Session}} | {error, nil}.
session_ets_lookup(Table, Id) ->
    case ets:lookup(Table, Id) of
        [{_, Version, CreatedAt, LastSeen, Session}] ->
            {ok, {Version, CreatedAt, LastSeen, Session}};
        [] ->
            {error, nil}
    end.

%% Atomic compare-and-swap: replace the row for Id only if its version is
%% still ExpectedVersion. Returns true when the swap happened. A deleted row
%% never matches, so a concurrent delete can never be undone by a write.
session_ets_cas(Table, Id, ExpectedVersion, NewRow) ->
    Id = element(1, NewRow),
    MatchSpec = [{{Id, ExpectedVersion, '_', '_', '_'}, [], [{const, NewRow}]}],
    ets:select_replace(Table, MatchSpec) =:= 1.

%% Update only the last-seen timestamp. Never recreates a deleted row.
session_ets_touch(Table, Id, NowMs) ->
    ets:update_element(Table, Id, {4, NowMs}).

session_ets_delete(Table, Id) ->
    ets:delete(Table, Id),
    nil.

%% Delete the row only if it still has Version. Returns true if deleted.
session_ets_delete_if_version(Table, Id, Version) ->
    ets:select_delete(Table, [{{Id, Version, '_', '_', '_'}, [], [true]}]) =:= 1.

%% Ids (with their versions) whose absolute or idle deadline has passed.
session_ets_expired_ids(Table, AbsoluteCutoffMs, IdleCutoffMs) ->
    ets:select(Table, [{
        {'$1', '$2', '$3', '$4', '_'},
        [{'orelse', {'<', '$3', AbsoluteCutoffMs}, {'<', '$4', IdleCutoffMs}}],
        [{{'$1', '$2'}}]
    }]).

session_ets_size(Table) ->
    ets:info(Table, size).

generate_session_id() ->
    Bytes = crypto:strong_rand_bytes(32),
    Base = base64:encode(Bytes),
    %% Make URL-safe
    Safe = binary:replace(binary:replace(binary:replace(Base, <<"+">>, <<"-">>, [global]), <<"/">>, <<"_">>, [global]), <<"=">>, <<>>, [global]),
    Safe.

%% Lowercase hex SHA-256 of a session id. Safe to embed in signed tokens: it
%% identifies the session without disclosing the bearer secret.
binding_fingerprint(SessionId) ->
    Hash = crypto:hash(sha256, SessionId),
    << <<(hex_digit(N))>> || <<N:4>> <= Hash >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.

%% Constant-time comparison for secrets (CSRF tokens). Length is not secret.
constant_time_equal(A, B) when byte_size(A) =:= byte_size(B) ->
    crypto:hash_equals(A, B);
constant_time_equal(_, _) ->
    false.

%% --- Live-connection registry (pg) ---
%% Processes bound to a session (WebSocket handlers) join the pg group
%% {beacon_session, TableName, SessionId}. pg removes members automatically
%% when they exit, so the registry cannot leak dead processes.

ensure_pg() ->
    case pg:start(?PG_SCOPE) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok
    end.

group(TableName, SessionId) ->
    {beacon_session, TableName, SessionId}.

%% Idempotently bind Pid to the session. Returns the member count.
bind_process(TableName, SessionId, Pid) ->
    ensure_pg(),
    Group = group(TableName, SessionId),
    Members = pg:get_local_members(?PG_SCOPE, Group),
    case lists:member(Pid, Members) of
        true -> length(Members);
        false ->
            ok = pg:join(?PG_SCOPE, Group, Pid),
            length(Members) + 1
    end.

bound_process_count(TableName, SessionId) ->
    ensure_pg(),
    length(pg:get_local_members(?PG_SCOPE, group(TableName, SessionId))).

%% Send {beacon_session_revoked, SessionId, Reason} to every bound process.
%% Returns the number of processes notified.
notify_revoked(TableName, SessionId, Reason) ->
    ensure_pg(),
    Members = pg:get_local_members(?PG_SCOPE, group(TableName, SessionId)),
    lists:foreach(fun(Pid) ->
        Pid ! {beacon_session_revoked, SessionId, Reason}
    end, Members),
    length(Members).

%% --- Expiry sweeper ---
%% An unlinked process that runs SweepFun every IntervalMs and exits when
%% Owner (the process that owns the ETS table) exits. Unlinked so a sweeper
%% crash never kills the owner; monitored so it never outlives the table.
start_sweeper(Owner, IntervalMs, SweepFun) when is_integer(IntervalMs), IntervalMs > 0 ->
    spawn(fun() ->
        Ref = erlang:monitor(process, Owner),
        sweeper_loop(Ref, IntervalMs, SweepFun)
    end).

sweeper_loop(Ref, IntervalMs, SweepFun) ->
    receive
        {'DOWN', Ref, process, _, _} -> ok
    after IntervalMs ->
        SweepFun(),
        sweeper_loop(Ref, IntervalMs, SweepFun)
    end.
