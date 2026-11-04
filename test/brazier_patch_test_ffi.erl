-module(brazier_patch_test_ffi).
-export([random_pair/1, compare_apply/1, run_node/2, write_file/2, scratch_path/1]).

%% Property-test helpers for the patch round trip (server diff -> client apply).

%% Generate a random {OldJson, NewJson} pair from an integer seed.
%% New is derived from Old by a handful of random structural edits so diffs
%% exercise object add/remove/replace, array insert/remove/replace/append and
%% RFC 6901 escaping ("~" and "/" in keys).
-spec random_pair(integer()) -> {binary(), binary()}.
random_pair(Seed) ->
    rand:seed(exsss, {Seed, Seed * 7 + 1, Seed * 13 + 3}),
    Old = gen_object(3),
    New = mutate_n(Old, 1 + rand:uniform(4)),
    {iolist_to_binary(json:encode(Old)), iolist_to_binary(json:encode(New))}.

keys() ->
    [<<"a">>, <<"b">>, <<"count">>, <<"items">>, <<"a/b">>, <<"~">>, <<"~1">>,
     <<"x~0/y">>, <<"">>, <<"name">>, <<"0">>, <<"-">>, <<"ünï"/utf8>>,
     %% Unsafe keys: both diffs must replace the map holding one instead of
     %% emitting a path through it (SEC-14).
     <<"__proto__">>, <<"constructor">>, <<"prototype">>].

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).

gen_scalar() ->
    case rand:uniform(6) of
        1 -> rand:uniform(100) - 50;
        2 -> (rand:uniform(100) - 50) + 0.5;
        3 -> pick([<<"">>, <<"x">>, <<"hello">>, <<"a/b~c">>]);
        4 -> true;
        5 -> false;
        6 -> null
    end.

gen_value(0) ->
    gen_scalar();
gen_value(Depth) ->
    case rand:uniform(4) of
        1 -> gen_object(Depth - 1);
        2 -> gen_array(Depth - 1);
        _ -> gen_scalar()
    end.

gen_object(Depth) ->
    N = rand:uniform(4) - 1,
    maps:from_list([{pick(keys()), gen_value(Depth)} || _ <- lists:seq(1, N)]).

gen_array(Depth) ->
    N = rand:uniform(5) - 1,
    [gen_value(Depth) || _ <- lists:seq(1, N)].

mutate_n(Value, 0) -> Value;
mutate_n(Value, N) -> mutate_n(mutate(Value), N - 1).

%% Apply one random edit somewhere inside Value.
mutate(Map) when is_map(Map) ->
    Keys = maps:keys(Map),
    case {rand:uniform(4), Keys} of
        {1, _} -> maps:put(pick(keys()), gen_value(2), Map);
        {2, [_ | _]} -> maps:remove(pick(Keys), Map);
        {3, [_ | _]} -> K = pick(Keys), maps:put(K, mutate(maps:get(K, Map)), Map);
        _ -> maps:put(pick(keys()), gen_value(1), Map)
    end;
mutate(List) when is_list(List) ->
    Len = length(List),
    case {rand:uniform(5), Len} of
        {1, _} ->
            I = rand:uniform(Len + 1) - 1,
            {Before, After} = lists:split(I, List),
            Before ++ [gen_value(1) | After];
        {2, L} when L > 0 ->
            I = rand:uniform(L) - 1,
            {Before, [_ | After]} = lists:split(I, List),
            Before ++ After;
        {3, L} when L > 0 ->
            I = rand:uniform(L) - 1,
            {Before, [Old | After]} = lists:split(I, List),
            Before ++ [mutate(Old) | After];
        {4, _} ->
            List ++ [gen_value(1) || _ <- lists:seq(1, rand:uniform(3))];
        _ ->
            [gen_value(1) | List]
    end;
mutate(_Scalar) ->
    case rand:uniform(3) of
        1 -> gen_object(1);
        2 -> gen_array(1);
        3 -> gen_scalar()
    end.

