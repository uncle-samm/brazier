-module(brazier_session_ffi).
-export([
    session_ets_new/1,
    session_ets_insert_new/5,
    session_ets_lookup/2,
    session_ets_cas/4,
    session_ets_touch/3,
    session_ets_delete/2,
    session_ets_delete_if_version/3,
    session_ets_expired_ids/4,
    session_ets_size/1,
    table_name/1,
    now_ms/0,
    generate_session_id/0,
    binding_fingerprint/1,
    constant_time_equal/2,
    ensure_registry/0,
    start_registry_link/0,
    registry_running/0,
    bind_process/3,
    bound_process_count/2,
    is_bound/3,
    notify_revoked/3,
    notify_revoked_local/3,
    local_bound_sessions/1,
    session_group/2,
    start_maintenance/5
]).

%% Session rows are stored as:
%%   {Id, Version, CreatedAtMs, LastSeenMs, Session}
%% where Session is the Gleam `Session(id, data)` record and all times are
%% erlang:system_time(millisecond), so rows written by different nodes (or
%% read back from an External backend) compare. brazier/session allows
%% clock_skew_tolerance_ms of difference between node clocks. Version increases on every data write
%% so updates can be applied with an atomic compare-and-swap (select_replace).
%%
%% SECURITY: Atom creation constraint.
%% Session store names come from developer code at compile time, not from runtime
%% user input. The validate_atom_name/1 guard restricts names to alphanumeric/
%% underscore/hyphen (max 255 bytes). Each distinct store creates one atom.

-define(PG_SCOPE, brazier_session_pg).
%% Node-local map from a binding's pg group back to its session id (see
%% "Group names" below). Not "brazier_session_" + a name: that prefix is
%% the session stores' (session_ets_new/1).
-define(BINDINGS, brazier_bound_sessions).
-define(GROUP_DOMAIN, "brazier-session-group-v1").

session_ets_new(Name) ->
    case validate_atom_name(Name) of
        ok ->
            TableName = binary_to_atom(<<"brazier_session_", Name/binary>>, utf8),
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
    erlang:system_time(millisecond).

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

%% Up to Limit ids (with their versions) whose absolute or idle deadline has
%% passed (`=<` matches the `>=` lifetime check in brazier/session).
session_ets_expired_ids(Table, AbsoluteCutoffMs, IdleCutoffMs, Limit)
        when is_integer(Limit), Limit > 0 ->
    MatchSpec = [{
        {'$1', '$2', '$3', '$4', '_'},
        [{'orelse', {'=<', '$3', AbsoluteCutoffMs}, {'=<', '$4', IdleCutoffMs}}],
        [{{'$1', '$2'}}]
    }],
    case ets:select(Table, MatchSpec, Limit) of
        {Rows, _Continuation} -> Rows;
        '$end_of_table' -> []
    end.

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
%% {brazier_session, Namespace, Key} in the brazier_session_pg scope, where
%% Key is a hash of the session id (see "Group names" below).
%% pg removes members when they exit or when their node disconnects, so the
%% registry cannot leak dead processes. Namespace is the same on every node
%% for a shared (External) store, so a revocation on one node reaches the
%% sockets bound on all of them (pg:get_members is cluster-wide).
%%
%% pg lists the members of every connected node, but a revocation goes only
%% to processes on this node and on verified cluster members
%% (brazier_cluster_ffi:verified/1): members on any other node are skipped
%% and counted in a warning. A revocation is a plain message, which names no
%% sender node, so the receiving side cannot check it; every Brazier node
%% gates its own sends, so two nodes that do not verify each other exchange
%% no revocations in either direction.
%%
%% Ownership: `brazier.start` (application.start_supervised) starts the scope
%% with start_registry_link/0 as a child of the root supervision tree, before
%% the HTTP listener. Without the tree (application.start, tests, embedding)
%% ensure_registry/0 starts it unlinked. Nothing else starts it: a lazy start
%% from bind/notify could race the supervisor restarting the scope.
%%
%% While the scope is not running no process can be bound (pg would hold
%% the members), so the read and notify functions report no members, and
%% bind_process/3 crashes loudly.
%%
%% Group names: pg replicates group names to every connected node, and
%% pg:which_groups/1 lists them there, verified cluster member or not. A
%% session id is a bearer secret, so it is never part of a group name: the
%% group carries Key = SHA-256 over a domain tag, the namespace and the id.
%% Session ids are 256 random bits, so the hash can be neither inverted nor
%% guessed, and an unkeyed hash is enough (the pattern of Rack's session
%% private_id, CVE-2019-16782). The domain tag keeps Key distinct from
%% binding_fingerprint/1, the plain SHA-256 that signed tokens carry. The
%% namespace stays readable: it is the store's name, not a secret.
%%
%% Ids back: the re-check (local_bound_sessions/1) needs the ids of the
%% sessions bound on this node, which the group names no longer give. Each
%% binding writes a row {{Namespace, Key, Pid}, SessionId} to the node-local
%% table brazier_bound_sessions (owned by brazier_ets_owner) before it joins
%% the group. Rows of processes that have exited are deleted on every
%% maintenance sweep and before each re-check; a process never comes back
%% to life, so deleting them never races a binding. The table holds one row
%% per live binding plus the bindings that ended since the last sweep.

