%% Test helper for ws8c_log_format_test: capture the log events the calling
%% process emits and render each one the way an operator would see it,
%% through the gleam `logging` formatter (what brazier/log.configure
%% installs) and through OTP's default logger_formatter.
-module(brazier_ws8c_log_format_ffi).
-export([capture/1, log/2, text_crash/0]).

capture(Fun) ->
    Id = list_to_atom(
        "brazier_ws8c_log_format_" ++ integer_to_list(erlang:unique_integer([positive]))
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

%% logger handler callback: forward the calling process's events, rendered.
log(Event = #{meta := Meta}, #{id := Id, config := #{target := Target}}) ->
    case maps:get(pid, Meta, undefined) of
        Target ->
            Gleam = unicode:characters_to_binary(
                logging_ffi:format(Event, #{colored => false})),
            Otp = unicode:characters_to_binary(
                logger_formatter:format(Event, #{single_line => true,
                                                 template => [level, " ", msg, "\n"]})),
            Context = maps:get(brazier_context, Meta, <<>>),
            Target ! {brazier_ws8c_log, Id, Gleam, Otp, Context};
        _ ->
            ok
    end,
    ok.

drain(Id, Acc) ->
    receive
        {brazier_ws8c_log, Id, Gleam, Otp, Context} ->
            drain(Id, [{Gleam, Otp, Context} | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

%% A format string that does not match its arguments crashes the caller.
text_crash() ->
    try brazier_log_ffi:text(<<"brazier.test">>, "~p ~p", [only_one]) of
        Text -> {ok, Text}
    catch
        error:badarg -> {error, <<"badarg">>}
    end.
