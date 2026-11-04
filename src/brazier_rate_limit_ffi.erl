-module(brazier_rate_limit_ffi).
%% Fixed-window rate limiter backed by a public ETS table.
%%
%% Each limiter has an owner gen_server that creates and owns the table, so
%% the table lives exactly as long as the owner. The owner is linked to the
%% process that called start/3 (an owner crash is loud) and monitors it (the
%% owner stops, freeing the table, when its creator exits for any reason,
%% including normally).
%%
%% Memory is bounded two ways:
%%   * the owner sweeps every window and deletes counters of past windows;
%%   * a hard cap on live counters: when the table holds MaxKeys entries a
%%     request from a key without a counter is refused (fail closed) instead
%%     of growing the table. Refusals are counted and the owner logs the
%%     total at error level on every sweep that saw any.
%%
%% Handle shape (opaque to Gleam): {brazier_rate_limiter, Tab, Owner, Refusals}.
%%
%% SECURITY: Atom creation constraint.
%% Rate limiter names come from developer code, not from runtime user input.
%% validate_name/1 restricts names to alphanumeric/underscore/hyphen
%% (max 255 bytes). Each distinct limiter creates one atom.
-behaviour(gen_server).

-export([start/3, increment/3, delete_key/2, key_count/1, owner/1, sweep_now/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(START_TIMEOUT_MS, 5000).

%% Start a limiter owner. Returns {ok, Handle} | {error, Reason}.
start(Name, WindowSeconds, MaxKeys)
        when is_binary(Name), is_integer(WindowSeconds), WindowSeconds > 0,
             is_integer(MaxKeys), MaxKeys > 0 ->
    case validate_name(Name) of
        {error, Reason} ->
            {error, Reason};
        ok ->
            TabName = binary_to_atom(<<"brazier_rl_", Name/binary>>, utf8),
            Refusals = counters:new(1, [write_concurrency]),
            %% gen_server:start (not start_link) so a refused init is
            %% returned as an error instead of an exit signal; the owner is
            %% linked to the caller once it is running.
            case gen_server:start(?MODULE, {TabName, WindowSeconds, Refusals, self()},
                                  [{timeout, ?START_TIMEOUT_MS}]) of
                {ok, Owner} ->
                    true = link(Owner),
                    {ok, {brazier_rate_limiter, TabName, Owner, Refusals}};
                {error, {already_exists, _}} ->
                    {error, <<"a rate limiter named ", Name/binary,
                              " already exists">>};
                {error, Other} ->
                    {error, format("rate limiter owner failed to start: ~p",
                                   [Other])}
            end
    end;
start(_Name, WindowSeconds, MaxKeys) ->
    {error, format("invalid rate limiter settings: window_seconds=~p max_keys=~p",
                   [WindowSeconds, MaxKeys])}.

%% Count one request for Key in the current window.
%% Returns {ok, Count} | {error, {at_capacity, Refused}} | {error, limiter_down}.
increment({brazier_rate_limiter, Tab, _Owner, Refusals}, Key, {WindowSeconds, MaxKeys}) ->
    CounterKey = {Key, current_window(WindowSeconds)},
    try ets:update_counter(Tab, CounterKey, {2, 1}) of
        Count -> {ok, Count}
    catch
        error:badarg ->
            case ets:info(Tab, size) of
                undefined ->
                    {error, limiter_down};
                Size when Size >= MaxKeys ->
                    ok = counters:add(Refusals, 1, 1),
                    {error, {at_capacity, counters:get(Refusals, 1)}};
                _ ->
                    %% Default object makes the insert atomic with respect to
                    %% concurrent first requests for the same key.
                    try ets:update_counter(Tab, CounterKey, {2, 1}, {CounterKey, 0}) of
                        Count -> {ok, Count}
                    catch
                        error:badarg -> {error, limiter_down}
                    end
            end
    end.

%% Delete every window counter of Key.
delete_key({brazier_rate_limiter, Tab, _Owner, _Refusals}, Key) ->
    try ets:match_delete(Tab, {{Key, '_'}, '_'}) of
        true -> {ok, nil}
    catch
        error:badarg -> {error, nil}
    end.

%% Number of live counters, or {error, nil} when the owner is gone.
key_count({brazier_rate_limiter, Tab, _Owner, _Refusals}) ->
    case ets:info(Tab, size) of
        undefined -> {error, nil};
        Size -> {ok, Size}
    end.

owner({brazier_rate_limiter, _Tab, Owner, _Refusals}) ->
    Owner.

%% Run a sweep synchronously (tests and operators). Returns the number of
%% counters deleted, or {error, nil} when the owner is gone.
sweep_now({brazier_rate_limiter, _Tab, Owner, _Refusals}) ->
    try gen_server:call(Owner, sweep, ?START_TIMEOUT_MS) of
        Deleted -> {ok, Deleted}
    catch
        exit:_ -> {error, nil}
    end.

%% --- Owner ---

init({TabName, WindowSeconds, Refusals, Creator}) ->
    case ets:whereis(TabName) of
        undefined ->
            Tab = ets:new(TabName, [set, public, named_table,
                                    {write_concurrency, true},
                                    {read_concurrency, true}]),
            schedule_sweep(WindowSeconds),
            _Ref = erlang:monitor(process, Creator),
            brazier_log_ffi:info(<<"brazier.rate_limit">>, "owner started table=~p window=~ps",
                                [TabName, WindowSeconds]),
            {ok, #{tab => Tab, window => WindowSeconds, refusals => Refusals}};
        _Existing ->
            {stop, {already_exists, TabName}}
    end.

handle_call(sweep, _From, State) ->
    {reply, sweep(State), State};
handle_call(Other, From, State) ->
    brazier_log_ffi:error(<<"brazier.rate_limit">>, "unexpected call ~p from ~p", [Other, From]),
    {reply, {error, unexpected_call}, State}.

handle_cast(Other, State) ->
    brazier_log_ffi:error(<<"brazier.rate_limit">>, "unexpected cast ~p", [Other]),
    {noreply, State}.

handle_info(sweep, State = #{window := WindowSeconds}) ->
    _Deleted = sweep(State),
    schedule_sweep(WindowSeconds),
    {noreply, State};
handle_info({'DOWN', _Ref, process, Creator, Reason}, State = #{tab := Tab}) ->
    brazier_log_ffi:info(<<"brazier.rate_limit">>, "owner of ~p stopping: creator ~p exited (~p)",
                        [Tab, Creator, Reason]),
    {stop, normal, State};
handle_info(Other, State) ->
    brazier_log_ffi:warning(<<"brazier.rate_limit">>, "unexpected message ~p", [Other]),
    {noreply, State}.

%% Delete counters of windows before the current one and report refusals.
sweep(#{tab := Tab, window := WindowSeconds, refusals := Refusals}) ->
    Current = current_window(WindowSeconds),
    Deleted = ets:select_delete(Tab, [{{{'_', '$1'}, '_'}, [{'<', '$1', Current}], [true]}]),
    Refused = counters:get(Refusals, 1),
    case Refused of
        0 -> ok;
        _ ->
            ok = counters:sub(Refusals, 1, Refused),
            brazier_log_ffi:error(<<"brazier.rate_limit">>, "table ~p hit its key cap: refused ~p "
                                 "requests from new clients since the last sweep",
                                 [Tab, Refused])
    end,
    case Deleted of
        0 -> ok;
        _ -> brazier_log_ffi:debug(<<"brazier.rate_limit">>, "swept ~p expired counters from ~p",
                                  [Deleted, Tab])
    end,
    Deleted.

schedule_sweep(WindowSeconds) ->
    erlang:send_after(WindowSeconds * 1000, self(), sweep).

current_window(WindowSeconds) ->
    erlang:system_time(second) div WindowSeconds.

validate_name(Name) when byte_size(Name) > 255 ->
    {error, <<"Name too long (max 255 bytes)">>};
validate_name(Name) ->
    case re:run(Name, <<"^[a-zA-Z0-9_-]+$">>) of
        {match, _} -> ok;
        nomatch -> {error, <<"Invalid name: must be alphanumeric, underscore, or hyphen">>}
    end.

format(Fmt, Args) ->
    unicode:characters_to_binary(io_lib:format(Fmt, Args)).