ensure_registry() ->
    case pg:start(?PG_SCOPE) of
        {ok, _Pid} ->
            brazier_log_ffi:info(<<"brazier.session">>,
                                "Started session registry scope ~p (unsupervised)",
                                [?PG_SCOPE]),
            nil;
        {error, {already_started, _Pid}} ->
            nil
    end.

%% Start the scope linked to the caller (a supervisor). Fails when it is
%% already running: an unlinked scope started earlier cannot be supervised.
start_registry_link() ->
    case pg:start_link(?PG_SCOPE) of
        {ok, Pid} ->
            brazier_log_ffi:info(<<"brazier.session">>,
                                "Started session registry scope ~p as ~p (supervised)",
                                [?PG_SCOPE, Pid]),
            {ok, Pid};
        {error, {already_started, Pid}} ->
            brazier_log_ffi:error(<<"brazier.session">>,
                                 "Session registry scope ~p is already running as ~p "
                                 "outside the supervision tree", [?PG_SCOPE, Pid]),
            {error, <<"the session registry scope (brazier_session_pg) is already running "
                      "outside the supervision tree; application.start or "
                      "session.ensure_registry ran before the supervised start">>};
        {error, Reason} ->
            brazier_log_ffi:error(<<"brazier.session">>,
                                 "Session registry scope ~p failed to start: ~p",
                                 [?PG_SCOPE, Reason]),
            {error, unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}
    end.

registry_running() ->
    whereis(?PG_SCOPE) =/= undefined.

group(Namespace, SessionId) ->
    {brazier_session, Namespace, group_key(Namespace, SessionId)}.

%% The pg group a process bound to SessionId in Namespace joins. Exported
%% for tests, which look the group up on other nodes.
session_group(Namespace, SessionId) when is_binary(Namespace), is_binary(SessionId) ->
    group(Namespace, SessionId).

group_key(Namespace, SessionId) ->
    crypto:hash(sha256, <<?GROUP_DOMAIN, (byte_size(Namespace)):32, Namespace/binary,
                          SessionId/binary>>).

%% The bindings table, created on first use.
bindings() ->
    case ets:whereis(?BINDINGS) of
        undefined ->
            case brazier_ets_ffi:ensure_table(atom_to_binary(?BINDINGS), ets_set) of
                {ok, ?BINDINGS} ->
                    brazier_log_ffi:info(<<"brazier.session">>,
                                        "Created the session bindings table ~p", [?BINDINGS]),
                    ?BINDINGS;
                {error, Reason} ->
                    brazier_log_ffi:error(<<"brazier.session">>,
                                         "Cannot create the session bindings table ~p: ~p",
                                         [?BINDINGS, Reason]),
                    erlang:error({brazier_session_bindings_unavailable, Reason})
            end;
        _Tid ->
            ?BINDINGS
    end.

%% Whether Pid is bound to the session on this node. A process cannot have
%% been bound while the scope is not running: bind_process/3 crashes then.
is_bound(Namespace, SessionId, Pid) ->
    case registry_running() of
        false -> false;
        true ->
            lists:member(Pid, pg:get_local_members(?PG_SCOPE, group(Namespace, SessionId)))
    end.

%% Idempotently bind Pid to the session. Returns the local member count.
%% Crashes when the scope is not running: binding would silently not happen.
bind_process(Namespace, SessionId, Pid) ->
    case registry_running() of
        true -> ok;
        false ->
            brazier_log_ffi:error(<<"brazier.session">>,
                                 "Cannot bind ~p: the session registry scope ~p is not running",
                                 [Pid, ?PG_SCOPE]),
            erlang:error({brazier_session_registry_down, ?PG_SCOPE})
    end,
    Key = group_key(Namespace, SessionId),
    Group = {brazier_session, Namespace, Key},
    %% The row goes in first, so a re-check that sees the pg member always
    %% finds its id. Rewriting it on a repeated bind changes nothing.
    true = ets:insert(bindings(), {{Namespace, Key, Pid}, SessionId}),
    Members = pg:get_local_members(?PG_SCOPE, Group),
    case lists:member(Pid, Members) of
        true -> length(Members);
        false ->
            ok = pg:join(?PG_SCOPE, Group, Pid),
            length(Members) + 1
    end.

