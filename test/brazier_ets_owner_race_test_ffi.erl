-module(brazier_ets_owner_race_test_ffi).

%% Helpers for ets_owner_race_test: hold a table creation between its owner
%% lookup and its monitor.
%%
%% brazier_ets_ffi:create_via_owner/4 looks the owner up (ensure_owner/0)
%% and then monitors it. When no owner runs, the lookup starts one on demand
%% and logs "Started ETS table owner" in the creating process, after the new
%% owner registered and before the creation monitors it. A logger handler
%% runs in the process that logs, so the handler here blocks the creator at
%% that line until the test releases it: in between, the test moves the
%% owner or kills it. Nothing sleeps; the hold is one message each way.
%%
%% Only for a fresh peer node: it raises the primary log level and removes
%% the node's default handler.

-export([hold_first_owner_start/0, await_held/1, release/1, lines/1, table_owner/1,
         moved_to/1, log/2]).

-define(HANDLER, brazier_ets_owner_race).
-define(HELD_LINE, <<"[brazier.ets] Started ETS table owner">>).
-define(TIMEOUT_MS, 5000).

%% Install the hold for the first "Started ETS table owner" line; later
%% starts are not held. Every brazier.ets line is forwarded to the caller,
%% tagged with the pid that logged it (see lines/1).
hold_first_owner_start() ->
    case logger:remove_handler(default) of
        ok -> ok;
        {error, {not_found, default}} -> ok
    end,
    ok = logger:set_primary_config(level, all),
    Config = #{test => self(), once => atomics:new(1, [])},
    ok = logger:add_handler(?HANDLER, ?MODULE, #{level => all, config => Config}),
    nil.

%% Logger handler callback: runs in the process that logs.
log(#{msg := {string, Text}, meta := #{brazier_context := <<"brazier.ets">>}},
    #{config := #{test := Test, once := Once}}) ->
    Line = unicode:characters_to_binary(Text),
    Test ! {brazier_ets_race_line, self(), Line},
    case binary:match(Line, ?HELD_LINE) of
        {0, _} ->
            case atomics:compare_exchange(Once, 1, 0, 1) of
                ok -> hold(Test);
                _AlreadyHeld -> ok
            end;
        nomatch ->
            ok
    end;
log(_Event, _Config) ->
    ok.

hold(Test) ->
    Test ! {brazier_ets_race_held, self()},
    receive
        brazier_ets_race_release -> ok
    after ?TIMEOUT_MS ->
        erlang:error({brazier_ets_race_not_released, self()})
    end.

%% Wait until Creator is held, and return the owner its lookup found (the
%% registered owner: nothing else can take the name while the test holds
%% the only creator).
await_held(Creator) ->
    receive
        {brazier_ets_race_held, Creator} ->
            case whereis(brazier_ets_owner) of
                Owner when is_pid(Owner) -> Owner;
                undefined -> erlang:error(brazier_ets_race_no_owner_while_held)
            end
    after ?TIMEOUT_MS ->
        erlang:error({brazier_ets_race_not_held, Creator})
    end.

release(Creator) ->
    Creator ! brazier_ets_race_release,
    nil.

%% Every brazier.ets line forwarded so far, oldest first: Pid's lines are
%% returned, every other process's are dropped. Call it after the creation
%% returned: a handler forwards a line before its process goes on.
lines(Pid) ->
    lines(Pid, []).

lines(Pid, Acc) ->
    receive
        {brazier_ets_race_line, Pid, Line} -> lines(Pid, [Line | Acc]);
        {brazier_ets_race_line, _Other, _Line} -> lines(Pid, Acc)
    after 0 ->
        lists:reverse(Acc)
    end.

table_owner(Table) ->
    case ets:info(Table, owner) of
        Owner when is_pid(Owner) -> Owner;
        undefined -> erlang:error({brazier_ets_race_no_table, Table})
    end.

%% The owner an exit reason says the table owner moved to.
moved_to({abnormal, {brazier_ets_owner_moved, To}}) when is_pid(To) -> {ok, To};
moved_to(_Reason) -> {error, nil}.
