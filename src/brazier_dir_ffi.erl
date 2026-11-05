-module(brazier_dir_ffi).
%% Directory listing that cannot hang the VM.
%%
%% On macOS every OTP directory listing decodes each name with
%% prim_file:internal_native2name/1, which normalises it toward NFC. A name
%% that starts with a combining mark (U+0301 and the like) makes that decoder
%% return a list whose cells were already freed (cleanup_norm in
%% erts/emulator/beam/erl_unicode.c never writes its heap pointer back), so
%% the next allocation turns the name into a cyclic term. file:list_dir/1,
%% file:list_dir_all/1, file:del_dir_r/1, filelib:wildcard/1 and simplifile's
%% read_directory, get_files and delete then never return, and the scheduler
%% and file_server_2 stay stuck with them. The full analysis and the upstream
%% report draft are in docs/design/OTP_LIST_DIR_HANG.md.
%%
%% No in-VM listing avoids that decoder: prim_file:list_dir_nif/1 is not
%% exported. So this module lists with find(1), started without a shell
%% (open_port spawn_executable), and reads the names as the raw bytes find
%% prints, NUL-terminated. A name the VM never decodes cannot trip the bug.
%% Reading, writing and deleting a file by a binary path encode the name, not
%% decode it, and are not affected.
%%
%% Every failure is an {error, Message} naming the path: a path that is not
%% a directory, find missing or failing, output that is not the listing
%% asked for, and (for list/1) a name that is not valid UTF-8, which a Gleam
%% String cannot hold. Nothing is skipped.
%%
%% Brazier lists directories only at build, dev and lint time, never while it
%% serves requests, so the cost of a find process per directory is spent
%% there.
-export([list/1, delete_tree/1, parse_listing/2]).

-include_lib("kernel/include/file.hrl").

-define(CONTEXT, <<"brazier.dir">>).

%% The names directly inside Dir (a UTF-8 binary), as UTF-8 binaries, in the
%% order find prints them. A symlink to a directory is listed like the
%% directory, as file:list_dir/1 does.
list(Dir) when is_binary(Dir) ->
    case list_raw(Dir) of
        {ok, Names} -> decode_names(Dir, Names);
        {error, _} = Error -> Error
    end.

%% list/1 without the UTF-8 check: the names as the bytes the file system
%% holds. delete_tree/1 uses it, because a path it only hands back to the
%% file system as a binary does not need to be text.
list_raw(Dir) when is_binary(Dir) ->
    case directory_check(Dir) of
        ok ->
            Root = find_root(Dir),
            brazier_log_ffi:debug(?CONTEXT, "Listing ~ts with find", [show(Dir)]),
            case run_find(Dir, Root) of
                {ok, Output} -> split_listing(Dir, Root, Output);
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% The names in Output, the bytes `find -H Root -mindepth 1 -maxdepth 1
%% -print0` printed for Dir, decoded as UTF-8. Exported so a test can feed
%% it output no file system it runs on can produce (a name that is not
%% valid UTF-8, which APFS refuses to create).
parse_listing(Dir, Output) when is_binary(Dir), is_binary(Output) ->
    case split_listing(Dir, find_root(Dir), Output) of
        {ok, Names} -> decode_names(Dir, Names);
        {error, _} = Error -> Error
    end.

