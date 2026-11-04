-module(brazier_session_test_ffi).
%% Test helpers for session backends.
%%
%% A "database" is a named ETS table owned by a long-lived process on one
%% node (start_db/1). backend/2 builds a brazier/session ExternalBackend whose
%% operations erpc to that node, so stores on several nodes share one
%% database the way they would share Postgres. set_failing/3 makes every
%% operation return an error.
%%
%% Bound processes (spawn_bound/1) record every revocation they receive in a
%% per-node table read back with revocations/0, and also tell the process
%% that spawned them, so a test on the same node waits for one with
%% await_revoked/4 instead of polling the table.
-export([start_db/1, backend/2, set_failing/3, owned/1, spawn_bound/1,
         revocations/0, await_revoked/4, bound_everywhere/2, raises/1,
         system_now/0,
         db_create/2, db_fetch/2, db_touch/3, db_replace/3, db_delete/2,
         db_delete_version/3, db_expired/4, db_count/1]).

-define(REVOKED, brazier_session_test_revoked).
-define(RPC_TIMEOUT_MS, 5000).
-define(REPLY_TIMEOUT_MS, 5000).

%% --- Database ---

table(Name) ->
    binary_to_atom(<<"brazier_session_test_db_", Name/binary>>, utf8).

start_db(Name) ->
    Table = table(Name),
    owned(fun() ->
        Table = ets:new(Table, [set, public, named_table]),
        nil
    end).

set_failing(Node, Name, Failing) ->
    ok = erpc:call(Node, persistent_term, put, [{?MODULE, failing, table(Name)}, Failing],
                   ?RPC_TIMEOUT_MS),
    nil.

%% The Gleam ExternalBackend record.
backend(Name, Node) ->
    Table = table(Name),
    Call = fun(Op, Args) -> remote(Node, Table, Op, Args) end,
    {external_backend, Name,
     fun(Row) -> Call(db_create, [Row]) end,
     fun(Id) -> Call(db_fetch, [Id]) end,
     fun(Id, Now) -> Call(db_touch, [Id, Now]) end,
     fun(Row, Expected) -> Call(db_replace, [Row, Expected]) end,
     fun(Id) -> Call(db_delete, [Id]) end,
     fun(Id, Version) -> Call(db_delete_version, [Id, Version]) end,
     fun(Abs, Idle, Limit) -> Call(db_expired, [Abs, Idle, Limit]) end,
     fun() -> Call(db_count, []) end}.

%% An unreachable database is a backend error, as a lost Postgres
%% connection would be.
remote(Node, Table, Op, Args) ->
    try erpc:call(Node, ?MODULE, Op, [Table | Args], ?RPC_TIMEOUT_MS)
    catch
        Class:Reason ->
            {error, unicode:characters_to_binary(
                      io_lib:format("~p ~p: ~p", [Op, Class, Reason]))}
    end.

failing(Table) ->
    persistent_term:get({?MODULE, failing, Table}, false).

guarded(Table, Fun) ->
    case failing(Table) of
        true -> {error, <<"injected failure">>};
        false -> {ok, Fun()}
    end.

row_id({stored_session, {session, Id, _Data}, _V, _C, _L}) -> Id.

db_create(Table, Row) ->
    guarded(Table, fun() -> ets:insert_new(Table, {row_id(Row), Row}) end).

db_fetch(Table, Id) ->
    guarded(Table, fun() ->
        case ets:lookup(Table, Id) of
            [{_, Row}] -> {some, Row};
            [] -> none
        end
    end).

db_touch(Table, Id, Now) ->
    guarded(Table, fun() ->
        Spec = [{{Id, {stored_session, '$1', '$2', '$3', '_'}}, [],
                 [{{Id, {{stored_session, '$1', '$2', '$3', {const, Now}}}}}]}],
        ets:select_replace(Table, Spec) =:= 1
    end).

db_replace(Table, Row, Expected) ->
    guarded(Table, fun() ->
        Id = row_id(Row),
        Spec = [{{Id, {stored_session, '_', Expected, '_', '_'}}, [],
                 [{const, {Id, Row}}]}],
        ets:select_replace(Table, Spec) =:= 1
    end).

db_delete(Table, Id) ->
    guarded(Table, fun() -> true = ets:delete(Table, Id), nil end).

