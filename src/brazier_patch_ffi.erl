-module(brazier_patch_ffi).
-export([diff_json/2, apply_json_ops/2, is_empty_ops/1, merge_ops_json/1, count_ops/1,
         escape_segment/1, parse_pointer/1]).

%% Brazier state-sync patches.
%%
%% Ops follow RFC 6902 (JSON Patch) with RFC 6901 (JSON Pointer) paths:
%%   add      - add an object member, or insert into an array at an index / "-"
%%   replace  - replace an existing value ("" replaces the whole document)
%%   remove   - remove an existing object member or array element
%%   append   - Brazier extension: concatenate a list onto an existing array
%%
%% The client mirror lives in brazier_client/src/brazier_client/patch.mjs and
%% MUST implement exactly the same semantics. Both sides are exercised against
%% the same randomly generated vectors by test/brazier/patch_test.gleam.
%%
%% Reference: RFC 6901, RFC 6902.

%% Diff two JSON strings and produce patch operations.
%% Returns a JSON-encoded string of the ops array.
%% Uses OTP 27+'s json:decode/1 and json:encode/1.
-spec diff_json(binary(), binary()) -> binary().
diff_json(OldJson, NewJson) ->
    Old = json:decode(OldJson),
    New = json:decode(NewJson),
    Ops = diff_values(Old, New, <<>>),
    iolist_to_binary(json:encode(Ops)).

%% Apply patch operations (JSON string) to a model JSON string.
%% Returns {ok, NewJsonString} or {error, Reason}. Every malformed op, unknown
%% op, invalid pointer or missing target is an error: nothing is skipped.
-spec apply_json_ops(binary(), binary()) -> {ok, binary()} | {error, binary()}.
apply_json_ops(ModelJson, OpsJson) ->
    try
        Model = json:decode(ModelJson),
        Ops = json:decode(OpsJson),
        case is_list(Ops) of
            true -> ok;
            false -> erlang:error({ops_not_array, Ops})
        end,
        NewModel = apply_ops_list(Model, Ops),
        {ok, iolist_to_binary(json:encode(NewModel))}
    catch
        _Class:Reason ->
            ReasonBin = unicode:characters_to_binary(
                io_lib:format("Patch apply failed: ~p", [Reason])
            ),
            {error, ReasonBin}
    end.

%% Check if an ops JSON string represents an empty ops array.
-spec is_empty_ops(binary()) -> boolean().
is_empty_ops(OpsJson) ->
    case json:decode(OpsJson) of
        [] -> true;
        _ -> false
    end.

%% === RFC 6901 JSON Pointer ===

%% Escape a single reference token: "~" -> "~0", then "/" -> "~1".
-spec escape_segment(binary()) -> binary().
escape_segment(Key) ->
    escape_segment(Key, <<>>).

escape_segment(<<>>, Acc) -> Acc;
escape_segment(<<$~, Rest/binary>>, Acc) -> escape_segment(Rest, <<Acc/binary, "~0">>);
escape_segment(<<$/, Rest/binary>>, Acc) -> escape_segment(Rest, <<Acc/binary, "~1">>);
escape_segment(<<C, Rest/binary>>, Acc) -> escape_segment(Rest, <<Acc/binary, C>>).

%% Parse a JSON pointer into reference tokens.
%% "" is the whole document; "/" is the single token "" (an empty key).
%% A non-empty pointer must start with "/". "~" must be followed by 0 or 1.
-spec parse_pointer(binary()) -> {ok, list(binary())} | {error, binary()}.
parse_pointer(Pointer) ->
    try
        {ok, parse_path(Pointer)}
    catch
        error:{invalid_pointer, _, Why} ->
            {error, <<"Invalid JSON pointer: ", Why/binary>>}
    end.

-spec parse_path(binary()) -> list(binary()).
parse_path(<<>>) ->
    [];
parse_path(<<$/, Rest/binary>> = Pointer) ->
    [unescape_segment(Segment, Pointer) || Segment <- binary:split(Rest, <<"/">>, [global])];