%% === Apply engine equivalence ===
%%
%% PERF-8 replaced the list-rebuilding apply engine (lists:split/2, ++,
%% length/1 and lists:nth/2 per op) with per-patch zippers. compare_apply/1
%% runs one seeded random patch through brazier_patch_ffi:apply_json_ops/2 and
%% through the list-rebuilding engine kept verbatim below (ref_*), and
%% requires the same result: the same JSON, or the same error reason.
%% Patches mix runs of ops on one array (the shapes a diff emits) with rare
%% corrupt ops (out-of-bounds or leading-zero indices, missing members,
%% scalar traversal, non-array appends, root removal, unknown ops).

%% {ok, true} when both engines applied the patch identically, {ok, false}
%% when both refused it with the same reason, {error, Details} otherwise.
-spec compare_apply(integer()) -> {ok, boolean()} | {error, binary()}.
compare_apply(Seed) ->
    rand:seed(exsss, {Seed, Seed * 3 + 5, Seed * 11 + 7}),
    Model = gen_model(),
    Ops = gen_ops(Model, 1 + rand:uniform(24), []),
    ModelJson = iolist_to_binary(json:encode(Model)),
    OpsJson = iolist_to_binary(json:encode(Ops)),
    New = brazier_patch_ffi:apply_json_ops(ModelJson, OpsJson),
    Ref = ref_apply_json_ops(ModelJson, OpsJson),
    case New =:= Ref of
        true -> {ok, element(1, New) =:= ok};
        false ->
            {error, unicode:characters_to_binary(io_lib:format(
                "apply engines disagree~nmodel=~ts~nops=~ts~nzipper=~p~nreference=~p",
                [ModelJson, OpsJson, New, Ref]))}
    end.

gen_model() ->
    case rand:uniform(3) of
        1 -> #{<<"items">> => [gen_value(1) || _ <- lists:seq(1, rand:uniform(60))],
               <<"rest">> => gen_object(2)};
        2 -> [gen_value(2) || _ <- lists:seq(1, rand:uniform(40))];
        3 -> gen_object(3)
    end.

safe_keys() ->
    [Key || Key <- keys(), not lists:member(Key, brazier_patch_ffi:unsafe_keys())].

%% Generate N op groups, evolving the model through the reference engine so
%% later ops address what earlier ones produced. A refused group leaves the
%% model as it was (the whole patch is refused at that op anyway).
gen_ops(_Model, 0, Acc) ->
    lists:append(lists:reverse(Acc));
gen_ops(Model, N, Acc) ->
    Group = gen_group(Model),
    Next = try ref_apply_ops_list(Model, Group) catch error:_ -> Model end,
    gen_ops(Next, N - 1, [Group | Acc]).

