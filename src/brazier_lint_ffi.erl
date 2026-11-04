-module(brazier_lint_ffi).
-export([stop_with_code/1]).

%% Gracefully stop the BEAM VM with an exit code.
%% Uses timer:sleep to allow logger to flush before halting.
stop_with_code(Code) ->
    timer:sleep(100),
    erlang:halt(Code).
