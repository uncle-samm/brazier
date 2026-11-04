-module(brazier_session_clock_test_ffi).
%% A manual wall clock for session store tests: time moves only when the
%% test advances it, so lifetime tests never sleep. One signed atomic
%% counter holds the time in milliseconds; any process can read it (the
%% store's sweeper does), and only the test writes it.
-export([new/1, now/1, advance/2]).

new(StartMs) when is_integer(StartMs) ->
    Ref = atomics:new(1, [{signed, true}]),
    ok = atomics:put(Ref, 1, StartMs),
    Ref.

now(Ref) ->
    atomics:get(Ref, 1).

%% Moving time backwards is never what a lifetime test means.
advance(Ref, Ms) when is_integer(Ms), Ms >= 0 ->
    atomics:add(Ref, 1, Ms),
    nil.