parse_path(Pointer) when is_binary(Pointer) ->
    erlang:error({invalid_pointer, Pointer, <<"pointer must be empty or start with /">>});
parse_path(Pointer) ->
    erlang:error({invalid_pointer, Pointer, <<"pointer must be a string">>}).

unescape_segment(Segment, Pointer) ->
    unescape_segment(Segment, Pointer, <<>>).

unescape_segment(<<>>, _Pointer, Acc) -> Acc;
unescape_segment(<<"~0", Rest/binary>>, Pointer, Acc) ->
    unescape_segment(Rest, Pointer, <<Acc/binary, $~>>);
unescape_segment(<<"~1", Rest/binary>>, Pointer, Acc) ->
    unescape_segment(Rest, Pointer, <<Acc/binary, $/>>);
unescape_segment(<<$~, _/binary>>, Pointer, _Acc) ->
    erlang:error({invalid_pointer, Pointer, <<"~ must be followed by 0 or 1">>});
unescape_segment(<<C, Rest/binary>>, Pointer, Acc) ->
    unescape_segment(Rest, Pointer, <<Acc/binary, C>>).

child_path(Base, Key) when is_binary(Key) ->
    Escaped = escape_segment(Key),
    <<Base/binary, $/, Escaped/binary>>;
child_path(Base, Index) when is_integer(Index) ->
    IndexBin = integer_to_binary(Index),
    <<Base/binary, $/, IndexBin/binary>>.

%% === Diff Engine ===

%% Diff two decoded JSON values at a given path prefix.
-spec diff_values(term(), term(), binary()) -> list().
diff_values(Old, New, _Path) when Old =:= New ->
    [];
diff_values(Old, New, Path) when is_map(Old), is_map(New) ->
    diff_maps(Old, New, Path);
diff_values(Old, New, Path) when is_list(Old), is_list(New) ->
    diff_arrays(Old, New, Path);
diff_values(_Old, New, Path) ->
    [replace_op(Path, New)].

replace_op(Path, Value) ->
    #{<<"op">> => <<"replace">>, <<"path">> => Path, <<"value">> => Value}.

