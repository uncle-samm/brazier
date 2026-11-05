-module(brazier_static_ffi).
%% File access for static file serving (brazier/static.gleam).
%%
%% A static file is never loaded into memory whole. file_digest/4 reads it
%% in bounded chunks to compute its content hash (the ETag) and its length,
%% and the response is then written with file:sendfile/5 by the HTTP writer
%% (brazier_transport_ffi:send_file/4).
%%
%% Only regular files are served, as Plug.Static does (`regular_file_info`):
%% a directory, FIFO, socket or device is reported as not_a_file, so a FIFO
%% placed in the static directory can never block a connection on open.
%%
%% DIGEST CACHE. Hashing the whole file on every request (a 304 included)
%% makes each request cost a full read of the file. The digest is cached in
%% the ETS table brazier_static_digests, keyed by path, next to the stat data
%% it was computed from, the way git's index caches blob ids against stat
%% data (Documentation/technical/racy-git.txt):
%%
%%   * An entry is used only while the file's size, mtime, ctime, inode and
%%     device are exactly those recorded. Any change re-hashes the file.
%%   * Racy-clean rule: an entry recorded less than ?RACY_SECONDS after the
%%     file's last mtime/ctime is not trusted. Timestamps have a granularity
%%     of one second (two on FAT), so an edit in the same second as the hash
%%     can keep every stat field the same; git re-hashes such "racily clean"
%%     entries and so does this cache. The time an entry was recorded is
%%     taken BEFORE the file is read, so an edit during the read also counts
%%     as racy.
%%   * The table is bounded: once it holds more than Capacity entries the
%%     excess entries are evicted (and logged at debug) right after the
%%     insert.
%%   * The table is owned by the node-wide owner of brazier_ets_ffi (created
%%     with ensure_table/2), not by the request process that first fills it,
%%     so it outlives every request. When the table cannot be had, the
%%     request fails with cache_unavailable: there is no silent fallback to
%%     uncached hashing.
-export([file_digest/4, now_seconds/0, cache_size/0]).

-include_lib("kernel/include/file.hrl").

-define(CHUNK_BYTES, 65536).
-define(TABLE, brazier_static_digests).
-define(TABLE_NAME, <<"brazier_static_digests">>).
%% Seconds after a file's last change before a digest of it is trusted.
-define(RACY_SECONDS, 2).

