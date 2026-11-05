-module(brazier_runtime_test_ffi).
-export([fake_socket/0, now_us/0, new_links/1]).

%% Returns a fake socket (nil) for testing.
%% Used when constructing Request(Connection) for init_from_request tests.
fake_socket() ->
    nil.

%% Monotonic time in microseconds, used by the runtime benchmark.
now_us() ->
    erlang:monotonic_time(microsecond).

%% Run Start and return {Result, Pids}: the processes Start linked to the
%% calling process, so a test can wait for a runtime that
%% runtime.start_and_connect started without handing back its pid.
new_links(Start) ->
    {links, Before} = erlang:process_info(self(), links),
    Result = Start(),
    {links, After} = erlang:process_info(self(), links),
    {Result, [Pid || Pid <- After, is_pid(Pid), not lists:member(Pid, Before)]}.
