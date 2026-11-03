-module(beacon_ets_ffi).
-export([ensure_table/2, owner_pid/0, put/3, get/2, delete/2, count/1]).

%% SECURITY: Atom creation constraint.
%% Table names come from developer code at compile time, not from runtime user input.
%% The validate_atom_name/1 guard restricts names to alphanumeric/underscore/hyphen
%% (max 255 bytes). Each distinct table creates one atom.
%%
%% OWNERSHIP: an ETS table dies with the process that owns it. Tables created
%% here are owned by a single long-lived, node-wide owner process
%% (`beacon_ets_owner`), not by the caller, so a store created from a request
%% handler, a runtime or a test process survives that process exiting. This is
%% the usual "table owner process" pattern (cf. Elixir/Phoenix tables owned by
%% a GenServer): the owner does nothing except create tables, so it has no
%% reason to crash.
%%
%% IDEMPOTENCE: ensure_table/2 returns the existing table when one with that
%% name already exists and has the requested type; a table of the same name
%% but a different type (or protection) is a typed error, never a silent reuse.

-define(OWNER, beacon_ets_owner).
-define(OWNER_TIMEOUT_MS, 5000).

%% Create a named public ETS table of the Gleam EtsTableType (ets_set |
%% ets_duplicate_bag) owned by the long-lived owner process, or return the
%% existing one.
%% Returns {ok, TableName} | {error, EtsError} where EtsError mirrors the
%% Gleam type beacon/state_manager.EtsError:
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
            case existing_table(Name, AtomName, Type) of
                {ok, _} = Existing -> Existing;
                {error, _} = Mismatch -> Mismatch;
                absent -> create_via_owner(Name, AtomName, Type)
            end;
        {error, Reason} ->
            {error, {invalid_table_name, Name, Reason}}
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

create_via_owner(Name, AtomName, Type) ->
    case ensure_owner() of
        {ok, Owner} ->
            MRef = erlang:monitor(process, Owner),
            Owner ! {beacon_ets_create, self(), MRef, Name, AtomName, Type},
            receive
                {MRef, Result} ->
                    erlang:demonitor(MRef, [flush]),
                    Result;
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
    Parent = self(),
    Ref = make_ref(),
    {Pid, MRef} = spawn_monitor(fun() -> owner_init(Parent, Ref) end),
    receive
        {Ref, registered} ->
            erlang:demonitor(MRef, [flush]),
            beacon_log_ffi:info(<<"beacon.ets">>, "Started ETS table owner ~p", [Pid]),
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
            owner_loop()
    catch
        error:badarg -> exit(already_registered)
    end.

owner_loop() ->
    receive
        {beacon_ets_create, From, MRef, Name, AtomName, Type} ->
            From ! {MRef, owner_create(Name, AtomName, Type)},
            owner_loop();
        Other ->
            beacon_log_ffi:warning(<<"beacon.ets">>, "Table owner discarding unexpected message: ~p", [Other]),
            owner_loop()
    end.

%% Runs in the owner, which serialises creation: re-check for a table created
%% by a concurrent caller between its whereis and its request.
owner_create(Name, AtomName, Type) ->
    case existing_table(Name, AtomName, Type) of
        {ok, _} = Existing ->
            Existing;
        {error, _} = Mismatch ->
            Mismatch;
        absent ->
            try ets:new(AtomName, [Type, public, named_table, {read_concurrency, true}]) of
                AtomName ->
                    beacon_log_ffi:info(<<"beacon.ets">>, "Created ~p table ~p", [Type, AtomName]),
                    {ok, AtomName}
            catch
                error:Reason ->
                    beacon_log_ffi:error(<<"beacon.ets">>, "Failed to create ~p table ~p: ~p",
                                         [Type, AtomName, Reason]),
                    {error, {table_owner_unavailable, Name, format_reason(Reason)}}
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
