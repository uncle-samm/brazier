-module(brazier_ets_ffi).
-export([ensure_table/2, owner_pid/0, put/3, get/2, delete/2, count/1,
         new_owner_tree/0, start_supervised_owner/1, owner_supervised/0]).

%% SECURITY: Atom creation constraint.
%% Table names come from developer code at compile time, not from runtime user input.
%% The validate_atom_name/1 guard restricts names to alphanumeric/underscore/hyphen
%% (max 255 bytes). Each distinct table creates one atom.
%%
%% OWNERSHIP: an ETS table dies with the process that owns it. Tables created
%% here are owned by a single long-lived, node-wide owner process
%% (`brazier_ets_owner`), not by the caller, so a store created from a request
%% handler, a runtime or a test process survives that process exiting. This is
%% the usual "table owner process" pattern (cf. Elixir/Phoenix tables owned by
%% a GenServer): the owner does nothing except create tables, so it has no
%% reason to crash.
%%
%% SUPERVISION: under `application.start_supervised` the owner is the first
%% child of the root tree (start_supervised_owner/1), so no other child's
%% restart takes the tables down with it. Stores are usually created in
%% `main` before the tree starts, by an owner started on demand; the
%% supervised owner adopts that owner's tables (ets:give_away/3) and its
%% name. Stopping the tree stops the owner and deletes its tables. Without a
%% tree (`application.start`, tests) the owner on demand runs until the node
%% stops.
%%
%% LOST TABLES: tables do not survive their owner. A supervised owner that
%% crashes while it owns tables is not restarted empty: the restart fails
%% (the supervisor gives up and the application stops loudly), and from then
%% on this node refuses to create tables on demand until a new tree's owner
%% starts, because every store handle the application holds names a table
%% that is gone. An owner that crashes owning no table restarts normally.
%% A creation in the instant between the crash and the supervisor's restart
%% attempt can still start an owner on demand; the restart then fails all the
%% same, so the application stops either way.
%%
%% IDEMPOTENCE: ensure_table/2 returns the existing table when one with that
%% name already exists and has the requested type; a table of the same name
%% but a different type (or protection) is a typed error, never a silent reuse.

-define(OWNER, brazier_ets_owner).
-define(OWNER_TIMEOUT_MS, 5000).
%% How many times one call follows the owner moving to the supervised one
%% (once per tree start in practice) before it reports the owner unavailable.
-define(MAX_OWNER_MOVES, 3).
%% How many owners on demand the supervised owner adopts before it gives up
%% (each adoption leaves the name free for an instant).
-define(MAX_ADOPTIONS, 10).
%% Set once a supervised owner was lost with tables (see LOST TABLES).
-define(LOST_KEY, {?MODULE, tables_lost}).

%% Create a named public ETS table of the Gleam EtsTableType (ets_set |
%% ets_duplicate_bag) owned by the long-lived owner process, or return the
%% existing one.
%% Returns {ok, TableName} | {error, EtsError} where EtsError mirrors the
%% Gleam type brazier/state_manager.EtsError:
%%   {invalid_table_name, Name, Reason}
%%   {table_type_mismatch, Name, ExpectedType, FoundType}
%%   {table_owner_unavailable, Name, Reason}
ensure_table(Name, ets_set) ->
    ensure_table_of_type(Name, set);
ensure_table(Name, ets_duplicate_bag) ->
    ensure_table_of_type(Name, duplicate_bag).

ensure_table_of_type(Name, Type) ->
    case validate_atom_name(Name) of
        ok ->
            AtomName = binary_to_atom(Name, utf8),
            ensure_existing_or_create(Name, AtomName, Type, ?MAX_OWNER_MOVES);
        {error, Reason} ->
            {error, {invalid_table_name, Name, Reason}}
    end.

ensure_existing_or_create(Name, AtomName, Type, Moves) ->
    case existing_table(Name, AtomName, Type) of
        {ok, _} = Existing -> Existing;
        {error, _} = Mismatch -> Mismatch;
        absent -> create_via_owner(Name, AtomName, Type, Moves)
    end.

%% Pid of the table owner process (starting it if necessary). Exposed for
%% tests that assert ownership.
owner_pid() ->
    ensure_owner().

existing_table(Name, AtomName, Type) ->
    case ets:whereis(AtomName) of
        undefined ->
            absent;
        _Tid ->
            FoundType = ets:info(AtomName, type),
            FoundProtection = ets:info(AtomName, protection),
            case {FoundType, FoundProtection} of
                {Type, public} ->
                    {ok, AtomName};
                {undefined, _} ->
                    %% Deleted between whereis and info: treat as absent and
                    %% let the owner (which serialises creation) decide.
                    absent;
                {_, public} ->
                    {error, {table_type_mismatch, Name, atom_to_binary(Type, utf8),
                             atom_to_binary(FoundType, utf8)}};
                {_, Other} ->
                    {error, {table_type_mismatch, Name, atom_to_binary(Type, utf8),
                             <<(atom_to_binary(FoundType, utf8))/binary, " (",
                               (atom_to_binary(Other, utf8))/binary, ")">>}}
            end
    end.

