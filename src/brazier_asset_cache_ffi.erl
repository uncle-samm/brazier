-module(brazier_asset_cache_ffi).
%% Read-mostly cache for the client JS bundle: raw bytes, gzip output and a
%% strong ETag, keyed by path and revalidated against the file on every
%% lookup (one stat per request; no read, no compression while the entry is
%% trusted).
%%
%% REVALIDATION follows git's index (Documentation/technical/racy-git.txt),
%% the same rule as the static digest cache in brazier_static_ffi:
%%
%%   * An entry is used only while the file's size, mtime, ctime, inode and
%%     device are exactly those recorded. Any change rebuilds it. Size and
%%     mtime alone (what Plug.Static's and cowboy_static's ETags hash) miss
%%     a same-size rewrite within the same second, and an atomic rename of
%%     a new bundle over the old one.
%%   * Racy-clean rule: an entry recorded less than ?RACY_SECONDS after the
%%     file's last mtime/ctime is not trusted, because an edit in the same
%%     second as the read can keep every stat field the same. Such an entry
%%     is rebuilt on every lookup until one is recorded outside the window,
%%     so a bundle is re-read for at most ?RACY_SECONDS after it is written.
%%     The time an entry is recorded is taken BEFORE the file is read, so an
%%     edit during the read also counts as racy.
%%
%% Stored in persistent_term because reads vastly outnumber writes (a write
%% happens only when the bundle is rebuilt). The cache holds at most
%% ?MAX_ENTRIES paths; the least recently stored is evicted. Misses are
%% serialised with a node-local global lock so concurrent first requests
%% compress once and the index can never lose an entry.
-export([load/2, cached_paths/0]).

-include_lib("kernel/include/file.hrl").

-define(KEY(Path), {brazier_asset_cache, Path}).
-define(INDEX, brazier_asset_cache_index).
-define(LOCK, brazier_asset_cache_lock).
-define(MAX_ENTRIES, 4).
%% Seconds after a file's last change before an entry of it is trusted.
-define(RACY_SECONDS, 2).

%% {ok, {loaded_asset, {client_asset, Raw, Gzip, Etag}, Source}} where Source
%% is asset_cached or {asset_built, not_cached | stat_changed | racily_clean}
%% (the Gleam type brazier/static.AssetSource);
%% {error, asset_not_found} | {error, {asset_read_failed, Reason}}.
%% Now is the current POSIX time in seconds (injected so tests can place an
%% entry inside or outside the racy window).
load(Path, Now) when is_binary(Path), is_integer(Now) ->
    case stat(Path) of
        {ok, Stat} ->
            case lookup(Path, Stat) of
                {trusted, Asset} -> {ok, {loaded_asset, Asset, asset_cached}};
                {untrusted, _Reason} -> locked_build(Path, Stat, Now)
            end;
        {error, _} = Error ->
            Error
    end.

%% Paths currently cached, most recently stored first.
cached_paths() ->
    persistent_term:get(?INDEX, []).

stat(Path) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular} = Info} -> {ok, stat_key(Info)};
        {ok, #file_info{}} -> {error, asset_not_found};
        {error, enoent} -> {error, asset_not_found};
        {error, enotdir} -> {error, asset_not_found};
        {error, Reason} -> {error, {asset_read_failed, format(Reason)}}
    end.

%% The fields git compares (cache_entry's stat data). mtime and ctime are in
%% seconds: read_file_info has no sub-second times, which is what the racy
%% rule covers.
stat_key(#file_info{size = Size, mtime = Mtime, ctime = Ctime,
                    inode = Inode, major_device = Device}) ->
    {Size, Mtime, Ctime, Inode, Device}.

lookup(Path, Stat) ->
    case persistent_term:get(?KEY(Path), undefined) of
        {Stat, CachedAt, Asset} ->
            case trusted(Stat, CachedAt) of
                true -> {trusted, Asset};
                false -> {untrusted, racily_clean}
            end;
        {_OtherStat, _CachedAt, _Asset} ->
            {untrusted, stat_changed};
        undefined ->
            {untrusted, not_cached}
    end.

%% git's is_racy_timestamp: an entry is racily clean when the file changed
%% no earlier than the entry was written. RACY_SECONDS widens that to the
%% coarsest common timestamp granularity.
trusted({_Size, Mtime, Ctime, _Inode, _Device}, CachedAt) ->
    CachedAt >= max(Mtime, Ctime) + ?RACY_SECONDS.

locked_build(Path, Stat, Now) ->
    global:trans({?LOCK, self()},
                 fun() ->
                     %% Another process may have built a trusted entry while
                     %% we waited; otherwise the reason is decided here, under
                     %% the lock, against the entry as it now stands.
                     case lookup(Path, Stat) of
                         {trusted, Asset} -> {ok, {loaded_asset, Asset, asset_cached}};
                         {untrusted, Reason} -> build(Path, Stat, Now, Reason)
                     end
                 end,
                 [node()]).

%% Now was taken before this read, so an edit during the read leaves the
%% entry racy (or changes its stat data) and the next lookup rebuilds it.
build(Path, Stat, Now, Reason) ->
    case file:read_file(Path) of
        {ok, Raw} ->
            Asset = {client_asset, Raw, zlib:gzip(Raw), etag(Raw)},
            store(Path, {Stat, Now, Asset}),
            {ok, {loaded_asset, Asset, {asset_built, Reason}}};
        {error, enoent} -> {error, asset_not_found};
        {error, ReadReason} -> {error, {asset_read_failed, format(ReadReason)}}
    end.

store(Path, Entry) ->
    Index = [Path | lists:delete(Path, cached_paths())],
    {Keep, Evict} = case length(Index) > ?MAX_ENTRIES of
        true -> lists:split(?MAX_ENTRIES, Index);
        false -> {Index, []}
    end,
    lists:foreach(fun(Old) -> persistent_term:erase(?KEY(Old)) end, Evict),
    persistent_term:put(?KEY(Path), Entry),
    persistent_term:put(?INDEX, Keep),
    ok.

etag(Raw) ->
    Hex = binary:part(binary:encode_hex(crypto:hash(sha256, Raw), lowercase), 0, 32),
    <<"\"", Hex/binary, "\"">>.

format(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
format(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).
