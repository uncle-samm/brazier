-module(beacon_asset_cache_ffi).
%% Read-mostly cache for the client JS bundle: raw bytes, gzip output and a
%% strong ETag, keyed by path and validated against the file's size and
%% mtime on every lookup (one stat per request, no read, no compression).
%%
%% Stored in persistent_term because reads vastly outnumber writes (a write
%% happens only when the bundle is rebuilt). The cache holds at most
%% ?MAX_ENTRIES paths; the least recently stored is evicted. Misses are
%% serialised with a node-local global lock so concurrent first requests
%% compress once and the index can never lose an entry.
-export([load/1, cached_paths/0]).

-include_lib("kernel/include/file.hrl").

-define(KEY(Path), {beacon_asset_cache, Path}).
-define(INDEX, beacon_asset_cache_index).
-define(LOCK, beacon_asset_cache_lock).
-define(MAX_ENTRIES, 4).

%% {ok, {client_asset, Raw, Gzip, Etag}} | {error, asset_not_found}
%% | {error, {asset_read_failed, Reason}}
load(Path) ->
    case stat(Path) of
        {ok, Size, Mtime} ->
            case persistent_term:get(?KEY(Path), undefined) of
                {Size, Mtime, Asset} -> {ok, Asset};
                _ -> locked_build(Path, Size, Mtime)
            end;
        {error, _} = Error ->
            Error
    end.

%% Paths currently cached, most recently stored first.
cached_paths() ->
    persistent_term:get(?INDEX, []).

stat(Path) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular, size = Size, mtime = Mtime}} -> {ok, Size, Mtime};
        {ok, #file_info{}} -> {error, asset_not_found};
        {error, enoent} -> {error, asset_not_found};
        {error, enotdir} -> {error, asset_not_found};
        {error, Reason} -> {error, {asset_read_failed, format(Reason)}}
    end.

locked_build(Path, Size, Mtime) ->
    global:trans({?LOCK, self()},
                 fun() ->
                     %% Another process may have built it while we waited.
                     case persistent_term:get(?KEY(Path), undefined) of
                         {Size, Mtime, Asset} -> {ok, Asset};
                         _ -> build(Path, Size, Mtime)
                     end
                 end,
                 [node()]).

build(Path, Size, Mtime) ->
    case file:read_file(Path) of
        {ok, Raw} ->
            Asset = {client_asset, Raw, zlib:gzip(Raw), etag(Raw)},
            store(Path, {Size, Mtime, Asset}),
            {ok, Asset};
        {error, enoent} -> {error, asset_not_found};
        {error, Reason} -> {error, {asset_read_failed, format(Reason)}}
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
