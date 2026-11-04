-module(brazier_http_routes_test_ffi).
-export([make_fifo/1]).

%% Creates a named pipe at Path with mkfifo(1). Reading a FIFO blocks until
%% a writer appears, so a static server that opened one would hang: the
%% test proves the server never opens it.
make_fifo(Path) when is_binary(Path) ->
    Output = os:cmd("mkfifo '" ++ binary_to_list(Path) ++ "' 2>&1 && echo ok"),
    case string:trim(Output) of
        "ok" -> {ok, nil};
        Other -> {error, unicode:characters_to_binary(Other)}
    end.
