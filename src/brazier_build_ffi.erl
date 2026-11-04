-module(brazier_build_ffi).
-export([run_program/3, absolute_path/1, content_hash/1, exit_failure/1]).

%% Run a program without invoking a shell. This prevents build-time command
%% injection through project paths or path dependencies.
%% Paths and arguments are UTF-8 binaries. They are converted to character
%% lists, not byte lists, so a non-ASCII path or argument reaches the program
%% as the same UTF-8 text instead of each byte re-encoded as a character.
run_program(Cwd0, Program0, Args0) ->
    Cwd = unicode:characters_to_list(Cwd0),
    Program = unicode:characters_to_list(Program0),
    Args = [unicode:characters_to_list(Arg) || Arg <- Args0],
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

absolute_path(Path) ->
    {ok, unicode:characters_to_binary(filename:absname(unicode:characters_to_list(Path)))}.

exit_failure(Reason) ->
    io:format(standard_error, "~ts~n", [Reason]),
    erlang:halt(1).

%% The first 16 hex digits of the SHA-256 of Contents. Bundle filenames are
%% derived from their contents so identical builds produce identical names.
content_hash(Contents) when is_binary(Contents) ->
    Hex = binary:encode_hex(crypto:hash(sha256, Contents), lowercase),
    binary:part(Hex, 0, 16).
