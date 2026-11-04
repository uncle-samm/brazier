-module(brazier_log_capture_ffi).
%% Capture logger output produced while a function runs, for tests that
%% assert a warning or error was logged. The test runner sets the primary
%% level to `none`; capture raises it for the duration of the call and
%% restores it afterwards, even when the function crashes.
-export([capture/1, log/2]).

capture(Fun) ->
    Id = list_to_atom("brazier_log_capture_" ++ integer_to_list(erlang:unique_integer([positive]))),
    #{level := PreviousLevel} = logger:get_primary_config(),
    ok = logger:add_handler(Id, ?MODULE, #{level => all, config => #{pid => self(), id => Id}}),
    ok = logger:set_primary_config(level, all),
    Result = try
        Fun()
    after
        ok = logger:set_primary_config(level, PreviousLevel),
        ok = logger:remove_handler(Id)
    end,
    {Result, collect(Id, [])}.

%% Logger handler callback: runs in the logging process.
log(#{level := Level, msg := Msg, meta := Meta}, #{config := #{pid := Pid, id := Id}}) ->
    Pid ! {brazier_captured_log, Id, {atom_to_binary(Level, utf8), format(Msg, Meta)}},
    ok.

collect(Id, Acc) ->
    receive
        {brazier_captured_log, Id, Entry} -> collect(Id, [Entry | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

format({string, String}, _Meta) ->
    unicode:characters_to_binary(String);
format({report, Report}, #{report_cb := Callback}) when is_function(Callback, 1) ->
    {Format, Args} = Callback(Report),
    unicode:characters_to_binary(io_lib:format(Format, Args));
format({report, Report}, _Meta) ->
    unicode:characters_to_binary(io_lib:format("~p", [Report]));
format({Format, Args}, _Meta) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).
