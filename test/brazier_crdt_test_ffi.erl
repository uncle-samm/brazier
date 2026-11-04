-module(brazier_crdt_test_ffi).
-export([reductions/1]).

%% The reductions the calling process spends running Fun. Reductions count
%% work done, not time, so a cost bound on them does not depend on how
%% loaded the machine is.
reductions(Fun) ->
    {reductions, Before} = erlang:process_info(self(), reductions),
    _ = Fun(),
    {reductions, After} = erlang:process_info(self(), reductions),
    After - Before.