create_via_owner(Name, AtomName, Type, Moves) ->
    case ensure_owner() of
        {ok, Owner} ->
            MRef = erlang:monitor(process, Owner),
            Owner ! {brazier_ets_create, self(), MRef, Name, AtomName, Type},
            receive
                {MRef, Result} ->
                    erlang:demonitor(MRef, [flush]),
                    Result;
                {'DOWN', MRef, process, _, {brazier_ets_owner_moved, _}} when Moves > 0 ->
                    %% The request reached an owner on demand just as the
                    %% supervised owner adopted it: ask the new owner.
                    brazier_log_ffi:debug(<<"brazier.ets">>,
                                         "Table owner moved while creating ~p, asking again",
                                         [AtomName]),
                    ensure_existing_or_create(Name, AtomName, Type, Moves - 1);
                {'DOWN', MRef, process, _, noproc} when Moves > 0 ->
                    %% The owner the lookup found was gone before the
                    %% monitor was taken: it moved to the supervised owner
                    %% (hand_over/2 gives up the name before it exits) or
                    %% died. The request reached no one, so look the owner
                    %% up again, as a call made a moment later would.
                    brazier_log_ffi:info(<<"brazier.ets">>,
                                        "Table owner ~p was gone before the creation of ~p "
                                        "monitored it (it moved or died), asking again",
                                        [Owner, AtomName]),
                    ensure_existing_or_create(Name, AtomName, Type, Moves - 1);
                {'DOWN', MRef, process, _, Reason} ->
                    {error, {table_owner_unavailable, Name, format_reason(Reason)}}
            after ?OWNER_TIMEOUT_MS ->
                erlang:demonitor(MRef, [flush]),
                {error, {table_owner_unavailable, Name, <<"owner did not reply within 5000ms">>}}
            end;
        {error, Reason} ->
            {error, {table_owner_unavailable, Name, Reason}}
    end.

%% Start the owner if it is not running. Concurrent starters race on
%% register/2; exactly one wins and the losers use the winner.
ensure_owner() ->
    case whereis(?OWNER) of
        undefined -> start_owner();
        Pid -> {ok, Pid}
    end.

start_owner() ->
    case persistent_term:get(?LOST_KEY, false) of
        false ->
            start_owner_on_demand();
        Lost ->
            Reason = iolist_to_binary(io_lib:format(
                "the supervised ETS table owner crashed owning ~p table(s); "
                "their data is gone, so no table is created until the "
                "application restarts", [Lost])),
            brazier_log_ffi:error(<<"brazier.ets">>, "Refusing to start a table owner: ~ts",
                                 [Reason]),
            {error, Reason}
    end.

start_owner_on_demand() ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, MRef} = spawn_monitor(fun() -> owner_init(Parent, Ref) end),
    receive
        {Ref, registered} ->
            erlang:demonitor(MRef, [flush]),
            brazier_log_ffi:info(<<"brazier.ets">>, "Started ETS table owner ~p", [Pid]),
            {ok, Pid};
        {'DOWN', MRef, process, Pid, already_registered} ->
            case whereis(?OWNER) of
                undefined -> start_owner();
                Winner -> {ok, Winner}
            end;
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, format_reason(Reason)}
    after ?OWNER_TIMEOUT_MS ->
        erlang:demonitor(MRef, [flush]),
        exit(Pid, kill),
        {error, <<"owner did not start within 5000ms">>}
    end.

owner_init(Parent, Ref) ->
    try register(?OWNER, self()) of
        true ->
            Parent ! {Ref, registered},
            owner_loop(on_demand)
    catch
        error:badarg -> exit(already_registered)
    end.

%% Mode is `on_demand` for an owner started by ensure_table, or
%% {supervised, Owned} for the tree's owner, where Owned is the atomics
%% counter of the tables it owns (read by start_supervised_owner/1 when the
%% supervisor restarts it).
owner_loop(Mode) ->
    receive
        {brazier_ets_create, From, MRef, Name, AtomName, Type} ->
            From ! {MRef, owner_create(Name, AtomName, Type, Mode)},
            owner_loop(Mode);
        {brazier_ets_handoff, New, Ref} when Mode =:= on_demand ->
            hand_over(New, Ref);
        {brazier_ets_handoff, New, Ref} ->
            New ! {Ref, {refused, <<"the table owner already belongs to a supervision tree">>}},
            owner_loop(Mode);
        {brazier_ets_supervised, From, Ref} ->
            From ! {Ref, Mode =/= on_demand},
            owner_loop(Mode);
        Other ->
            brazier_log_ffi:warning(<<"brazier.ets">>, "Table owner discarding unexpected message: ~p", [Other]),
            owner_loop(Mode)
    end.

