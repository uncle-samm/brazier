-module(brazier_build_ffi).
-export([run_program/3, absolute_path/1, content_hash/1, exit_failure/1]).

%% Run a program without invoking a shell. This prevents build-time command
%% injection through project paths or path dependencies.
%% The working directory and arguments are UTF-8 binaries, and open_port is
%% given them as binaries: those reach the program byte for byte. A character
%% list is encoded with the VM's file name encoding instead, which is latin1
%% when the locale is not UTF-8 (a bare container), and there open_port
%% raises badarg for any character past U+00FF.
run_program(Cwd, Program0, Args) ->
    Program = unicode:characters_to_list(Program0),
    case os:find_executable(Program) of
        false ->
            {error, unicode:characters_to_binary(["Executable not found: ", Program])};
        Executable ->
            try open_port(
                    {spawn_executable, Executable},
                    [
                        {cd, Cwd},
                        {args, Args},
                        exit_status,
                        use_stdio,
                        stderr_to_stdout,
                        binary
                    ]
                ) of
                Port -> collect_port_output(Port, [])
            catch
                error:Reason ->
                    {error, unicode:characters_to_binary(
                        io_lib:format("Failed to start ~ts in ~ts: ~tp", [Program, Cwd, Reason])
                    )}
            end
    end.

collect_port_output(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port_output(Port, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, Status}} ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            {error, unicode:characters_to_binary([
                Output,
                "\nExit status: ",
                integer_to_list(Status)
            ])}
    end.

%% Path resolved against the current directory. filename:absname/1 reads the
%% current directory with a badmatch on failure, so it is read here and its
%% error returned: file:get_cwd/0 fails when the directory was deleted under
%% the VM (enoent) or a parent stopped being searchable (eacces).
absolute_path(Path) ->
    case file:get_cwd() of
        {ok, Cwd} ->
            Absolute = filename:absname(unicode:characters_to_list(Path), Cwd),
            {ok, unicode:characters_to_binary(Absolute)};
        {error, Reason} ->
            {error, unicode:characters_to_binary(
                io_lib:format("Cannot resolve ~ts: cannot read the current directory: ~ts",
                              [Path, file:format_error(Reason)])
            )}
    end.

exit_failure(Reason) ->
    io:format(standard_error, "~ts~n", [Reason]),
    erlang:halt(1).

%% The first 16 hex digits of the SHA-256 of Contents. Bundle filenames are
%% derived from their contents so identical builds produce identical names.
content_hash(Contents) when is_binary(Contents) ->
    Hex = binary:encode_hex(crypto:hash(sha256, Contents), lowercase),
    binary:part(Hex, 0, 16).
