-module(brazier_bundle_manifest_ffi).
%% Read-mostly cache of the bundle name in `brazier_client.manifest`, keyed
%% by the manifest path. Every page render and every join asks for the name,
%% and it changes only when `brazier/build` runs, so a lookup is one stat of
%% the manifest instead of a read (the pattern of brazier_asset_cache_ffi).
%%
%% An entry is trusted only when the manifest's stat (size, mtime, inode)
%% is unchanged AND its mtime is older than the second in which the
%% manifest was stamped before being read. mtime has a resolution of one
%% second, and a rebuild writes a name of the same length, so a manifest
%% rewritten in the second it was read has the same stat as before; such
%% an entry is never trusted, and the manifest is read again (git's
%% "racy clean" rule for its index, Documentation/technical/racy-git.txt).
%%
%% Stored in persistent_term because reads vastly outnumber writes. At most
%% ?MAX_ENTRIES manifests are cached; the least recently stored is evicted.
%% Stores are serialised with a node-local global lock so the index can
%% never lose an entry (an entry missing from the index would never be
%% evicted).
-export([stamp/1, cached/2, remember/3, cached_manifests/0]).

-include_lib("kernel/include/file.hrl").

-define(KEY(Path), {brazier_bundle_manifest, Path}).
-define(INDEX, brazier_bundle_manifest_index).
-define(LOCK, brazier_bundle_manifest_lock).
-define(MAX_ENTRIES, 4).

%% The manifest's stat, taken before it is read. {error, nil} when it
%% cannot be stat'ed: the caller then reads it, and the read reports why.
stamp(Path) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, size = Size, mtime = Mtime, inode = Inode}} ->
            {ok, {manifest_stamp, Size, Mtime, Inode, erlang:system_time(second)}};
        {ok, #file_info{}} -> {error, nil};
        {error, _} -> {error, nil}
    end.

%% The cached name for a manifest whose stamp is `Stamp`, if the entry can
%% be trusted (see the module doc).
cached(Path, {manifest_stamp, Size, Mtime, Inode, _Now}) ->
    case persistent_term:get(?KEY(Path), undefined) of
        {{Size, Mtime, Inode}, StampedAt, Name} when Mtime < StampedAt -> {ok, Name};
        _ -> {error, nil}
    end.

%% Remember the name read from a manifest after `Stamp` was taken. A
%% manifest changed between the stamp and the read has a newer stat than
%% the stamp, so the entry is simply never hit. A manifest modified in the
%% stamp's second (or later, with a skewed clock) is not stored at all: it
%% could not be trusted, and storing it would rewrite a persistent_term
%% (a global GC) on every lookup.
remember(_Path, {manifest_stamp, _Size, Mtime, _Inode, StampedAt}, _Name)
        when Mtime >= StampedAt ->
    nil;
remember(Path, {manifest_stamp, Size, Mtime, Inode, StampedAt}, Name) ->
    Entry = {{Size, Mtime, Inode}, StampedAt, Name},
    global:trans({?LOCK, self()}, fun() -> store(Path, Entry) end, [node()]),
    nil.

%% Manifest paths currently cached, most recently stored first.
cached_manifests() ->
    persistent_term:get(?INDEX, []).

store(Path, Entry) ->
    Index = [Path | lists:delete(Path, cached_manifests())],
    {Keep, Evict} = case length(Index) > ?MAX_ENTRIES of
        true -> lists:split(?MAX_ENTRIES, Index);
        false -> {Index, []}
    end,
    lists:foreach(fun(Old) -> persistent_term:erase(?KEY(Old)) end, Evict),
    persistent_term:put(?KEY(Path), Entry),
    persistent_term:put(?INDEX, Keep),
    ok.
