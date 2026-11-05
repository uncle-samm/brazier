%% Type checks for brazier/internal/wire_decode on Erlang.
%%
%% Each check answers whether a parsed JSON value (from gleam_json) is of one
%% kind, and returns it unchanged when it is. The decoders build their errors
%% in Gleam; nothing here builds an error or a path.
-module(brazier_wire_decode_ffi).

-export([
    to_int/1,
    to_float/1,
    to_bool/1,
    to_string/1,
    is_null/1,
    is_object/1,
    object_get/2,
    to_list/1,
    to_entries/1
]).

to_int(Data) when is_integer(Data) -> {ok, Data};
to_int(_) -> {error, nil}.

%% An integer is accepted as a float, because JavaScript writes the float
%% 1.0 as 1. An integer too large for a float is refused, not a crash.
to_float(Data) when is_float(Data) -> {ok, Data};
to_float(Data) when is_integer(Data) ->
    try
        {ok, float(Data)}
    catch
        error:badarg -> {error, nil}
    end;
to_float(_) -> {error, nil}.

to_bool(Data) when is_boolean(Data) -> {ok, Data};
to_bool(_) -> {error, nil}.

%% A Gleam String is a binary of valid UTF-8.
to_string(Data) when is_binary(Data) ->
    case is_utf8(Data) of
        true -> {ok, Data};
        false -> {error, nil}
    end;
to_string(_) -> {error, nil}.

is_utf8(<<>>) -> true;
is_utf8(<<_/utf8, Rest/binary>>) -> is_utf8(Rest);
is_utf8(_) -> false.

%% null as gleam/dynamic/decode.optional reads it.
is_null(Data) ->
    Data =:= null orelse Data =:= nil orelse Data =:= undefined.

is_object(Data) -> is_map(Data).

object_get(Data, Key) when is_map(Data) ->
    case maps:find(Key, Data) of
        {ok, Value} -> {ok, {some, Value}};
        error -> {ok, none}
    end;
object_get(_, _) -> {error, nil}.

to_list(Data) when is_list(Data) -> {ok, Data};
to_list(_) -> {error, nil}.

to_entries(Data) when is_map(Data) -> {ok, maps:to_list(Data)};
to_entries(_) -> {error, nil}.
