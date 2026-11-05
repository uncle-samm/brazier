-module(brazier_dev_build_test_ffi).
%% Helpers for brazier/dev_build_test, which runs on fresh peer nodes.
-export([set_cwd/1]).

%% Change the node's working directory, so `ssr.client_assets_dir()`
%% (the relative "priv/static") names a scratch directory. Only called on a
%% peer: its code paths are absolute, so loading modules is unaffected.
set_cwd(Dir) ->
    case file:set_cwd(Dir) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.
