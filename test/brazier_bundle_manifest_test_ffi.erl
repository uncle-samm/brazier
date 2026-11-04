-module(brazier_bundle_manifest_test_ffi).
%% Set a file's mtime, so a test can place a manifest's last change in a
%% second of its choosing (the bundle-name cache trusts only a manifest
%% whose mtime is older than the second it was read in).
-export([set_mtime/2]).

-include_lib("kernel/include/file.hrl").

set_mtime(Path, Posix) ->
    case file:write_file_info(Path, #file_info{mtime = Posix, atime = Posix}, [{time, posix}]) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.
