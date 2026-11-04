-module(brazier_patch_test_ffi).
-export([random_pair/1, run_node/2, write_file/2, scratch_path/1]).

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
     <<"x~0/y">>, <<"">>, <<"name">>, <<"0">>, <<"-">>, <<"ünï"/utf8>>].

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
