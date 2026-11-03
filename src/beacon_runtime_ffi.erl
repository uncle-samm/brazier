-module(beacon_runtime_ffi).
-export([
    store_navigation_targets/1, get_navigation_targets/0,
    try_load_codec_encoder/0, try_load_codec_decoder/0,
    try_load_codec_event_decoder/0,
    message_queue_len/1
]).

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