%% Runs in the owner, which serialises creation: re-check for a table created
%% by a concurrent caller between its whereis and its request.
owner_create(Name, AtomName, Type, Mode) ->
    case existing_table(Name, AtomName, Type) of
        {ok, _} = Existing ->
            Existing;
        {error, _} = Mismatch ->
            Mismatch;
        absent ->
            try ets:new(AtomName, [Type, public, named_table, {read_concurrency, true}]) of
                AtomName ->
                    count_owned(Mode),
                    brazier_log_ffi:info(<<"brazier.ets">>, "Created ~p table ~p", [Type, AtomName]),
                    {ok, AtomName}
            catch
                error:Reason ->
                    brazier_log_ffi:error(<<"brazier.ets">>, "Failed to create ~p table ~p: ~p",
                                         [Type, AtomName, Reason]),
                    {error, {table_owner_unavailable, Name, format_reason(Reason)}}
            end
    end.

count_owned(on_demand) -> ok;
count_owned({supervised, Owned}) -> atomics:add(Owned, 1, 1).

%% Runs in an owner on demand that the supervised owner New adopts: give up
%% the name, finish the creations already queued here, give every table to
%% New and exit. A creation sent here after that sees the owner moved, or
%% gone (noproc) when it monitors after the exit, and asks again
%% (create_via_owner/4).
hand_over(New, Ref) ->
    true = unregister(?OWNER),
    drain_creates(),
    Tables = owned_tables(),
    lists:foreach(fun(Table) -> true = ets:give_away(Table, New, brazier_ets_handoff) end,
                  Tables),
    New ! {Ref, {handed_over, Tables}},
    brazier_log_ffi:info(<<"brazier.ets">>, "Table owner ~p handed ~p table(s) to ~p",
                        [self(), length(Tables), New]),
    exit({brazier_ets_owner_moved, New}).

drain_creates() ->
    receive
        {brazier_ets_create, From, MRef, Name, AtomName, Type} ->
            From ! {MRef, owner_create(Name, AtomName, Type, on_demand)},
            drain_creates()
    after 0 ->
        ok
    end.

owned_tables() ->
    Self = self(),
    [Table || Table <- ets:all(), ets:info(Table, owner) =:= Self].

%% The counter of the tables a tree's owner holds, shared by every start of
%% that tree's owner child (application.start_supervised makes one per tree).
new_owner_tree() ->
    atomics:new(1, []).

%% The root tree's owner child. Runs in the supervisor: starts the owner
%% linked to it, or refuses when the previous one died owning tables.
%% {ok, Pid} | {error, ReasonBin}.
start_supervised_owner(Owned) ->
    case atomics:get(Owned, 1) of
        0 ->
            spawn_supervised_owner(Owned);
        Lost ->
            %% Creation on demand is refused from now on too: the stores
            %% the application holds name tables that no longer exist.
            persistent_term:put(?LOST_KEY, Lost),
            Reason = iolist_to_binary(io_lib:format(
                "the ETS table owner crashed owning ~p table(s), whose data is "
                "gone; it is not restarted empty, so the application must "
                "restart", [Lost])),
            brazier_log_ffi:error(<<"brazier.ets">>, "~ts", [Reason]),
            {error, Reason}
    end.

spawn_supervised_owner(Owned) ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn_link(fun() -> supervised_init(Parent, Ref, Owned) end),
    receive
        {Ref, ok} ->
            brazier_log_ffi:info(<<"brazier.ets">>, "Started supervised ETS table owner ~p", [Pid]),
            clear_lost(),
            {ok, Pid};
        {Ref, {error, Reason}} ->
            unlink_and_flush(Pid),
            brazier_log_ffi:error(<<"brazier.ets">>, "Supervised ETS table owner did not start: ~ts",
                                 [Reason]),
            {error, Reason}
    after ?OWNER_TIMEOUT_MS ->
        unlink_and_flush(Pid),
        exit(Pid, kill),
        Reason = <<"the supervised ETS table owner did not start within 5000ms">>,
        brazier_log_ffi:error(<<"brazier.ets">>, "~ts", [Reason]),
        {error, Reason}
    end.

%% A supervised owner that starts belongs to a tree that holds no lost
%% table (a lost tree never restarts its owner), so it is the application
%% restart that LOST TABLES waits for: tables may be created again.
clear_lost() ->
    case persistent_term:get(?LOST_KEY, false) of
        false ->
            ok;
        Lost ->
            true = persistent_term:erase(?LOST_KEY),
            brazier_log_ffi:info(<<"brazier.ets">>,
                                "A new tree's table owner started; creating tables again "
                                "after ~p table(s) were lost", [Lost])
    end.

