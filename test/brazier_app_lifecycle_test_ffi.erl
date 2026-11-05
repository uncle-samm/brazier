%% Test helpers for app_lifecycle_test.
-module(brazier_app_lifecycle_test_ffi).
-export([run_then_await_log/4, exit_with/1]).

%% Run Run, then wait for a log line at Level containing Fragment, logged
%% by any process on this node from the moment Run starts. A logger handler
%% runs in the logging process and forwards each line here, so the wait
%% ends as soon as the line is logged: {ok, Line}, or {error, Text} when
%% none arrives within Timeout ms (a deadline for a failing test, never a
%% sleep). The primary level is raised for the call and restored after it,
%% as brazier_log_capture_ffi does.
run_then_await_log(Run, Level, Fragment, Timeout) when is_function(Run, 0) ->
    Id = list_to_atom("brazier_app_lifecycle_log_" ++
                      integer_to_list(erlang:unique_integer([positive]))),
    #{level := PreviousLevel} = logger:get_primary_config(),
    ok = logger:add_handler(Id, brazier_log_capture_ffi,
                            #{level => all, config => #{pid => self(), id => Id}}),
    ok = logger:set_primary_config(level, all),
    try
        Run(),
        await_line(Id, Level, Fragment, Timeout)
    after
        ok = logger:set_primary_config(level, PreviousLevel),
        ok = logger:remove_handler(Id),
        flush(Id)
    end.

await_line(Id, Level, Fragment, Timeout) ->
    receive
        {brazier_captured_log, Id, {Level, Line}} ->
            case binary:match(Line, Fragment) of
                nomatch -> await_line(Id, Level, Fragment, Timeout);
                _ -> {ok, Line}
            end;
        {brazier_captured_log, Id, _Other} ->
            await_line(Id, Level, Fragment, Timeout)
    after Timeout ->
        {error, iolist_to_binary(io_lib:format("no ~s line containing ~p within ~pms",
                                               [Level, Fragment, Timeout]))}
    end.

%% The handler is removed: drop the lines it forwarded and nobody read.
flush(Id) ->
    receive
        {brazier_captured_log, Id, _} -> flush(Id)
    after 0 -> ok
    end.

%% Exit the calling process with Reason (an atom made from the binary).
exit_with(Reason) when is_binary(Reason) ->
    exit(binary_to_atom(Reason, utf8)).
