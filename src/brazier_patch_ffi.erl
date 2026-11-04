-module(brazier_patch_ffi).
-export([diff_json/2, apply_json_ops/2, is_empty_ops/1, merge_ops_json/1, count_ops/1,
         escape_segment/1, parse_pointer/1, unsafe_keys/0]).

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
%% Unsafe keys: unsafe_keys/0 below is THE canonical list. patch.mjs mirrors
%% it as UNSAFE_PATCH_KEYS, and test/brazier/patch_test.gleam asserts the two
%% are equal. Neither diff ever emits a path through an unsafe key (the
%% nearest safe parent is replaced instead) and both appliers refuse one.
%% On the JS client a path through "__proto__", "constructor" or "prototype"
%% could reach Object.prototype (prototype pollution); the server refuses it
%% too so both sides keep exactly the same semantics.
%%
%% Reference: RFC 6901, RFC 6902; the unsafe keys are the ones the OWASP
%% prototype-pollution guidance and lodash's `baseSet` guard refuse.

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
%%
%% A path through an unsafe key (see unsafe_keys/0) is never emitted: when an
%% unsafe key is added, removed or changed, the map holding it (the nearest
%% safe parent) is replaced whole. Both appliers refuse such paths, so an
%% op through one would force every client into a full resync.
-spec diff_maps(map(), map(), binary()) -> list().
diff_maps(Old, New, BasePath) ->
    case touches_unsafe_key(Old, New) of
        true -> [replace_op(BasePath, New)];
        false -> diff_safe_maps(Old, New, BasePath)
    end.

diff_safe_maps(Old, New, BasePath) ->
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

%% True when an unsafe key was added, removed or changed between two maps.
%% Three lookups per map, never a walk of the keys.
touches_unsafe_key(Old, New) ->
    lists:any(fun(Key) -> maps:find(Key, Old) =/= maps:find(Key, New) end, unsafe_keys()).

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
%%
%% A patch can carry thousands of ops against one array (the diff of a long
%% list emits one op per changed element). Rebuilding the list for every op
%% (lists:split/2, ++, length/1, lists:nth/2) made a patch cost O(ops * n).
%% Instead every container an op walks through is opened ONCE per patch and
%% closed back into plain JSON terms after the last op:
%%
%%   - a list becomes a zipper (Huet, "The Zipper", JFP 1997):
%%     {'$open_list', RevBefore, After, Index, Len, HasOpen}. The element at
%%     Index is the head of After and RevBefore holds the elements before it
%%     in reverse. Len is tracked so bounds checks never call length/1, and
%%     HasOpen says whether any element may itself be open.
%%   - a map becomes {'$open_map', Map, OpenKeys}; OpenKeys holds the keys
%%     whose values are open.
%%
%% Moving the cursor costs the distance moved, so the ascending pairs, the
%% descending removes and the ascending inserts the diff emits cost
%% O(n + ops) per array instead of O(ops * n). The tagged tuples never occur
%% in decoded JSON (json:decode/1 yields only maps, lists, binaries, numbers
%% and atoms), so an open container is never confused with a model value.
%% The error terms are exactly those of the list-rebuilding engine; the
%% randomized comparison in test/brazier/patch_test.gleam holds them equal.

-spec apply_ops_list(term(), list()) -> term().
apply_ops_list(Model, Ops) ->
    close(lists:foldl(fun(Op, Root) -> apply_single_op(Root, Op) end, Model, Ops)).

