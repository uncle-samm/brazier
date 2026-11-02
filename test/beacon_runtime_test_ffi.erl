-module(beacon_runtime_test_ffi).
-export([fake_socket/0, now_us/0]).

%% Returns a fake socket (nil) for testing.
%% Used when constructing Request(Connection) for init_from_request tests.
fake_socket() ->
    nil.

%% Monotonic time in microseconds, used by the runtime benchmark.
now_us() ->
    erlang:monotonic_time(microsecond).
