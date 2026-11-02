-module(beacon_runtime_ffi).
-export([
    store_redirect_target/1, get_redirect_target/0,
    try_load_codec_encoder/0, try_load_codec_decoder/0,
    try_load_codec_event_decoder/0,
    message_queue_len/1
]).

%% Store the navigation target (the connection whose event is being
%% handled) in the runtime's process dictionary while effects run.
store_redirect_target(Subject) ->
    erlang:put(beacon_redirect_target, Subject),
    nil.

%% Get the navigation target from the process dictionary.
get_redirect_target() ->
    case erlang:get(beacon_redirect_target) of
        undefined -> none;
        Subject -> {some, Subject}
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
