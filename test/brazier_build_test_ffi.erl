-module(brazier_build_test_ffi).
-export([in_deleted_directory/2]).

%% Run Fun with the current directory set to Dir (created, then deleted
%% while it is current, so file:get_cwd/0 fails with enoent), and restore
%% the current directory however Fun returns. The current directory is
%% node-wide; gleeunit runs tests one at a time.
in_deleted_directory(Dir, Fun) ->
    {ok, Old} = file:get_cwd(),
    Absolute = filename:join(Old, Dir),
    ok = file:make_dir(Absolute),
    ok = file:set_cwd(Absolute),
    try
        ok = file:del_dir(Absolute),
        {error, enoent} = file:get_cwd(),
        Fun()
    after
        ok = file:set_cwd(Old)
    end.
