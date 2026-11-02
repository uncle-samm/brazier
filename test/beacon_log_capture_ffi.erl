%% Captures the log events the calling process emits while a function runs.
%%
%% The test runner sets the primary logger level to `none`. `capture/1`
%% raises it to `all` for the duration of the call, installs a handler that
%% forwards only events logged by the calling process, and restores the
%% previous level and removes the handler afterwards, even when the function
%% crashes. Handlers run in the logging process, so every event is in the
%% mailbox by the time the function returns.
-module(beacon_log_capture_ffi).
-export([capture/1, log/2]).

capture(Fun) ->
    Id = list_to_atom(
        "beacon_log_capture_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    #{level := PreviousLevel} = logger:get_primary_config(),
    ok = logger:add_handler(Id, ?MODULE, #{
        level => all,
        filter_default => log,
        filters => [],
        config => #{target => self()}
    }),
    ok = logger:set_primary_config(level, all),
    Result =
        try
            Fun()
        after
            ok = logger:set_primary_config(level, PreviousLevel),
            ok = logger:remove_handler(Id)
        end,
    {Result, drain(Id, [])}.

%% logger handler callback.
log(#{level := Level, msg := Msg, meta := Meta}, #{id := Id, config := #{target := Target}}) ->
    case maps:get(pid, Meta, undefined) of
        Target -> Target ! {beacon_captured_log, Id, atom_to_binary(Level), format(Msg)};
        _ -> ok
    end,
    ok.

drain(Id, Acc) ->
    receive
        {beacon_captured_log, Id, Level, Text} -> drain(Id, [{Level, Text} | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

format({string, Chardata}) ->
    unicode:characters_to_binary(Chardata);
format({report, Report}) ->
    unicode:characters_to_binary(io_lib:format("~p", [Report]));
format({Format, Args}) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).
