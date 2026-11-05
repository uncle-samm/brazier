-module(brazier_dir_test_ffi).
%% A child VM for directory-listing tests.
%%
%% On macOS, OTP's own directory listing never returns for a name that
%% starts with a combining mark, and it takes the VM's file server and a
%% scheduler with it: no timer, monitor or erlang:halt/1 in that VM runs
%% afterwards (docs/design/OTP_LIST_DIR_HANG.md). A test that lists such a
%% directory in the suite's own VM would hang the suite on a regression. So
%% those tests run the call in a separate VM, started with +fnu (UTF-8 file
%% names, the mode that has the bug on macOS whatever the locale), and kill
%% it with SIGKILL when it does not answer in time: a regression fails the
%% test, it does not hang the suite.
-export([call_in_child/4, child_main/1, decoder_frees_its_result/0, is_macos/0]).

-define(MARKER, "BRAZIER_CHILD_RESULT:").

%% Apply Module:Function(Args...) in a new VM and return {ok, Result}, or
%% {error, Message} when the child does not answer within TimeoutMs (it is
%% then killed with SIGKILL), crashes, or exits without an answer. Module
%% and Function are names as binaries; Args and the result must be plain
%% terms (no pids, ports, references or funs), because they cross the VM
%% boundary as term_to_binary.
call_in_child(Module, Function, Args, TimeoutMs) when is_binary(Module),
                                                      is_binary(Function),
                                                      is_list(Args),
                                                      is_integer(TimeoutMs) ->
    Caller = self(),
    Ref = make_ref(),
    Call = {binary_to_atom(Module), binary_to_atom(Function), Args},
    %% The port lives in its own process, so nothing it sends (data, exit
    %% status, an exit signal) can reach the test process's mailbox.
    {Pid, Monitor} = spawn_monitor(fun() -> Caller ! {Ref, run_child(Call, TimeoutMs)} end),
    receive
        {Ref, Result} ->
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Pid, Reason} ->
            {error, format("The child VM runner crashed: ~tp", [Reason])}
    end.

run_child(Call, TimeoutMs) ->
    Erl = filename:join([code:root_dir(), "bin", "erl"]),
    Root = code:root_dir(),
    Paths = [Path || Path <- code:get_path(), not lists:prefix(Root, Path)],
    Encoded = base64:encode_to_string(term_to_binary(Call)),
    Eval = "brazier_dir_test_ffi:child_main(\"" ++ Encoded ++ "\").",
    Args = ["+fnu", "-noshell", "-pa" | Paths] ++ ["-eval", Eval],
    Port = open_port({spawn_executable, Erl},
                     [{args, Args}, exit_status, use_stdio, stderr_to_stdout, binary]),
    {os_pid, OsPid} = erlang:port_info(Port, os_pid),
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    collect(Port, OsPid, Deadline, TimeoutMs, []).

collect(Port, OsPid, Deadline, TimeoutMs, Acc) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            collect(Port, OsPid, Deadline, TimeoutMs, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            answer(Output, Status)
    after Remaining ->
        Killed = kill(Port, OsPid),
        Output = iolist_to_binary(lists:reverse(Acc)),
        {error, format("The child VM (os pid ~b) did not answer in ~b ms; ~ts. Output: ~ts",
                       [OsPid, TimeoutMs, Killed, Output])}
    end.

%% SIGKILL the child and wait for the port to report its exit, so no VM is
%% left behind.
kill(Port, OsPid) ->
    Kill = os:find_executable("kill"),
    KillPort = open_port({spawn_executable, Kill},
                         [{args, ["-9", integer_to_list(OsPid)]}, exit_status]),
    receive
        {KillPort, {exit_status, 0}} -> ok
    after 10000 ->
        erlang:error({kill_did_not_finish, OsPid})
    end,
    await_exit(Port, OsPid).

await_exit(Port, OsPid) ->
    receive
        {Port, {data, _}} ->
            await_exit(Port, OsPid);
        {Port, {exit_status, Status}} ->
            format("killed it with SIGKILL (exit status ~b)", [Status])
    after 10000 ->
        erlang:error({killed_child_vm_still_running, OsPid})
    end.

answer(Output, Status) ->
    case binary:match(Output, <<?MARKER>>) of
        nomatch ->
            {error, format("The child VM exited with status ~b without an answer. Output: ~ts",
                           [Status, Output])};
        {Start, Length} ->
            Rest = binary:part(Output, Start + Length, byte_size(Output) - Start - Length),
            [Encoded | _] = binary:split(Rest, <<"\n">>),
            case binary_to_term(base64:decode(Encoded)) of
                {returned, Result} ->
                    {ok, Result};
                {crashed, Class, Reason, Stack} ->
                    {error, format("The call crashed in the child VM: ~p:~tp ~tp",
                                   [Class, Reason, Stack])}
            end
    end.

%% Runs in the child VM: apply the call, print the answer, stop.
child_main(Encoded) ->
    {Module, Function, Args} = binary_to_term(base64:decode(Encoded)),
    Answer = try {returned, apply(Module, Function, Args)}
             catch Class:Reason:Stack -> {crashed, Class, Reason, Stack}
             end,
    io:put_chars([?MARKER, base64:encode(term_to_binary(Answer)), "\n"]),
    erlang:halt(0).

%% True when prim_file:internal_native2name/1 hands back a list whose cells
%% the next allocation reuses: the OTP bug brazier_dir_ffi works around.
%% The decoded list is never printed or copied, only compared by address,
%% so the probe itself cannot hang.
decoder_frees_its_result() ->
    Decoded = prim_file:internal_native2name(<<204, 129, $b>>),
    Fresh = [fresh | Decoded],
    erts_debug:same(Fresh, Decoded).

is_macos() ->
    os:type() =:= {unix, darwin}.

format(Format, Args) ->
    unicode:characters_to_binary(io_lib:format(Format, Args)).
