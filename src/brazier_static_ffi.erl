-module(brazier_static_ffi).
%% File access for static file serving (brazier/static.gleam).
%%
%% A static file is never loaded into memory whole. file_digest/2 reads it
%% in bounded chunks to compute its content hash (the ETag) and its length,
%% and the response is then written with file:sendfile/5 by the HTTP writer
%% (brazier_transport_ffi:send_file/4).
%%
%% Only regular files are served, as Plug.Static does (`regular_file_info`):
%% a directory, FIFO, socket or device is reported as not_a_file, so a FIFO
%% placed in the static directory can never block a connection on open.
-export([file_digest/2]).

-include_lib("kernel/include/file.hrl").

-define(CHUNK_BYTES, 65536).

%% {ok, {Length, HashPrefixHex}} where HashPrefixHex is the lowercase hex
%% SHA-256 of the bytes read, truncated to HexChars characters, and Length
%% is the number of bytes read (the file's size at the time it was read);
%% {error, not_a_file} for a missing path or anything but a regular file;
%% {error, {read_failed, Bin}} when the file exists but cannot be read.
file_digest(Path, HexChars)
  when is_binary(Path), is_integer(HexChars), HexChars > 0, HexChars =< 64 ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{type = regular}} ->
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
                            Hex = string:lowercase(binary:encode_hex(Digest)),
                            {ok, {Length, binary:part(Hex, 0, HexChars)}};
                        {error, Reason} ->
                            {error, {read_failed, format(Reason)}}
                    end;
                {error, Reason} ->
                    {error, {read_failed, format(Reason)}}
            end;
        {ok, #file_info{}} ->
            {error, not_a_file};
        {error, Missing} when Missing =:= enoent; Missing =:= enotdir ->
            {error, not_a_file};
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
