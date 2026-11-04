-module(brazier_test_ffi).
-export([unique_ref/0, pd_put/2, pd_get/1, string_contains/2, do_crash/0, ensure_dir/1, suppress_logs/0, string_index_of/2, system_time_seconds/0, masked_ws_frame/2]).

%% Returns a binary string unique across every running VM, not only this
%% one. erlang:unique_integer alone restarts from the same values in each VM,
%% so two `gleam test` runs at once (another worktree, the flake gate) would
%% name the same /tmp directory and delete each other's files. The OS pid
%% tells concurrent VMs apart.
unique_ref() ->
    Pid = list_to_binary(os:getpid()),
    N = erlang:integer_to_binary(erlang:unique_integer([positive])),
    <<Pid/binary, "_", N/binary>>.

%% Put a value in the process dictionary.
pd_put(Key, Value) ->
    erlang:put(Key, Value),
    nil.

%% Get a value from the process dictionary.
pd_get(Key) ->
    erlang:get(Key).

%% Check if a binary string contains a substring.
string_contains(Haystack, Needle) ->
    case binary:match(Haystack, Needle) of
        nomatch -> false;
        _ -> true
    end.

%% Ensure a directory exists (creates it if needed).
ensure_dir(Path) ->
    case filelib:ensure_dir(<<Path/binary, "/dummy">>) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

%% Intentionally crash for testing error boundaries.
do_crash() ->
    error(intentional_test_crash).

%% Suppress OTP/Erlang logger output during tests.
suppress_logs() ->
    logger:set_primary_config(level, none),
    %% Also remove default handler to prevent any output
    logger:remove_handler(default),
    nil.

%% Find the byte offset of Needle in Haystack. Returns {ok, Pos} or {error, nil}.
string_index_of(Haystack, Needle) ->
    case binary:match(Haystack, Needle) of
        nomatch -> {error, nil};
        {Pos, _Len} -> {ok, Pos}
    end.

%% Get current system time in seconds (Unix timestamp).
system_time_seconds() ->
    erlang:system_time(second).

%% Build a masked client WebSocket frame for direct ws.decode_frame tests.
masked_ws_frame(Opcode, Payload) ->
    Len = byte_size(Payload),
    Mask = <<0, 0, 0, 0>>,
    if
        Len < 126 ->
            <<1:1, 0:3, Opcode:4, 1:1, Len:7, Mask/binary, Payload/binary>>;
        Len < 65536 ->
            <<1:1, 0:3, Opcode:4, 1:1, 126:7, Len:16, Mask/binary, Payload/binary>>;
        true ->
            <<1:1, 0:3, Opcode:4, 1:1, 127:7, Len:64, Mask/binary, Payload/binary>>
    end.
