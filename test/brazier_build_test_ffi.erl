-module(brazier_build_test_ffi).
-export([in_deleted_directory/2, run_offline/3]).

%% Run Fun with the current directory set to Dir (created, then deleted
%% while it is current, so file:get_cwd/0 fails with enoent), and restore
%% the current directory however Fun returns. The current directory is
%% node-wide; gleeunit runs tests one at a time.
in_deleted_directory(Dir, Fun) ->
    {ok, Old} = file:get_cwd(),
    Absolute = filename:join(Old, Dir),
    ok = file:make_dir(Absolute),
    ok = file:set_cwd(Absolute),
    try
        ok = file:del_dir(Absolute),
        {error, enoent} = file:get_cwd(),
        Fun()
    after
        ok = file:set_cwd(Old)
    end.

%% Run Program in Cwd with every HTTP(S) proxy variable pointing at a
%% localhost port nothing listens on, and the no-proxy lists removed, so any
%% request the program makes to Hex is refused at once instead of reaching
%% the network. The port is one the OS just handed out and was closed again.
%% Output and exit status come back like brazier_build_ffi:run_program/3.
run_offline(Cwd0, Program0, Args0) ->
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Proxy = "http://127.0.0.1:" ++ integer_to_list(Port),
    Env =
        [{Name, Proxy} || Name <- ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY",
                                   "http_proxy", "ALL_PROXY", "all_proxy"]]
        ++ [{"NO_PROXY", false}, {"no_proxy", false}],
    Cwd = unicode:characters_to_list(Cwd0),
    Args = [unicode:characters_to_list(Arg) || Arg <- Args0],
    Executable = os:find_executable(unicode:characters_to_list(Program0)),
    true = is_list(Executable),
    Child = open_port(
        {spawn_executable, Executable},
        [{cd, Cwd}, {args, Args}, {env, Env}, exit_status, use_stdio,
         stderr_to_stdout, binary]
    ),
    collect(Child, []).

collect(Child, Acc) ->
    receive
        {Child, {data, Data}} ->
            collect(Child, [Data | Acc]);
        {Child, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {Child, {exit_status, Status}} ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            {error, unicode:characters_to_binary(
                [Output, "\nExit status: ", integer_to_list(Status)])}
    end.