%% Diff two maps: remove deleted keys, add new keys, recurse into shared keys.
%% Keys are visited in sorted order so the output is deterministic.
-spec diff_maps(map(), map(), binary()) -> list().
diff_maps(Old, New, BasePath) ->
    RemovedOps = [#{<<"op">> => <<"remove">>, <<"path">> => child_path(BasePath, Key)}
                  || Key <- lists:sort(maps:keys(Old)), not maps:is_key(Key, New)],
    ChangedOps = lists:flatmap(
        fun(Key) ->
            NewVal = maps:get(Key, New),
            Path = child_path(BasePath, Key),
            case maps:find(Key, Old) of
                error ->
                    [#{<<"op">> => <<"add">>, <<"path">> => Path, <<"value">> => NewVal}];
                {ok, OldVal} ->
                    diff_values(OldVal, NewVal, Path)
            end
        end,
        lists:sort(maps:keys(New))),
    RemovedOps ++ ChangedOps.

%% Diff two arrays.
%%
%% Strips the common prefix and suffix, then pairs the remaining middle
%% elements by index (recursively diffed), removes surplus old elements in
%% descending index order and inserts surplus new elements in ascending order.
%% A pure tail extension becomes a single Brazier `append` op. When the
%% element-wise patch would be larger than the array itself, the whole array
%% is replaced instead (an encoding-size decision, not an error path).
-spec diff_arrays(list(), list(), binary()) -> list().
diff_arrays(Old, New, Path) ->
    {Prefix, OldRest, NewRest} = strip_prefix(Old, New, 0),
    {OldMid, NewMid, SuffixLen} = strip_suffix(OldRest, NewRest),
    OldMidLen = length(OldMid),
    NewMidLen = length(NewMid),
    Paired = min(OldMidLen, NewMidLen),
    {OldPaired, OldSurplus} = lists:split(Paired, OldMid),
    {NewPaired, NewSurplus} = lists:split(Paired, NewMid),
    PairedOps = diff_paired(OldPaired, NewPaired, Path, Prefix),
    SurplusOps =
        case {OldSurplus, NewSurplus} of
            {[], []} ->
                [];
            {[_ | _], []} ->
                %% Remove highest index first so earlier indices stay valid.
                First = Prefix + Paired,
                Last = Prefix + OldMidLen - 1,
                [#{<<"op">> => <<"remove">>, <<"path">> => child_path(Path, I)}
                 || I <- lists:seq(Last, First, -1)];
            {[], [_ | _]} when SuffixLen =:= 0 ->
                [#{<<"op">> => <<"append">>, <<"path">> => Path, <<"value">> => NewSurplus}];
            {[], [_ | _]} ->
                First = Prefix + Paired,
                {InsertOps, _} = lists:mapfoldl(
                    fun(Value, I) ->
                        {#{<<"op">> => <<"add">>, <<"path">> => child_path(Path, I),
                           <<"value">> => Value}, I + 1}
                    end,
                    First,
                    NewSurplus),
                InsertOps
        end,
    Ops = PairedOps ++ SurplusOps,
    case length(Ops) > length(New) of
        true -> [replace_op(Path, New)];
        false -> Ops
    end.

strip_prefix([A | OldRest], [A | NewRest], Count) ->
    strip_prefix(OldRest, NewRest, Count + 1);
strip_prefix(Old, New, Count) ->
    {Count, Old, New}.

strip_suffix(Old, New) ->
    {RevOld, RevNew, Count} = strip_rev(lists:reverse(Old), lists:reverse(New), 0),
    {lists:reverse(RevOld), lists:reverse(RevNew), Count}.

strip_rev([A | OldRest], [A | NewRest], Count) ->
    strip_rev(OldRest, NewRest, Count + 1);
strip_rev(Old, New, Count) ->
    {Old, New, Count}.

diff_paired([], [], _Path, _Index) ->
    [];
diff_paired([OldVal | OldRest], [NewVal | NewRest], Path, Index) ->
    diff_values(OldVal, NewVal, child_path(Path, Index))
        ++ diff_paired(OldRest, NewRest, Path, Index + 1).

%% === Apply Engine ===

-spec apply_ops_list(term(), list()) -> term().
apply_ops_list(Model, []) ->
    Model;
apply_ops_list(Model, [Op | Rest]) ->
    apply_ops_list(apply_single_op(Model, Op), Rest).

-spec apply_single_op(term(), term()) -> term().
apply_single_op(Model, #{<<"op">> := <<"replace">>, <<"path">> := Path, <<"value">> := Value}) ->
    update_at(Model, parse_path(Path), fun(Container, Token) -> replace_in(Container, Token, Value) end, Value);
apply_single_op(Model, #{<<"op">> := <<"add">>, <<"path">> := Path, <<"value">> := Value}) ->
    update_at(Model, parse_path(Path), fun(Container, Token) -> add_in(Container, Token, Value) end, Value);
apply_single_op(Model, #{<<"op">> := <<"remove">>, <<"path">> := Path}) ->
    case parse_path(Path) of
        [] -> erlang:error({cannot_remove_root, Path});
        Tokens -> update_at(Model, Tokens, fun remove_in/2, undefined)
    end;
apply_single_op(Model, #{<<"op">> := <<"append">>, <<"path">> := Path, <<"value">> := Items})
        when is_list(Items) ->
    case parse_path(Path) of
        [] -> append_to(Model, Items, Path);
        Tokens ->
            update_at(Model, Tokens,
                      fun(Container, Token) ->
                          Current = get_in(Container, Token),
                          replace_in(Container, Token, append_to(Current, Items, Path))
                      end,
                      undefined)
    end;
apply_single_op(_Model, Op) ->
    erlang:error({unknown_or_malformed_op, Op}).

%% Walk to the parent of the final token and apply Fun(Parent, LastToken).
%% An empty token list means the whole document: RootValue is returned.
update_at(_Model, [], _Fun, RootValue) ->
    RootValue;
update_at(Model, [Token], Fun, _RootValue) ->
    Fun(Model, Token);
update_at(Model, [Token | Rest], Fun, RootValue) ->
    Child = get_in(Model, Token),
    replace_in(Model, Token, update_at(Child, Rest, Fun, RootValue)).

get_in(Map, Key) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> erlang:error({missing_member, Key})
    end;
get_in(List, Token) when is_list(List) ->
    Index = existing_index(List, Token),
    lists:nth(Index + 1, List);
get_in(Other, Token) ->
    erlang:error({not_a_container, Token, Other}).

replace_in(Map, Key, Value) when is_map(Map) ->
    case maps:is_key(Key, Map) of
        true -> maps:put(Key, Value, Map);
        false -> erlang:error({missing_member, Key})
    end;
replace_in(List, Token, Value) when is_list(List) ->
    Index = existing_index(List, Token),
    {Before, [_ | After]} = lists:split(Index, List),
    Before ++ [Value | After];
replace_in(Other, Token, _Value) ->
    erlang:error({not_a_container, Token, Other}).

add_in(Map, Key, Value) when is_map(Map) ->
    maps:put(Key, Value, Map);
add_in(List, <<"-">>, Value) when is_list(List) ->
    List ++ [Value];
add_in(List, Token, Value) when is_list(List) ->
    Index = parse_index(Token),
    case Index =< length(List) of
        true ->
            {Before, After} = lists:split(Index, List),
            Before ++ [Value | After];
        false ->
            erlang:error({index_out_of_bounds, Token, length(List)})
    end;
add_in(Other, Token, _Value) ->
    erlang:error({not_a_container, Token, Other}).

remove_in(Map, Key) when is_map(Map) ->
    case maps:is_key(Key, Map) of
        true -> maps:remove(Key, Map);
        false -> erlang:error({missing_member, Key})
    end;
remove_in(List, Token) when is_list(List) ->
    Index = existing_index(List, Token),
    {Before, [_ | After]} = lists:split(Index, List),
    Before ++ After;
remove_in(Other, Token) ->
    erlang:error({not_a_container, Token, Other}).

append_to(List, Items, _Path) when is_list(List) ->
    List ++ Items;
append_to(Other, _Items, Path) ->
    erlang:error({append_target_not_array, Path, Other}).

existing_index(List, Token) ->
    Index = parse_index(Token),
    case Index < length(List) of
        true -> Index;
        false -> erlang:error({index_out_of_bounds, Token, length(List)})
    end.

%% RFC 6901 array index: "0" or a decimal without leading zeros.
parse_index(<<"0">>) ->
    0;
parse_index(<<First, _/binary>> = Token) when First >= $1, First =< $9 ->
    case lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Token)) of
        true -> binary_to_integer(Token);
        false -> erlang:error({invalid_array_index, Token})
    end;
parse_index(Token) ->
    erlang:error({invalid_array_index, Token}).

%% Merge multiple JSON ops arrays into a single array.
%% Each input is a JSON-encoded string like "[{...}]".
-spec merge_ops_json(list(binary())) -> binary().
merge_ops_json(OpsList) ->
    AllOps = lists:flatmap(fun(OpsJson) ->
        json:decode(OpsJson)
    end, OpsList),
    iolist_to_binary(json:encode(AllOps)).

%% Count the number of operations in a JSON ops string.
%% Returns {error, Reason} when the JSON is malformed or not an array.
-spec count_ops(binary()) -> {ok, non_neg_integer()} | {error, binary()}.
count_ops(OpsJson) ->
    try
        Ops = json:decode(OpsJson),
        case is_list(Ops) of
            true -> {ok, length(Ops)};
            false -> {error, <<"Patch ops JSON must decode to an array">>}
        end
    catch
        _Class:Reason ->
            ReasonBin = unicode:characters_to_binary(
                io_lib:format("Patch op count failed: ~p", [Reason])
            ),
            {error, ReasonBin}
    end.