%% Delete Path and, when it is a directory, everything below it. A symlink
%% is deleted, never followed. A path that does not exist is an error; the
%% caller decides whether a missing path is acceptable before calling.
delete_tree(Path) when is_binary(Path) ->
    case file:read_link_info(Path, [raw]) of
        {ok, #file_info{type = directory}} ->
            case list_raw(Path) of
                {ok, Names} ->
                    case delete_children(Path, Names) of
                        ok -> delete_empty_directory(Path);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {ok, #file_info{}} ->
            case file:delete(Path, [raw]) of
                ok -> {ok, nil};
                {error, Reason} -> failure("delete", Path, Reason)
            end;
        {error, Reason} ->
            failure("inspect", Path, Reason)
    end.

delete_children(_Dir, []) ->
    ok;
delete_children(Dir, [Name | Rest]) ->
    case delete_tree(<<Dir/binary, $/, Name/binary>>) of
        {ok, nil} -> delete_children(Dir, Rest);
        {error, _} = Error -> Error
    end.

delete_empty_directory(Path) ->
    case file:del_dir(Path) of
        ok -> {ok, nil};
        {error, Reason} -> failure("delete the directory", Path, Reason)
    end.

directory_check(Dir) ->
    case file:read_file_info(Dir, [raw]) of
        {ok, #file_info{type = directory}} ->
            ok;
        {ok, #file_info{type = Type}} ->
            message("Cannot list ~ts: it is not a directory (its type is ~p)",
                    [show(Dir), Type]);
        {error, Reason} ->
            failure("list", Dir, Reason)
    end.

%% The path to hand find: without trailing slashes, so the paths it prints
%% are Root/Name, and with ./ in front of a relative path that starts with
%% -, which find would read as an option.
find_root(Dir) ->
    Trimmed = trim_trailing_slashes(Dir),
    case Trimmed of
        <<"-", _/binary>> -> <<"./", Trimmed/binary>>;
        _ -> Trimmed
    end.

trim_trailing_slashes(<<>>) ->
    <<>>;
trim_trailing_slashes(<<"/">>) ->
    <<"/">>;
trim_trailing_slashes(Dir) ->
    case binary:last(Dir) of
        $/ -> trim_trailing_slashes(binary:part(Dir, 0, byte_size(Dir) - 1));
        _ -> Dir
    end.

run_find(Dir, Root) ->
    case os:find_executable("find") of
        false ->
            message("Cannot list ~ts: find is not on the PATH. Brazier lists "
                    "directories with find(1) because OTP's own listing hangs "
                    "on macOS for a name that starts with a combining mark",
                    [show(Dir)]);
        Find ->
            Args = [<<"-H">>, Root, <<"-mindepth">>, <<"1">>,
                    <<"-maxdepth">>, <<"1">>, <<"-print0">>],
            try open_port({spawn_executable, Find},
                          [{args, Args}, exit_status, use_stdio,
                           stderr_to_stdout, binary]) of
                Port ->
                    %% Unlinked, so a caller that traps exits gets no
                    %% {'EXIT', Port, normal} in its mailbox when find
                    %% exits. The port still closes if the caller dies.
                    unlink(Port),
                    receive {'EXIT', Port, _} -> ok after 0 -> ok end,
                    collect(Dir, Port, [])
            catch
                error:Reason ->
                    message("Cannot list ~ts: cannot start ~ts: ~tp",
                            [show(Dir), Find, Reason])
            end
    end.

collect(Dir, Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Dir, Port, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, Status}} ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            message("Cannot list ~ts: find exited with status ~b: ~ts",
                    [show(Dir), Status, show(Output)])
    end.

%% Each entry find printed is Root/Name followed by a NUL. Anything else
%% (a line find wrote to stderr, a name with a slash) means the output is
%% not the listing asked for, and is an error rather than a guess.
split_listing(Dir, Root, Output) ->
    Prefix = case Root of
        <<"/">> -> <<"/">>;
        _ -> <<Root/binary, $/>>
    end,
    case Output of
        <<>> ->
            {ok, []};
        _ ->
            case binary:last(Output) of
                0 ->
                    Entries = binary:split(Output, <<0>>, [global, trim]),
                    names(Dir, Prefix, Entries, []);
                _ ->
                    message("Cannot list ~ts: find printed output that does not "
                            "end in a NUL: ~ts", [show(Dir), show(Output)])
            end
    end.

names(_Dir, _Prefix, [], Acc) ->
    {ok, lists:reverse(Acc)};
names(Dir, Prefix, [Entry | Rest], Acc) ->
    Size = byte_size(Prefix),
    case Entry of
        <<Prefix:Size/binary, Name/binary>> when Name =/= <<>> ->
            case binary:match(Name, <<"/">>) of
                nomatch -> names(Dir, Prefix, Rest, [Name | Acc]);
                _ -> unexpected_entry(Dir, Entry)
            end;
        _ ->
            unexpected_entry(Dir, Entry)
    end.

unexpected_entry(Dir, Entry) ->
    message("Cannot list ~ts: find printed ~ts, which is not an entry of it",
            [show(Dir), show(Entry)]).

decode_names(Dir, Names) ->
    case [Name || Name <- Names, not is_utf8(Name)] of
        [] ->
            {ok, Names};
        [Bad | _] ->
            message("Cannot list ~ts: the name ~w is not valid UTF-8, so Brazier "
                    "cannot hold it as a path; rename it", [show(Dir), Bad])
    end.

is_utf8(Bytes) ->
    unicode:characters_to_binary(Bytes) =:= Bytes.

%% Bytes as text for a message: as they are when they are UTF-8, as an
%% Erlang binary literal otherwise.
show(Bytes) ->
    case is_utf8(Bytes) of
        true -> Bytes;
        false -> io_lib:format("~w", [Bytes])
    end.

failure(Operation, Path, Reason) ->
    message("Cannot ~ts ~ts: ~ts", [Operation, show(Path), file:format_error(Reason)]).

message(Format, Args) ->
    Text = unicode:characters_to_binary(io_lib:format(Format, Args)),
    brazier_log_ffi:error(?CONTEXT, Text),
    {error, Text}.
