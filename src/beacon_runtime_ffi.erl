-module(beacon_runtime_ffi).
-export([
    store_navigation_targets/1, get_navigation_targets/0,
    try_load_codec_encoder/0, try_load_codec_decoder/0,
    try_load_codec_event_decoder/0,
    message_queue_len/1,
    event_label/1,
    run_guarded/1,
    guard_handler/2,
    describe_exit/1,
    exit_like/1
]).

%% The depth a crash or exit reason is printed to in telemetry metadata and
%% logs, so a huge term (a model in a badmatch) stays bounded.
-define(REASON_DEPTH, 30).

%% Run the runtime's message handler. A crash (error, exit or throw) is
%% reported to OnCrash with its class and a bounded description, then
%% raised again unchanged, so the runtime still dies with the original
%% reason and stacktrace (gen_server runs terminate/2 for a callback that
%% raises the same way, then exits with the reason).
guard_handler(Run, OnCrash) ->
    try Run()
    catch
        Class:Reason:Stacktrace ->
            report_crash(OnCrash, Class, Reason),
            erlang:raise(Class, Reason, Stacktrace)
    end.

%% A report that fails is logged and the original crash still propagates:
%% the report must never replace the reason the runtime dies with.
report_crash(OnCrash, Class, Reason) ->
    Description = describe(Reason),
    try
        OnCrash(atom_to_binary(Class, utf8), Description)
    catch
        ReportClass:ReportReason:ReportStacktrace ->
            beacon_log_ffi:error(<<"beacon.runtime">>,
                "Reporting the runtime crash ~ts:~ts failed: ~p:~0tP~n~p",
                [Class, Description, ReportClass, ReportReason, ?REASON_DEPTH,
                 ReportStacktrace])
    end.

%% A trapped exit's reason, as gleam/erlang/process.ExitReason, described
%% for telemetry and the log.
describe_exit(killed) -> <<"killed">>;
describe_exit({abnormal, Reason}) -> describe(Reason).

%% Exit the calling process with the reason a linked process exited with,
%% so the runtime's own links see the same reason. A normal exit is not
%% passed here (a normal exit of a linked process does not stop the
%% runtime), so `normal` crashes with function_clause.
exit_like(killed) -> exit(killed);
exit_like({abnormal, Reason}) -> exit(Reason).

describe(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0tP", [Reason, ?REASON_DEPTH])).

%% Run Fun in the calling process. A crash (error, exit or throw) is returned
%% as {error, {<<"Class:Reason">>, <<"Stacktrace">>}}, so the caller can
%% answer it (close the socket with 1011) instead of dying. The caller logs
%% it once, with the session's context (beacon/runtime.mount).
run_guarded(Fun) ->
    try Fun() of
        Result -> {ok, Result}
    catch
        Class:Reason:Stacktrace ->
            {error, {unicode:characters_to_binary(io_lib:format("~p:~p", [Class, Reason])),
                     unicode:characters_to_binary(io_lib:format("~p", [Stacktrace]))}}
    end.

%% The telemetry label of an app message: its constructor name. A Gleam
%% constructor without fields is an atom and one with fields is a tuple
%% headed by an atom, so the label set is the app's finite set of
%% constructors. Any other value (a String or Int message type) is
%% "unknown", so a label never carries message data.
event_label(Msg) when is_atom(Msg) ->
    atom_to_binary(Msg, utf8);
event_label(Msg) when is_tuple(Msg), tuple_size(Msg) > 0, is_atom(element(1, Msg)) ->
    atom_to_binary(element(1, Msg), utf8);
event_label(_) ->
    <<"unknown">>.

%% Store the connections that `beacon/router` navigation effects should
%% navigate in the runtime's process dictionary, before the runtime runs
%% effects. Overwritten on every effect run, so a stale target never leaks.
store_navigation_targets(Subjects) when is_list(Subjects) ->
    erlang:put(beacon_navigation_targets, Subjects),
    nil.

%% The stored navigation targets; [] in a process that never stored any
%% (an effect run outside the runtime, or a spawned effect process).
get_navigation_targets() ->
    case erlang:get(beacon_navigation_targets) of
        undefined -> [];
        Subjects when is_list(Subjects) -> Subjects
    end.


%% The generated beacon_codec:encode_model/1, or {error, nil} when the codec
%% has not been generated.
try_load_codec_encoder() ->
    try_load(encode_model, 1).

%% The generated beacon_codec:decode_model/1.
try_load_codec_decoder() ->
    try_load(decode_model, 1).

%% The generated beacon_codec:decode_event/4.
try_load_codec_event_decoder() ->
    try_load(decode_event, 4).

try_load(Name, Arity) ->
    case code:ensure_loaded(beacon_codec) of
        {module, beacon_codec} ->
            case erlang:function_exported(beacon_codec, Name, Arity) of
                true -> {ok, erlang:make_fun(beacon_codec, Name, Arity)};
                false -> {error, nil}
            end;
        _ ->
            {error, nil}
    end.

message_queue_len(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Len} -> Len;
        undefined -> 1000000000
    end.
