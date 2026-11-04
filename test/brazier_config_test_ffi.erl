-module(brazier_config_test_ffi).
%% Environment helpers for config tests. Each setter returns the previous
%% value so the test can restore it.
-export([put_env/2, restore_env/2, free_port/0, port_is_free/1]).

%% A port that was free a moment ago (bound to 0, read back, closed).
free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.

%% True when nothing is listening on Port.
port_is_free(Port) ->
    case gen_tcp:listen(Port, [{reuseaddr, true}]) of
        {ok, Socket} ->
            ok = gen_tcp:close(Socket),
            true;
        {error, eaddrinuse} ->
            false
    end.

put_env(Name, Value) ->
    Previous = os:getenv(binary_to_list(Name)),
    true = os:putenv(binary_to_list(Name), binary_to_list(Value)),
    Previous.

restore_env(Name, false) ->
    true = os:unsetenv(binary_to_list(Name)),
    nil;
restore_env(Name, Previous) ->
    true = os:putenv(binary_to_list(Name), Previous),
    nil.
