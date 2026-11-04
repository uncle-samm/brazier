-module(brazier_codegen_ffi).
-export([get_args/0]).

%% Get command line arguments as a list of binaries.
%% init:get_plain_arguments() returns charlists, we convert to binaries.
get_args() ->
    Args = init:get_plain_arguments(),
    [unicode:characters_to_binary(A) || A <- Args].
