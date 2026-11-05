-module(brazier_file_trace_test_ffi).
%% Record the calls a process makes into the modules that touch the file
%% system, for tests that prove a code path does no file I/O.
%%
%% erlang:trace/3 with `call` makes Pid report every call to a function
%% whose trace pattern is set; the patterns below cover the `file` API,
%% its NIF layer `prim_file` and simplifile's Erlang module, so any read,
%% stat or open in Pid is seen, whichever API it goes through. The
%% patterns are node-wide but only a traced process reports, and `stop`
%% removes them again. erlang:trace_delivered/1 is the flush: its reply
%% comes after every trace message Pid generated before the call, so the
%% list is complete without a sleep.
-export([start/1, stop/1]).

-define(MODULES, [file, prim_file, simplifile_erl]).

start(Pid) ->
    lists:foreach(fun(M) ->
        {module, M} = code:ensure_loaded(M),
        erlang:trace_pattern({M, '_', '_'}, true, [local])
    end, ?MODULES),
    1 = erlang:trace(Pid, true, [call]),
    nil.

%% Stop tracing Pid and return the calls it made, "module:function/arity",
%% in order. Pid may have exited already (a connection the server closed):
%% its trace flags went with it, and trace_delivered still flushes the
%% messages it generated. erlang:trace/3 raises badarg only for a process
%% that is not alive, which is asserted rather than assumed.
stop(Pid) ->
    try erlang:trace(Pid, false, [call]) of
        1 -> ok
    catch
        error:badarg -> false = erlang:is_process_alive(Pid)
    end,
    Ref = erlang:trace_delivered(Pid),
    receive {trace_delivered, Pid, Ref} -> ok end,
    lists:foreach(fun(M) ->
        erlang:trace_pattern({M, '_', '_'}, false, [local])
    end, ?MODULES),
    collect(Pid, []).

collect(Pid, Acc) ->
    receive
        {trace, Pid, call, {M, F, Args}} ->
            Call = iolist_to_binary(io_lib:format("~s:~s/~b", [M, F, length(Args)])),
            collect(Pid, [Call | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.