%% The caller (a supervisor) traps exits: drop the EXIT of a child that
%% failed to start, which is answered with an error instead.
unlink_and_flush(Pid) ->
    unlink(Pid),
    receive
        {'EXIT', Pid, _} -> ok
    after 0 ->
        ok
    end.

supervised_init(Parent, Ref, Owned) ->
    case adopt(?MAX_ADOPTIONS, 0) of
        {ok, Adopted} ->
            atomics:put(Owned, 1, Adopted),
            Parent ! {Ref, ok},
            owner_loop({supervised, Owned});
        {error, Reason} ->
            Parent ! {Ref, {error, Reason}}
    end.

%% Take the owner name, adopting the tables of the owner on demand that
%% holds it. {ok, TablesOwned} | {error, ReasonBin}.
adopt(0, _Adopted) ->
    {error, <<"owners on demand kept taking the table owner name">>};
adopt(Attempts, Adopted) ->
    case whereis(?OWNER) of
        undefined ->
            try register(?OWNER, self()) of
                true -> {ok, Adopted}
            catch
                error:badarg -> adopt(Attempts - 1, Adopted)
            end;
        Old ->
            MRef = erlang:monitor(process, Old),
            Old ! {brazier_ets_handoff, self(), MRef},
            receive
                {MRef, {handed_over, Tables}} ->
                    erlang:demonitor(MRef, [flush]),
                    lists:foreach(fun(Table) -> await_transfer(Table, Old) end, Tables),
                    adopt(Attempts - 1, Adopted + length(Tables));
                {MRef, {refused, Reason}} ->
                    erlang:demonitor(MRef, [flush]),
                    {error, Reason};
                {'DOWN', MRef, process, Old, _} ->
                    %% Gone before it answered: take the name if it is free.
                    adopt(Attempts - 1, Adopted)
            after ?OWNER_TIMEOUT_MS ->
                erlang:demonitor(MRef, [flush]),
                {error, <<"the table owner on demand did not hand over within 5000ms">>}
            end
    end.

%% give_away/3 sends the new owner one 'ETS-TRANSFER' message per table;
%% take each, so the owner's mailbox holds only requests.
await_transfer(Table, Old) ->
    receive
        {'ETS-TRANSFER', Table, Old, brazier_ets_handoff} -> ok
    after ?OWNER_TIMEOUT_MS ->
        erlang:error({ets_transfer_missing, Table, Old})
    end.

%% Whether the running owner belongs to a supervision tree. Exposed for
%% tests. {ok, Bool} | {error, nil} when no owner runs.
owner_supervised() ->
    case whereis(?OWNER) of
        undefined -> {error, nil};
        Owner ->
            MRef = erlang:monitor(process, Owner),
            Owner ! {brazier_ets_supervised, self(), MRef},
            receive
                {MRef, Supervised} ->
                    erlang:demonitor(MRef, [flush]),
                    {ok, Supervised};
                {'DOWN', MRef, process, _, _} ->
                    {error, nil}
            after ?OWNER_TIMEOUT_MS ->
                erlang:demonitor(MRef, [flush]),
                erlang:error({table_owner_unresponsive, Owner})
            end
    end.

format_reason(Reason) when is_binary(Reason) -> Reason;
format_reason(Reason) -> unicode:characters_to_binary(io_lib:format("~0p", [Reason])).

%% Validate that a name is safe for atom conversion.
%% Max 255 bytes, alphanumeric + underscore + hyphen only (no spaces, no special chars).
%% This prevents atom table exhaustion from arbitrary user-controlled input.
validate_atom_name(Name) when not is_binary(Name) ->
    {error, <<"Invalid name: must be a string">>};
validate_atom_name(Name) when byte_size(Name) > 255 ->
    {error, <<"Name too long (max 255 bytes)">>};
validate_atom_name(Name) ->
    case re:run(Name, <<"^[a-zA-Z0-9_-]+$">>) of
        {match, _} -> ok;
        nomatch -> {error, <<"Invalid name: must be alphanumeric, underscore, or hyphen">>}
    end.

%% Store a key-value pair in the ETS table.
put(Table, Key, Value) ->
    ets:insert(Table, {Key, Value}),
    nil.

%% Retrieve a value from the ETS table. Returns {ok, Value} or {error, nil}.
get(Table, Key) ->
    case ets:lookup(Table, Key) of
        [{_, Value}] -> {ok, Value};
        [] -> {error, nil}
    end.

%% Delete a key from the ETS table.
delete(Table, Key) ->
    ets:delete(Table, Key),
    nil.

%% Count the number of entries in the ETS table.
count(Table) ->
    ets:info(Table, size).
