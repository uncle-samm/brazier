-module(brazier_integration_test_ffi).
-export([response_401/1]).

%% Create a Gleam HTTP response with the given status code.
%% Matches gleam_http's Response type: {response, Status, Headers, Body}
%% Body is server.Bytes(bytes_tree)
response_401(Status) ->
    Body = {bytes, gleam@bytes_tree:from_string(<<"Unauthorized">>)},
    {response, Status, [], Body}.