%% Bound processes on this node only.
bound_process_count(Namespace, SessionId) ->
    length(local_members(group(Namespace, SessionId))).

%% Send {brazier_session_revoked, SessionId, Reason} to every bound process on
%% this node and on every verified cluster member. Returns the number of
%% processes notified.
notify_revoked(Namespace, SessionId, Reason) ->
    Members = case registry_running() of
        true -> pg:get_members(?PG_SCOPE, group(Namespace, SessionId));
        false -> []
    end,
    {Allowed, Skipped} = lists:partition(fun(Pid) -> member_node(node(Pid)) end, Members),
    case Skipped of
        [] ->
            ok;
        _ ->
            brazier_log_ffi:warning(<<"brazier.session">>,
                                   "Revocation skipped ~b bound process(es) on ~p: not verified "
                                   "cluster members",
                                   [length(Skipped), lists:usort([node(Pid) || Pid <- Skipped])])
    end,
    send_revoked(Allowed, SessionId, Reason).

member_node(Node) when Node =:= node() -> true;
member_node(Node) -> brazier_cluster_ffi:verified(Node).

%% The same, for processes on this node only (the nodeup re-check).
notify_revoked_local(Namespace, SessionId, Reason) ->
    send_revoked(local_members(group(Namespace, SessionId)), SessionId, Reason).

local_members(Group) ->
    case registry_running() of
        true -> pg:get_local_members(?PG_SCOPE, Group);
        false -> []
    end.

send_revoked(Members, SessionId, Reason) ->
    lists:foreach(fun(Pid) ->
        Pid ! {brazier_session_revoked, SessionId, Reason}
    end, Members),
    length(Members).

%% Session ids in Namespace with at least one bound process on this node:
%% the ids of the live rows in the bindings table whose group still has a
%% local member (a restarted scope has lost its members).
local_bound_sessions(Namespace) ->
    case registry_running() of
        true ->
            _Pruned = prune_bindings(Namespace),
            Bound = lists:usort([{Key, Id} || {{_, Key, _}, Id} <- binding_rows(Namespace)]),
            [Id || {Key, Id} <- Bound,
                   pg:get_local_members(?PG_SCOPE, {brazier_session, Namespace, Key}) =/= []];
        false ->
            []
    end.

%% Delete the rows of bindings in Namespace whose process has exited.
%% Returns how many were deleted.
prune_bindings(Namespace) ->
    Dead = [Row || {{_, _, Pid}, _} = Row <- binding_rows(Namespace), not is_process_alive(Pid)],
    lists:foreach(fun(Row) -> true = ets:delete_object(?BINDINGS, Row) end, Dead),
    case Dead of
        [] ->
            ok;
        _ ->
            brazier_log_ffi:debug(<<"brazier.session">>,
                                 "Pruned ~b ended session binding(s) in ~ts",
                                 [length(Dead), Namespace])
    end,
    length(Dead).

%% The bindings rows of Namespace. No table means no process on this node
%% was ever bound. A local member of one of Namespace's groups with no
%% table means the table was lost (its owner crashed, see brazier_ets_ffi
%% LOST TABLES) and the ids of those bindings with it: that crashes.
binding_rows(Namespace) ->
    case ets:whereis(?BINDINGS) of
        undefined ->
            case [G || {brazier_session, Ns, _} = G <- pg:which_groups(?PG_SCOPE),
                       Ns =:= Namespace,
                       pg:get_local_members(?PG_SCOPE, G) =/= []] of
                [] ->
                    [];
                Groups ->
                    brazier_log_ffi:error(<<"brazier.session">>,
                                         "~b session group(s) in ~ts have local members but the "
                                         "bindings table ~p is gone",
                                         [length(Groups), Namespace, ?BINDINGS]),
                    erlang:error({brazier_session_bindings_lost, Namespace})
            end;
        _Tid ->
            ets:match_object(?BINDINGS, {{Namespace, '_', '_'}, '_'})
    end.

