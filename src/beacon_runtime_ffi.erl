-module(beacon_runtime_ffi).
-export([
    rescue/1, store_redirect_target/1, get_redirect_target/0,
    try_load_codec_encoder/0, try_load_codec_decoder/0,
    try_load_codec_event_decoder/0,
    try_load_codec_renderer/0,
    try_load_substate_names/0, try_load_substate_encoder/1, try_load_flat_encoder/0,
    message_queue_len/1
]).

%% Execute a function, catching any exception.
%% Returns {ok, Result} on success, {error, Reason} on failure.
rescue(Fun) ->
    try
        Result = Fun(),
        {ok, Result}
    catch
        _Class:Reason ->
            ReasonBin = unicode:characters_to_binary(
                io_lib:format("~p", [Reason])
            ),
            {error, ReasonBin}
    end.

%% Store redirect target in process dictionary for current effect execution.
store_redirect_target(Subject) ->
    erlang:put(beacon_redirect_target, Subject),
    nil.

%% Get redirect target from process dictionary.
get_redirect_target() ->
    case erlang:get(beacon_redirect_target) of
        undefined -> none;
        Subject -> {some, Subject}
    end.

%% Auto-discover beacon_codec module and return its encode_model function.
%% Returns {ok, Fun} if the module exists and exports encode_model/1,
%% or {error, nil} if not found.
try_load_codec_encoder() ->
    case code:ensure_loaded(beacon_codec) of
        {module, beacon_codec} ->
            case erlang:function_exported(beacon_codec, encode_model, 1) of
                true ->
                    {ok, fun beacon_codec:encode_model/1};
                false ->
                    {error, nil}
            end;
        _ ->
            {error, nil}
    end.

%% Auto-discover beacon_codec module and return its decode_model function.
%% Returns {ok, Fun} if the module exists and exports decode_model/1,
%% or {error, nil} if not found.
try_load_codec_decoder() ->
    case code:ensure_loaded(beacon_codec) of
        {module, beacon_codec} ->
            case erlang:function_exported(beacon_codec, decode_model, 1) of
                true ->
                    {ok, fun beacon_codec:decode_model/1};
                false ->
                    {error, nil}
            end;
        _ ->
            {error, nil}
    end.

%% Auto-discover beacon_codec module and return its decode_event function.
%% Returns {ok, Fun} if the module exists and exports decode_event/4,
%% or {error, nil} if not found.
try_load_codec_event_decoder() ->
    case code:ensure_loaded(beacon_codec) of
        {module, beacon_codec} ->
            case erlang:function_exported(beacon_codec, decode_event, 4) of
                true ->
                    {ok, fun beacon_codec:decode_event/4};
                false ->
                    {error, nil}
            end;
        _ ->
            {error, nil}
    end.

%% Auto-discover beacon_codec module and return its render_model function.
%% Returns {ok, Fun} if the module exists and exports render_model/1,
%% or {error, nil} if not found.
try_load_codec_renderer() ->
    case code:ensure_loaded(beacon_codec) of
        {module, beacon_codec} ->
            case erlang:function_exported(beacon_codec, render_model, 1) of
                true ->
                    {ok, fun beacon_codec:render_model/1};
                false ->
                    {error, nil}
            end;
        _ ->
            {error, nil}
    end.

%% Load substate_names/0 from beacon_codec.
%% Returns {ok, List(String)} or {error, nil}.
try_load_substate_names() ->
    case code:ensure_loaded(beacon_codec) of
        {module, beacon_codec} ->
            case erlang:function_exported(beacon_codec, substate_names, 0) of
                true ->
                    {ok, beacon_codec:substate_names()};
                false ->
                    {error, nil}
            end;
        _ ->
            {error, nil}
    end.

%% Load encode_substate_<Name>/1 from beacon_codec.
%% Name is a binary like <<"cards">>.
%% Returns {ok, Fun} or {error, nil}.
try_load_substate_encoder(Name) ->
    case validate_atom_name(Name) of
        ok ->
            case code:ensure_loaded(beacon_codec) of
                {module, beacon_codec} ->
                    FnName = binary_to_atom(<<"encode_substate_", Name/binary>>, utf8),
                    case erlang:function_exported(beacon_codec, FnName, 1) of
                        true ->
                            {ok, erlang:make_fun(beacon_codec, FnName, 1)};
                        false ->
                            {error, nil}
                    end;
                _ ->
                    {error, nil}
            end;
        {error, _} ->
            {error, nil}
    end.

%% Validate that a name is safe for atom conversion.
%% Max 255 bytes, alphanumeric + underscore + hyphen only (no spaces, no special chars).
%% This prevents atom table exhaustion from arbitrary user-controlled input.
%%
%% SECURITY: Atom creation constraint.
%% Substate names come from the generated beacon_codec module (compile-time analysis
%% of user type definitions), not from runtime user input. The set of atoms created
%% is bounded by the number of model fields in the user's app. The validate check
%% is a defense-in-depth measure.
validate_atom_name(Name) when byte_size(Name) > 255 ->
    {error, <<"Name too long (max 255 bytes)">>};
validate_atom_name(Name) ->
    case re:run(Name, <<"^[a-zA-Z0-9_-]+$">>) of
        {match, _} -> ok;
        nomatch -> {error, <<"Invalid name: must be alphanumeric, underscore, or hyphen">>}
    end.

%% Load encode_flat_fields/1 from beacon_codec.
%% Returns {ok, Fun} or {error, nil}.
try_load_flat_encoder() ->
    case code:ensure_loaded(beacon_codec) of
        {module, beacon_codec} ->
            case erlang:function_exported(beacon_codec, encode_flat_fields, 1) of
                true ->
                    {ok, fun beacon_codec:encode_flat_fields/1};
                false ->
                    {error, nil}
            end;
        _ ->
            {error, nil}
    end.

message_queue_len(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Len} -> Len;
        undefined -> 1000000000
    end.
