-module(beacon_upload_ffi).
-export([random_token/0, write_new_file/2, read_regular_file/1,
         binary_split/2, binary_split_once/2]).

%% 128 random bits as 32 lower-case hex digits: a stored upload's name.
random_token() ->
    binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).

%% Create Path exclusively (O_EXCL: an existing file or symlink is never
%% opened, so nothing is overwritten), as Plug.Upload does. A failed write
%% removes the partial file.
write_new_file(Path, Data) ->
    case validate_path(Path) of
        {error, Msg} ->
            beacon_log_ffi:error(<<"beacon.upload">>, "Upload path traversal blocked: path=~ts reason=~ts",
                                 [Path, Msg]),
            {error, list_to_binary(Msg)};
        ok ->
            case file:open(Path, [write, exclusive, raw, binary]) of
                {error, Reason} ->
                    beacon_log_ffi:error(<<"beacon.upload">>, "Upload create failed: path=~ts reason=~p",
                                         [Path, Reason]),
                    {error, reason(Reason)};
                {ok, Fd} ->
                    Written = file:write(Fd, Data),
                    Closed = file:close(Fd),
                    case {Written, Closed} of
                        {ok, ok} -> {ok, nil};
                        _ ->
                            beacon_log_ffi:error(<<"beacon.upload">>, "Upload write failed: path=~ts write=~p close=~p",
                                                 [Path, Written, Closed]),
                            case file:delete(Path) of
                                ok -> ok;
                                {error, DeleteReason} ->
                                    beacon_log_ffi:error(<<"beacon.upload">>, "Cannot remove partial upload: path=~ts reason=~p",
                                                         [Path, DeleteReason])
                            end,
                            {error, <<"write failed">>}
                    end
            end
    end.

%% Read Path only if it is a regular file (not a symlink, directory or
%% device).
read_regular_file(Path) ->
    case validate_path(Path) of
        {error, Msg} -> {error, list_to_binary(Msg)};
        ok ->
            case file:read_link_info(Path) of
                {ok, Info} when element(3, Info) =:= regular ->
                    case file:read_file(Path) of
                        {ok, Data} -> {ok, Data};
                        {error, Reason} -> {error, reason(Reason)}
                    end;
                {ok, Info} ->
                    {error, list_to_binary(io_lib:format("not a regular file (~p)",
                                                         [element(3, Info)]))};
                {error, Reason} -> {error, reason(Reason)}
            end
    end.

validate_path(Path) when is_binary(Path) ->
    case lists:member(<<"..">>, filename:split(Path)) of
        true -> {error, "path traversal (..) is not allowed"};
        false -> ok
    end.

reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

%% Split binary data on a separator, returning list of parts.
binary_split(Data, Separator) ->
    binary:split(Data, Separator, [global]).

%% Split binary data on separator, returning first occurrence as {Before, After}.
binary_split_once(Data, Separator) ->
    case binary:split(Data, Separator) of
        [Before, After] -> {ok, {Before, After}};
        _ -> {error, nil}
    end.