db_delete_version(Table, Id, Version) ->
    guarded(Table, fun() ->
        ets:select_delete(Table, [{{Id, {stored_session, '_', Version, '_', '_'}},
                                   [], [true]}]) =:= 1
    end).

db_expired(Table, Abs, Idle, Limit) ->
    guarded(Table, fun() ->
        Spec = [{{'$1', {stored_session, '_', '$2', '$3', '$4'}},
                 [{'orelse', {'=<', '$3', Abs}, {'=<', '$4', Idle}}],
                 [{{'$1', '$2'}}]}],
        case ets:select(Table, Spec, Limit) of
            {Rows, _} -> Rows;
            '$end_of_table' -> []
        end
    end).

db_count(Table) ->
    guarded(Table, fun() -> ets:info(Table, size) end).

%% --- Owners and bound processes ---

%% Run Fun in a new unlinked process that stays alive afterwards (until the
%% node stops), and return Fun's result. Stores and tables created by Fun
%% are owned by that process, so they outlive the rpc that created them.
owned(Fun) ->
    Parent = self(),
    Ref = make_ref(),
    %% spawn_monitor: a Fun that crashes at once reports its own reason,
    %% never noproc.
    {Pid, MRef} = spawn_monitor(fun() ->
        Parent ! {Ref, Fun()},
        receive stop -> ok end
    end),
    receive
        {Ref, Result} ->
            erlang:demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, Pid, Reason} ->
            erlang:error({owner_crashed, Reason})
    after ?REPLY_TIMEOUT_MS ->
        erlang:error(owner_timeout)
    end.

ensure_revoked_table() ->
    case ets:whereis(?REVOKED) of
        undefined ->
            owned(fun() ->
                ?REVOKED = ets:new(?REVOKED, [bag, public, named_table]),
                nil
            end);
        _ -> nil
    end.

%% A process that runs Bind (which binds it to a session) and then records
%% every revocation it receives. Returns once Bind has run.
spawn_bound(Bind) ->
    ensure_revoked_table(),
    Parent = self(),
    Ref = make_ref(),
    {Pid, MRef} = spawn_monitor(fun() ->
        nil = Bind(),
        Parent ! {Ref, bound},
        bound_loop(Parent)
    end),
    receive
        {Ref, bound} ->
            erlang:demonitor(MRef, [flush]),
            Pid;
        {'DOWN', MRef, process, Pid, Reason} ->
            erlang:error({bind_crashed, Reason})
    after ?REPLY_TIMEOUT_MS ->
        erlang:error(bind_timeout)
    end.

%% Parent may be an erpc worker that has already exited (a bound process
%% spawned on a peer node); a send to it is then dropped, and the table is
%% what such tests read.
bound_loop(Parent) ->
    receive
        {brazier_session_revoked, Id, Reason} ->
            true = ets:insert(?REVOKED, {Id, Reason}),
            Parent ! {brazier_session_test_revoked, self(), Id, Reason},
            bound_loop(Parent);
        stop ->
            ok
    end.

revocations() ->
    ensure_revoked_table(),
    lists:sort(ets:tab2list(?REVOKED)).

%% Wait for the bound process Pid (spawned by the caller) to receive the
%% revocation {Id, Reason}: {ok, nil}, or {error, Others} with the other
%% revocations Pid reported before the deadline. Only Pid's reports match,
%% so a revocation recorded by an earlier test never satisfies this one.
await_revoked(Pid, Id, Reason, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    await_revoked(Pid, Id, Reason, Deadline, []).

await_revoked(Pid, Id, Reason, Deadline, Others) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {brazier_session_test_revoked, Pid, Id, Reason} ->
            {ok, nil};
        {brazier_session_test_revoked, Pid, OtherId, OtherReason} ->
            await_revoked(Pid, Id, Reason, Deadline,
                          [{OtherId, OtherReason} | Others])
    after Remaining ->
        {error, lists:reverse(Others)}
    end.

%% Bound processes for a session on every node this node sees.
bound_everywhere(Namespace, Id) ->
    length(pg:get_members(brazier_session_pg, {brazier_session, Namespace, Id})).

%% Whether Fun raises (any class).
raises(Fun) ->
    try Fun() of
        _ -> false
    catch
        _:_ -> true
    end.

system_now() ->
    erlang:system_time(millisecond).