%% {ok, {digest, Length, HashPrefixHex, Source}} where HashPrefixHex is the
%% lowercase hex SHA-256 of the file truncated to HexChars characters,
%% Length is its byte length, and Source is `cached` or
%% {hashed, not_cached | stat_changed | racily_clean} (the Gleam type
%% brazier/static.DigestSource);
%% {error, not_a_file} for a missing path (a name too long included) or
%% anything but a regular file;
%% {error, {read_failed, Bin}} when the file exists but cannot be read;
%% {error, {cache_unavailable, Bin}} when the digest table cannot be had.
%% Now is the current POSIX time in seconds (injected so tests can place an
%% entry inside or outside the racy window); Capacity bounds the table.
file_digest(Path, HexChars, Now, Capacity)
  when is_binary(Path), is_integer(HexChars), HexChars > 0, HexChars =< 64,
       is_integer(Now), is_integer(Capacity), Capacity > 0 ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular} = Info} ->
            case table() of
                {ok, Tab} -> digest_regular(Tab, Path, stat_key(Info), HexChars, Now, Capacity);
                {error, Reason} -> {error, {cache_unavailable, Reason}}
            end;
        {ok, #file_info{}} ->
            {error, not_a_file};
        %% enametoolong: the client sent a segment longer than the file
        %% system allows. No file can have that name, so it is missing,
        %% not a server failure (Plug.Static passes on any stat error).
        {error, Missing} when Missing =:= enoent; Missing =:= enotdir;
                              Missing =:= enametoolong ->
            {error, not_a_file};
        {error, Reason} ->
            {error, {read_failed, format(Reason)}}
    end.

now_seconds() ->
    erlang:system_time(second).

%% Entries in the digest table (0 before it exists). For tests.
cache_size() ->
    case ets:info(?TABLE, size) of
        undefined -> 0;
        Size -> Size
    end.

%% The fields git compares (cache_entry's stat data). mtime and ctime are in
%% seconds: read_file_info has no sub-second times, which is what the racy
%% rule covers.
stat_key(#file_info{size = Size, mtime = Mtime, ctime = Ctime,
                    inode = Inode, major_device = Device}) ->
    {Size, Mtime, Ctime, Inode, Device}.

digest_regular(Tab, Path, Stat, HexChars, Now, Capacity) ->
    try ets:lookup(Tab, Path) of
        [{Path, Stat, Length, Hex, CachedAt}] ->
            case trusted(Stat, CachedAt) of
                true -> {ok, {digest, Length, binary:part(Hex, 0, HexChars), cached}};
                false -> hash_and_store(Tab, Path, Stat, HexChars, Now, Capacity, racily_clean)
            end;
        [{Path, _OtherStat, _Length, _Hex, _CachedAt}] ->
            hash_and_store(Tab, Path, Stat, HexChars, Now, Capacity, stat_changed);
        [] ->
            hash_and_store(Tab, Path, Stat, HexChars, Now, Capacity, not_cached)
    catch
        error:badarg -> {error, {cache_unavailable, <<"the digest table was deleted">>}}
    end.

%% git's is_racy_timestamp: an entry is racily clean when the file changed
%% no earlier than the entry was written. RACY_SECONDS widens that to the
%% coarsest common timestamp granularity.
trusted({_Size, Mtime, Ctime, _Inode, _Device}, CachedAt) ->
    CachedAt >= max(Mtime, Ctime) + ?RACY_SECONDS.

hash_and_store(Tab, Path, Stat, HexChars, Now, Capacity, Reason) ->
    case hash_file(Path) of
        {ok, Length, Hex} ->
            true = ets:insert(Tab, {Path, Stat, Length, Hex, Now}),
            ok = evict_excess(Tab, Path, Capacity),
            {ok, {digest, Length, binary:part(Hex, 0, HexChars), {hashed, Reason}}};
        {error, _} = Error ->
            Error
    end.

%% Evict entries other than Keep until the table is back at Capacity. The
%% number of evictions is fixed up front, so concurrent inserts cannot keep
%% one caller looping.
evict_excess(Tab, Keep, Capacity) ->
    case ets:info(Tab, size) of
        Size when is_integer(Size), Size > Capacity ->
            evict(Tab, Keep, ets:first(Tab), Size - Capacity);
        _ ->
            ok
    end.

evict(_Tab, _Keep, _Key, 0) ->
    ok;
evict(_Tab, _Keep, '$end_of_table', _Left) ->
    ok;
evict(Tab, Keep, Keep, Left) ->
    evict(Tab, Keep, ets:next(Tab, Keep), Left);
evict(Tab, Keep, Key, Left) ->
    Next = ets:next(Tab, Key),
    true = ets:delete(Tab, Key),
    brazier_log_ffi:debug(<<"brazier.static">>, "digest cache full: evicted ~ts", [Key]),
    evict(Tab, Keep, Next, Left - 1).

table() ->
    case ets:whereis(?TABLE) of
        undefined ->
            case brazier_ets_ffi:ensure_table(?TABLE_NAME, ets_set) of
                {ok, ?TABLE} -> {ok, ?TABLE};
                {error, Reason} -> {error, format(Reason)}
            end;
        _Tid ->
            {ok, ?TABLE}
    end.

hash_file(Path) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            Result = hash_chunks(Fd, crypto:hash_init(sha256), 0),
            case file:close(Fd) of
                ok -> ok;
                {error, CloseReason} ->
                    brazier_log_ffi:warning(<<"brazier.static">>,
                                           "closing ~ts failed: ~p", [Path, CloseReason])
            end,
            case Result of
                {ok, Length, Digest} ->
                    {ok, Length, string:lowercase(binary:encode_hex(Digest))};
                {error, Reason} ->
                    {error, {read_failed, format(Reason)}}
            end;
        {error, Reason} ->
            {error, {read_failed, format(Reason)}}
    end.

hash_chunks(Fd, Ctx, Length) ->
    case file:read(Fd, ?CHUNK_BYTES) of
        {ok, Data} -> hash_chunks(Fd, crypto:hash_update(Ctx, Data), Length + byte_size(Data));
        eof -> {ok, Length, crypto:hash_final(Ctx)};
        {error, Reason} -> {error, Reason}
    end.

format(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
format(Reason) -> list_to_binary(io_lib:format("~p", [Reason])).