%% --- Maintenance process ---
%% An unlinked process per store that
%%   - runs SweepFun every IntervalMs (timer via send_after, so other
%%     messages do not postpone the sweep), after deleting the bindings
%%     rows of Namespace's exited processes (prune_bindings/1), and
%%   - runs RecheckFun(Node) when Node and this node have verified each
%%     other ({brazier_cluster_peer_mutual, Node}, see
%%     brazier_cluster_ffi:subscribe_mutual/1): a revocation goes only from
%%     a node that has verified the bound process's node, so once each side
%%     has verified the other no further one is skipped, and the ones
%%     skipped before (while apart, or while only one side had verified the
%%     other) are caught up by this re-check of the local bindings. Notices
%%     already queued are coalesced into one re-check;
%% and exits when Owner (the process that created the store) exits.
%% Unlinked so a crash never kills the owner; monitored so it never outlives
%% the store. A crash inside either fun is logged and the loop continues:
%% the funs log their own failures, so a crash here is a bug worth an error
%% line, but stopping expiry for the life of the store would be worse.
%%
%% The subscription is made here, in the owner, before this returns: it
%% survives cluster manager restarts, and a failure to make it (the node's
%% ETS table owner is gone, see brazier_ets_ffi LOST TABLES) crashes the
%% owner loudly instead of running a store whose revocations are never
%% caught up.
%%
%% Residual window: pg replicates the bindings of each node to the others
%% on its own schedule (pg sync on nodeup), apart from the peer check. A
%% revocation sent after the mutual notice but before the sender's pg has
%% learnt of a remote binding misses that binding, and no re-check follows.
%% The transport's periodic auth re-check of every socket bounds it.
start_maintenance(Owner, Namespace, IntervalMs, SweepFun, RecheckFun)
        when is_binary(Namespace), is_integer(IntervalMs), IntervalMs > 0 ->
    Sweep = fun() ->
        run_guarded(prune_bindings, fun() -> prune_bindings(Namespace) end),
        run_guarded(sweep, fun() -> SweepFun() end)
    end,
    Pid = spawn(fun() ->
        Ref = erlang:monitor(process, Owner),
        ok = net_kernel:monitor_nodes(true),
        erlang:send_after(IntervalMs, self(), brazier_session_sweep),
        maintenance_loop(Ref, IntervalMs, Sweep, RecheckFun)
    end),
    case brazier_cluster_ffi:subscribe_mutual(Pid) of
        {ok, nil} ->
            Pid;
        {error, Reason} ->
            true = exit(Pid, kill),
            brazier_log_ffi:error(<<"brazier.session">>,
                                 "Session maintenance cannot subscribe to cluster membership: ~p",
                                 [Reason]),
            erlang:error({brazier_session_maintenance_not_subscribed, Reason})
    end.

maintenance_loop(Ref, IntervalMs, SweepFun, RecheckFun) ->
    receive
        {'DOWN', Ref, process, _, Reason} ->
            brazier_log_ffi:debug(<<"brazier.session">>,
                                 "Session store owner exited (~p); stopping maintenance",
                                 [Reason]),
            nil = brazier_cluster_ffi:unsubscribe_mutual(self()),
            ok;
        brazier_session_sweep ->
            SweepFun(),
            erlang:send_after(IntervalMs, self(), brazier_session_sweep),
            maintenance_loop(Ref, IntervalMs, SweepFun, RecheckFun);
        {nodeup, Node} ->
            warn_unmanaged(Node),
            maintenance_loop(Ref, IntervalMs, SweepFun, RecheckFun);
        {brazier_cluster_peer_mutual, Node} ->
            Last = drain_mutual(Node),
            run_guarded(recheck, fun() -> RecheckFun(Last) end),
            maintenance_loop(Ref, IntervalMs, SweepFun, RecheckFun);
        {nodedown, _Node} ->
            %% pg drops the remote members itself; nothing to do here.
            maintenance_loop(Ref, IntervalMs, SweepFun, RecheckFun);
        Other ->
            brazier_log_ffi:warning(<<"brazier.session">>,
                                   "Session maintenance got an unexpected message: ~p",
                                   [Other]),
            maintenance_loop(Ref, IntervalMs, SweepFun, RecheckFun)
    end.

%% A connected node is re-checked for once it and this node have verified
%% each other; without a cluster manager that never happens.
warn_unmanaged(Node) ->
    case whereis(brazier_cluster) of
        undefined ->
            brazier_log_ffi:warning(<<"brazier.session">>,
                                   "~p connected, but no cluster manager runs here: revocations "
                                   "are not exchanged with it and no re-check runs until one does",
                                   [Node]);
        _Manager ->
            brazier_log_ffi:debug(<<"brazier.session">>,
                                 "~p connected; re-checking bound sessions once it and this node "
                                 "have verified each other", [Node])
    end.

%% Take the mutual notices already in the mailbox; one re-check covers
%% them all.
drain_mutual(Node) ->
    receive
        {brazier_cluster_peer_mutual, Next} -> drain_mutual(Next)
    after 0 -> Node
    end.

run_guarded(What, Fun) ->
    try
        Fun()
    catch
        Class:Reason:Stack ->
            brazier_log_ffi:error(<<"brazier.session">>,
                                 "Session maintenance task ~p crashed: ~p:~p~n~p",
                                 [What, Class, Reason, Stack])
    end.
