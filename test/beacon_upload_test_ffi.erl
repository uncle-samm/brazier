-module(beacon_upload_test_ffi).
%% File-system helpers for upload tests. Each test works in its own fresh
%% directory under the system temp dir and removes it afterwards.
-export([fresh_dir/0, remove_dir/1, read_file/1, write_file/2, make_symlink/2,
         list_dir/1]).

fresh_dir() ->
    Base = case os:getenv("TMPDIR") of
        false -> "/tmp";
        Tmp -> Tmp
    end,
    %% unique_integer restarts on every VM boot, so a directory left behind by
    %% an earlier run could collide; random bytes make the name unique.
    Suffix = binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8), lowercase)),
    Name = "beacon_upload_test_" ++ Suffix,
    Dir = unicode:characters_to_binary(filename:join(Base, Name)),
    ok = file:make_dir(Dir),
    Dir.

remove_dir(Dir) ->
    ok = file:del_dir_r(Dir),
    nil.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Data} -> {ok, Data};
        {error, _} -> {error, nil}
    end.

write_file(Path, Data) ->
    ok = file:write_file(Path, Data),
    nil.

make_symlink(Target, Link) ->
    ok = file:make_symlink(Target, Link),
    nil.

list_dir(Dir) ->
    {ok, Names} = file:list_dir(Dir),
    lists:sort([unicode:characters_to_binary(N) || N <- Names]).
