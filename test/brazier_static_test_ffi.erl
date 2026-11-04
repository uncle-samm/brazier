-module(brazier_static_test_ffi).
%% Test helpers for brazier/static's digest cache.
-export([set_mtime/2]).

-include_lib("kernel/include/file.hrl").

%% Set a file's mtime (POSIX seconds). The kernel also moves its ctime.
set_mtime(Path, Mtime) when is_binary(Path), is_integer(Mtime) ->
    case file:write_file_info(Path, #file_info{mtime = Mtime}, [{time, posix}]) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.