gen_group(Model) ->
    {Tokens, Container} = pick_container(Model, []),
    case rand:uniform(60) of
        1 -> [corrupt_op(Model, Tokens, Container)];
        2 -> [#{<<"op">> => <<"replace">>, <<"path">> => <<>>, <<"value">> => gen_object(2)}];
        _ -> member_ops(Tokens, Container)
    end.

%% Walk to a random container (the root included), skipping unsafe keys.
pick_container(Value, Rev) ->
    case [Child || {_, C} = Child <- children(Value), is_map(C) orelse is_list(C)] of
        [_ | _] = Containers ->
            case rand:uniform(3) of
                1 -> {lists:reverse(Rev), Value};
                _ -> {Token, Child} = pick(Containers), pick_container(Child, [Token | Rev])
            end;
        [] ->
            {lists:reverse(Rev), Value}
    end.

children(Map) when is_map(Map) ->
    [{Key, Value} || {Key, Value} <- lists:sort(maps:to_list(Map)),
                     not lists:member(Key, brazier_patch_ffi:unsafe_keys())];
children(List) when is_list(List) ->
    lists:zip([integer_to_binary(I) || I <- lists:seq(0, length(List) - 1)], List);
children(_) ->
    [].

pointer(Tokens) ->
    iolist_to_binary([[$/, brazier_patch_ffi:escape_segment(Token)] || Token <- Tokens]).

op(Name, Tokens) -> #{<<"op">> => Name, <<"path">> => pointer(Tokens)}.
op(Name, Tokens, Value) -> (op(Name, Tokens))#{<<"value">> => Value}.

%% Valid ops on the members of one container.
member_ops(Tokens, Map) when is_map(Map) ->
    Existing = [Key || {Key, _} <- children(Map)],
    case {rand:uniform(4), Existing} of
        {1, [_ | _]} -> [op(<<"replace">>, Tokens ++ [pick(Existing)], gen_value(1))];
        {2, [_ | _]} -> [op(<<"remove">>, Tokens ++ [pick(Existing)])];
        {3, [_ | _]} ->
            Key = pick(Existing),
            case maps:get(Key, Map) of
                List when is_list(List) -> [op(<<"append">>, Tokens ++ [Key], [gen_value(1)])];
                _ -> [op(<<"replace">>, Tokens ++ [Key], gen_value(2))]
            end;
        _ -> [op(<<"add">>, Tokens ++ [pick(safe_keys())], gen_value(2))]
    end;
member_ops(Tokens, List) when is_list(List) ->
    Len = length(List),
    Index = fun(I) -> Tokens ++ [integer_to_binary(I)] end,
    case {rand:uniform(6), Len} of
        {1, L} when L > 0 ->
            %% Ascending replaces: the paired ops of an array diff.
            First = rand:uniform(L) - 1,
            Last = min(L - 1, First + rand:uniform(8) - 1),
            [op(<<"replace">>, Index(I), gen_value(1)) || I <- lists:seq(First, Last)];
        {2, L} when L > 0 ->
            %% Descending removes: the surplus removes of an array diff.
            Count = rand:uniform(min(L, 8)),
            [op(<<"remove">>, Index(I)) || I <- lists:seq(L - 1, L - Count, -1)];
        {3, L} ->
            %% Ascending inserts: the surplus adds of an array diff.
            First = rand:uniform(L + 1) - 1,
            [op(<<"add">>, Index(I), gen_value(1)) || I <- lists:seq(First, First + rand:uniform(5) - 1)];
        {4, _} ->
            [op(<<"add">>, Tokens ++ [<<"-">>], gen_value(1))];
        {5, _} ->
            [op(<<"append">>, Tokens, [gen_value(1) || _ <- lists:seq(1, rand:uniform(3))])];
        {_, L} when L > 0 ->
            %% Scattered ops: the cursor moves both ways.
            [op(<<"replace">>, Index(rand:uniform(L) - 1), gen_value(1)) || _ <- lists:seq(1, 4)];
        _ ->
            [op(<<"add">>, Index(0), gen_value(1))]
    end;
member_ops(Tokens, _Scalar) ->
    %% A scalar root (after a root replace): adding to it must be refused.
    [op(<<"add">>, Tokens ++ [pick(safe_keys())], gen_value(1))].

%% One op both engines must refuse.
corrupt_op(Model, Tokens, Container) ->
    Len = case Container of
        List when is_list(List) -> length(List);
        _ -> 0
    end,
    case rand:uniform(7) of
        1 -> op(<<"replace">>, Tokens ++ [integer_to_binary(Len + rand:uniform(3) - 1)], 1);
        2 -> op(<<"add">>, Tokens ++ [integer_to_binary(Len + 1 + rand:uniform(2))], 1);
        3 -> op(<<"remove">>, Tokens ++ [<<"01">>]);
        4 -> op(<<"replace">>, Tokens ++ [<<"no such member">>, <<"x">>], 1);
        5 -> op(<<"append">>, Tokens ++ [<<"no such member">>], [1]);
        6 -> case scalar_member(Model) of
                 {ok, ScalarTokens} -> op(<<"replace">>, ScalarTokens ++ [<<"x">>], 1);
                 error -> #{<<"op">> => <<"remove">>, <<"path">> => <<>>}
             end;
        7 -> #{<<"op">> => <<"move">>, <<"from">> => <<>>, <<"path">> => pointer(Tokens)}
    end.

%% A path to some scalar inside Value, if there is one on a random walk.
scalar_member(Value) ->
    case children(Value) of
        [] -> error;
        Children ->
            {Token, Child} = pick(Children),
            case is_map(Child) orelse is_list(Child) of
                true ->
                    case scalar_member(Child) of
                        {ok, Rest} -> {ok, [Token | Rest]};
                        error -> error
                    end;
                false -> {ok, [Token]}
            end
    end.

%% The list-rebuilding engine as it was before PERF-8, kept verbatim (with
%% a ref_ prefix) as the reference. Same wrapper as apply_json_ops/2.
ref_apply_json_ops(ModelJson, OpsJson) ->
    try
        Model = json:decode(ModelJson),
        Ops = json:decode(OpsJson),
        case is_list(Ops) of
            true -> ok;
            false -> erlang:error({ops_not_array, Ops})
        end,
        NewModel = ref_apply_ops_list(Model, Ops),
        {ok, iolist_to_binary(json:encode(NewModel))}
    catch
        _Class:Reason ->
            ReasonBin = unicode:characters_to_binary(
                io_lib:format("Patch apply failed: ~p", [Reason])
            ),
            {error, ReasonBin}
    end.

ref_apply_ops_list(Model, []) ->
    Model;
ref_apply_ops_list(Model, [Op | Rest]) ->
    ref_apply_ops_list(ref_apply_single_op(Model, Op), Rest).

ref_apply_single_op(Model, #{<<"op">> := <<"replace">>, <<"path">> := Path, <<"value">> := Value}) ->
    ref_update_at(Model, ref_parse_path(Path), fun(Container, Token) -> ref_replace_in(Container, Token, Value) end, Value);
ref_apply_single_op(Model, #{<<"op">> := <<"add">>, <<"path">> := Path, <<"value">> := Value}) ->
    ref_update_at(Model, ref_parse_path(Path), fun(Container, Token) -> ref_add_in(Container, Token, Value) end, Value);
ref_apply_single_op(Model, #{<<"op">> := <<"remove">>, <<"path">> := Path}) ->
    case ref_parse_path(Path) of
        [] -> erlang:error({cannot_remove_root, Path});
        Tokens -> ref_update_at(Model, Tokens, fun ref_remove_in/2, undefined)
    end;
ref_apply_single_op(Model, #{<<"op">> := <<"append">>, <<"path">> := Path, <<"value">> := Items})
        when is_list(Items) ->
    case ref_parse_path(Path) of
        [] -> ref_append_to(Model, Items, Path);
        Tokens ->
            ref_update_at(Model, Tokens,
                      fun(Container, Token) ->
                          Current = ref_get_in(Container, Token),
                          ref_replace_in(Container, Token, ref_append_to(Current, Items, Path))
                      end,
                      undefined)
    end;
ref_apply_single_op(_Model, Op) ->
    erlang:error({unknown_or_malformed_op, Op}).

%% Walk to the parent of the final token and apply Fun(Parent, LastToken).
%% An empty token list means the whole document: RootValue is returned.
ref_update_at(_Model, [], _Fun, RootValue) ->
    RootValue;
ref_update_at(Model, [Token], Fun, _RootValue) ->
    Fun(Model, Token);
ref_update_at(Model, [Token | Rest], Fun, RootValue) ->
    Child = ref_get_in(Model, Token),
    ref_replace_in(Model, Token, ref_update_at(Child, Rest, Fun, RootValue)).

ref_get_in(Map, Key) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> erlang:error({missing_member, Key})
    end;
ref_get_in(List, Token) when is_list(List) ->
    Index = ref_existing_index(List, Token),
    lists:nth(Index + 1, List);
ref_get_in(Other, Token) ->
    erlang:error({not_a_container, Token, Other}).

ref_replace_in(Map, Key, Value) when is_map(Map) ->
    case maps:is_key(Key, Map) of
        true -> maps:put(Key, Value, Map);
        false -> erlang:error({missing_member, Key})
    end;
ref_replace_in(List, Token, Value) when is_list(List) ->
    Index = ref_existing_index(List, Token),
    {Before, [_ | After]} = lists:split(Index, List),
    Before ++ [Value | After];
ref_replace_in(Other, Token, _Value) ->
    erlang:error({not_a_container, Token, Other}).

ref_add_in(Map, Key, Value) when is_map(Map) ->
    maps:put(Key, Value, Map);
ref_add_in(List, <<"-">>, Value) when is_list(List) ->
    List ++ [Value];
ref_add_in(List, Token, Value) when is_list(List) ->
    Index = ref_parse_index(Token),
    case Index =< length(List) of
        true ->
            {Before, After} = lists:split(Index, List),
            Before ++ [Value | After];
        false ->
            erlang:error({index_out_of_bounds, Token, length(List)})
    end;
ref_add_in(Other, Token, _Value) ->
    erlang:error({not_a_container, Token, Other}).

ref_remove_in(Map, Key) when is_map(Map) ->
    case maps:is_key(Key, Map) of
        true -> maps:remove(Key, Map);
        false -> erlang:error({missing_member, Key})
    end;
ref_remove_in(List, Token) when is_list(List) ->
    Index = ref_existing_index(List, Token),
    {Before, [_ | After]} = lists:split(Index, List),
    Before ++ After;
ref_remove_in(Other, Token) ->
    erlang:error({not_a_container, Token, Other}).

ref_append_to(List, Items, _Path) when is_list(List) ->
    List ++ Items;
ref_append_to(Other, _Items, Path) ->
    erlang:error({append_target_not_array, Path, Other}).

ref_existing_index(List, Token) ->
    Index = ref_parse_index(Token),
    case Index < length(List) of
        true -> Index;
        false -> erlang:error({index_out_of_bounds, Token, length(List)})
    end.

%% RFC 6901 array index: "0" or a decimal without leading zeros.
ref_parse_index(<<"0">>) ->
    0;
ref_parse_index(<<First, _/binary>> = Token) when First >= $1, First =< $9 ->
    case lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Token)) of
        true -> binary_to_integer(Token);
        false -> erlang:error({invalid_array_index, Token})
    end;
ref_parse_index(Token) ->
    erlang:error({invalid_array_index, Token}).


ref_parse_path(<<>>) ->
    [];
ref_parse_path(<<$/, Rest/binary>> = Pointer) ->
    [ref_unescape_segment(Segment, Pointer) || Segment <- binary:split(Rest, <<"/">>, [global])];
ref_parse_path(Pointer) when is_binary(Pointer) ->
    erlang:error({invalid_pointer, Pointer, <<"pointer must be empty or start with /">>});
ref_parse_path(Pointer) ->
    erlang:error({invalid_pointer, Pointer, <<"pointer must be a string">>}).

ref_unescape_segment(Segment, Pointer) ->
    ref_unescape_segment(Segment, Pointer, <<>>).

ref_unescape_segment(<<>>, _Pointer, Acc) -> Acc;
ref_unescape_segment(<<"~0", Rest/binary>>, Pointer, Acc) ->
    ref_unescape_segment(Rest, Pointer, <<Acc/binary, $~>>);
ref_unescape_segment(<<"~1", Rest/binary>>, Pointer, Acc) ->
    ref_unescape_segment(Rest, Pointer, <<Acc/binary, $/>>);
ref_unescape_segment(<<$~, _/binary>>, Pointer, _Acc) ->
    erlang:error({invalid_pointer, Pointer, <<"~ must be followed by 0 or 1">>});
ref_unescape_segment(<<C, Rest/binary>>, Pointer, Acc) ->
    ref_unescape_segment(Rest, Pointer, <<Acc/binary, C>>).

%% Path for a scratch file under the system temp directory.
-spec scratch_path(binary()) -> binary().
scratch_path(Name) ->
    Dir = case os:getenv("TMPDIR") of
        false -> "/tmp";
        D -> D
    end,
    Unique = integer_to_list(erlang:unique_integer([positive])),
    unicode:characters_to_binary(filename:join(Dir, "brazier_" ++ Unique ++ "_" ++ binary_to_list(Name))).

-spec write_file(binary(), binary()) -> {ok, nil} | {error, binary()}.
write_file(Path, Contents) ->
    case file:write_file(Path, Contents) of
        ok -> {ok, nil};
        {error, Reason} -> {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Run `node Script Arg` and return {ok, Output} on exit status 0, or
%% {error, Output} otherwise. A missing node binary is an error, never a skip.
-spec run_node(binary(), binary()) -> {ok, binary()} | {error, binary()}.
run_node(Script, Arg) ->
    case os:find_executable("node") of
        false ->
            {error, <<"node executable not found on PATH; the patch round-trip test requires node">>};
        Node ->
            Port = open_port({spawn_executable, Node},
                             [{args, [Script, Arg]}, exit_status, stderr_to_stdout, binary]),
            collect(Port, <<>>)
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} -> {ok, Acc};
        {Port, {exit_status, Status}} ->
            StatusBin = integer_to_binary(Status),
            {error, <<"node exited with status ", StatusBin/binary, ": ", Acc/binary>>}
    after 60000 ->
        port_close(Port),
        {error, <<"node timed out after 60s: ", Acc/binary>>}
    end.
