-module(brazier_log_ffi).
%% The one way Brazier's Erlang modules log.
%%
%% logger:info(Format, Args) hands the formatter a {Format, Args} message.
%% The gleam `logging` formatter (installed by brazier/log.configure) does not
%% format those: it prints the inspected tuple, so a line like
%%   {"brazier.http_conns started port=~p ...", [8080, ...]}
%% reaches the operator instead of the text. This module formats first and
%% logs the finished text as a {string, Text} message, which every formatter
%% prints as is (the gleam one, OTP's logger_formatter, a test capture).
%%
%% Every line has the shape the Gleam side uses (brazier/log):
%%   [brazier.http_conns] started port=8080 max_connections=10000 ...
%% and carries its context in the metadata too, for handlers that read it:
%%   #{domain => [brazier], brazier_context => <<"brazier.http_conns">>}
%%
%% Formatting runs only when the level is enabled (logger:allow/2), so a
%% disabled debug line costs one level check, as with the logger macros.
%% A format string that does not match its arguments is a programming
%% error: io_lib:format raises badarg and the caller crashes loudly.
-export([debug/2, debug/3, info/2, info/3, notice/2, notice/3,
         warning/2, warning/3, error/2, error/3, text/3]).

debug(Context, Text) -> log(debug, Context, Text).
debug(Context, Format, Args) -> log(debug, Context, Format, Args).
info(Context, Text) -> log(info, Context, Text).
info(Context, Format, Args) -> log(info, Context, Format, Args).
notice(Context, Text) -> log(notice, Context, Text).
notice(Context, Format, Args) -> log(notice, Context, Format, Args).
warning(Context, Text) -> log(warning, Context, Text).
warning(Context, Format, Args) -> log(warning, Context, Format, Args).
error(Context, Text) -> log(error, Context, Text).
error(Context, Format, Args) -> log(error, Context, Format, Args).

%% The finished line for Context, Format and Args, as a binary. Exposed so
%% tests can assert the exact text a call site produces.
text(Context, Format, Args) when is_binary(Context), is_list(Args) ->
    unicode:characters_to_binary([$[, Context, <<"] ">>, io_lib:format(Format, Args)]).

log(Level, Context, Text) when is_binary(Context) ->
    case logger:allow(Level, ?MODULE) of
        true ->
            emit(Level, Context,
                 unicode:characters_to_binary([$[, Context, <<"] ">>, Text]));
        false ->
            ok
    end.

log(Level, Context, Format, Args) when is_binary(Context), is_list(Args) ->
    case logger:allow(Level, ?MODULE) of
        true -> emit(Level, Context, text(Context, Format, Args));
        false -> ok
    end.

emit(Level, Context, Line) when is_binary(Line) ->
    logger:log(Level, Line, #{domain => [brazier], brazier_context => Context}).