-spec apply_single_op(term(), term()) -> term().
apply_single_op(Root, #{<<"op">> := <<"replace">>, <<"path">> := Path, <<"value">> := Value}) ->
    update_at(Root, safe_path(Path), fun(Container, Token) -> replace_in(Container, Token, Value) end, Value);
apply_single_op(Root, #{<<"op">> := <<"add">>, <<"path">> := Path, <<"value">> := Value}) ->
    update_at(Root, safe_path(Path), fun(Container, Token) -> add_in(Container, Token, Value) end, Value);
apply_single_op(Root, #{<<"op">> := <<"remove">>, <<"path">> := Path}) ->
    case safe_path(Path) of
        [] -> erlang:error({cannot_remove_root, Path});
        Tokens -> update_at(Root, Tokens, fun remove_in/2, undefined)
    end;
apply_single_op(Root, #{<<"op">> := <<"append">>, <<"path">> := Path, <<"value">> := Items})
        when is_list(Items) ->
    case safe_path(Path) of
        [] -> append_to(Root, Items, Path);
        Tokens ->
            update_at(Root, Tokens,
                      fun(Container, Token) ->
                          {Current, Seeked} = get_in(Container, Token),
                          replace_in(Seeked, Token, append_to(Current, Items, Path))
                      end,
                      undefined)
    end;
apply_single_op(_Root, Op) ->
    erlang:error({unknown_or_malformed_op, Op}).

%% Parse a pointer and refuse any token on the unsafe-key list.
safe_path(Path) ->
    Tokens = parse_path(Path),
    case [Token || Token <- Tokens, lists:member(Token, unsafe_keys())] of
        [] -> Tokens;
        [Unsafe | _] -> erlang:error({unsafe_path_segment, Unsafe})
    end.

%% Keys a patch path must never pass through. THE canonical list: patch.mjs
%% mirrors it as UNSAFE_PATCH_KEYS and patch_test.gleam asserts equality.
-spec unsafe_keys() -> list(binary()).
unsafe_keys() ->
    [<<"__proto__">>, <<"constructor">>, <<"prototype">>].

%% Walk to the parent of the final token, opening each container on the way,
%% and apply Fun(OpenParent, LastToken). An empty token list means the whole
%% document: RootValue is returned.
update_at(_Node, [], _Fun, RootValue) ->
    RootValue;
update_at(Node, [Token], Fun, _RootValue) ->
    Fun(open(Node, Token), Token);
update_at(Node, [Token | Rest], Fun, RootValue) ->
    {Child, Seeked} = get_in(open(Node, Token), Token),
    replace_in(Seeked, Token, update_at(Child, Rest, Fun, RootValue)).

%% Open a container for in-place editing within this patch. An already open
%% container is returned as is; a scalar cannot be traversed.
open({'$open_list', _, _, _, _, _} = Open, _Token) -> Open;
open({'$open_map', _, _} = Open, _Token) -> Open;
open(Map, _Token) when is_map(Map) -> {'$open_map', Map, #{}};
open(List, _Token) when is_list(List) -> {'$open_list', [], List, 0, length(List), false};
open(Other, Token) -> erlang:error({not_a_container, Token, Other}).

is_open({'$open_list', _, _, _, _, _}) -> true;
is_open({'$open_map', _, _}) -> true;
is_open(_) -> false.

%% Close an open container (and every open container inside it) back into a
%% plain JSON term. A plain value never holds an open one, so it is returned
%% as is without a walk.
close({'$open_list', RevBefore, After, _Index, _Len, false}) ->
    lists:reverse(RevBefore, After);
close({'$open_list', RevBefore, After, _Index, _Len, true}) ->
    [close(Element) || Element <- lists:reverse(RevBefore, After)];
close({'$open_map', Map, OpenKeys}) ->
    %% `:=` crashes if an open key is missing: OpenKeys must be a subset of
    %% the map's keys, an invariant replace_in/add_in/remove_in maintain.
    maps:fold(fun(Key, true, Acc) -> Acc#{Key := close(maps:get(Key, Acc))} end, Map, OpenKeys);
close(Value) ->
    Value.

%% Move a zipper's cursor to Target (0 =< Target =< Len).
seek({'$open_list', RevBefore, After, Index, Len, HasOpen}, Target) ->
    {RevBefore1, After1} = move(RevBefore, After, Index, Target),
    {'$open_list', RevBefore1, After1, Target, Len, HasOpen}.

move(RevBefore, After, Index, Index) ->
    {RevBefore, After};
move(RevBefore, [Element | After], Index, Target) when Index < Target ->
    move([Element | RevBefore], After, Index + 1, Target);
move([Element | RevBefore], After, Index, Target) when Index > Target ->
    move(RevBefore, [Element | After], Index - 1, Target).

%% Look up a child. Returns {Child, Open}: Open is the container with its
%% cursor moved onto the child, so the replace_in/3 that follows is O(1).
get_in({'$open_map', Map, _} = Open, Key) ->
    case maps:find(Key, Map) of
        {ok, Value} -> {Value, Open};
        error -> erlang:error({missing_member, Key})
    end;
get_in({'$open_list', _, _, _, Len, _} = Open, Token) ->
    {'$open_list', _, [Value | _], _, _, _} = Seeked = seek(Open, existing_index(Token, Len)),
    {Value, Seeked}.

replace_in({'$open_map', Map, OpenKeys}, Key, Value) ->
    case maps:is_key(Key, Map) of
        true -> {'$open_map', maps:put(Key, Value, Map), track_open(Key, Value, OpenKeys)};
        false -> erlang:error({missing_member, Key})
    end;
replace_in({'$open_list', _, _, _, Len, _} = Open, Token, Value) ->
    {'$open_list', RevBefore, [_ | After], Index, Len, HasOpen} = seek(Open, existing_index(Token, Len)),
    {'$open_list', RevBefore, [Value | After], Index, Len, HasOpen orelse is_open(Value)}.

add_in({'$open_map', Map, OpenKeys}, Key, Value) ->
    {'$open_map', maps:put(Key, Value, Map), track_open(Key, Value, OpenKeys)};
add_in({'$open_list', _, _, _, Len, _} = Open, <<"-">>, Value) ->
    insert_at(Open, Len, Value);
add_in({'$open_list', _, _, _, Len, _} = Open, Token, Value) ->
    Index = parse_index(Token),
    case Index =< Len of
        true -> insert_at(Open, Index, Value);
        false -> erlang:error({index_out_of_bounds, Token, Len})
    end.

insert_at(Open, Index, Value) ->
    {'$open_list', RevBefore, After, Index, Len, HasOpen} = seek(Open, Index),
    {'$open_list', RevBefore, [Value | After], Index, Len + 1, HasOpen orelse is_open(Value)}.

remove_in({'$open_map', Map, OpenKeys}, Key) ->
    case maps:is_key(Key, Map) of
        true -> {'$open_map', maps:remove(Key, Map), maps:remove(Key, OpenKeys)};
        false -> erlang:error({missing_member, Key})
    end;
remove_in({'$open_list', _, _, _, Len, _} = Open, Token) ->
    {'$open_list', RevBefore, [_ | After], Index, Len, HasOpen} = seek(Open, existing_index(Token, Len)),
    {'$open_list', RevBefore, After, Index, Len - 1, HasOpen}.

track_open(Key, Value, OpenKeys) ->
    case is_open(Value) of
        true -> OpenKeys#{Key => true};
        false -> maps:remove(Key, OpenKeys)
    end.

%% Concatenate Items onto the end of a list target. The cursor moves to the
%% end once; Items become the tail without copying the list.
append_to({'$open_list', _, _, _, Len, _} = Open, Items, _Path) ->
    {'$open_list', RevBefore, [], Len, Len, HasOpen} = seek(Open, Len),
    {'$open_list', RevBefore, Items, Len, Len + length(Items), HasOpen};
append_to(List, Items, Path) when is_list(List) ->
    append_to(open(List, Path), Items, Path);
append_to(Other, _Items, Path) ->
    erlang:error({append_target_not_array, Path, close(Other)}).

existing_index(Token, Len) ->
    Index = parse_index(Token),
    case Index < Len of
        true -> Index;
        false -> erlang:error({index_out_of_bounds, Token, Len})
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
