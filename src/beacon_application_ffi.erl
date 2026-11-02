-module(beacon_application_ffi).
-export([trap_exit/0, receive_shutdown_signal/1, get_env_int/1, generate_strong_secret/0]).

%% Enable trapping of exit signals (SIGTERM etc.)
trap_exit() ->
    process_flag(trap_exit, true),
    nil.

%% Wait for a shutdown signal (EXIT message from supervisor/system).
%% Returns true if shutdown received, false on timeout.
receive_shutdown_signal(Timeout) ->
    receive
        {'EXIT', _From, shutdown} -> true;
        {'EXIT', _From, {shutdown, _}} -> true;
        {'EXIT', _From, normal} -> true
    after Timeout ->
        false
    end.

%% Generate a cryptographically secure secret key using crypto:strong_rand_bytes/1.
%% Returns a URL-safe base64-encoded string prefixed with "beacon_".
generate_strong_secret() ->
    Bytes = crypto:strong_rand_bytes(32),
    Base = base64:encode(Bytes, #{mode => urlsafe, padding => false}),
    <<"beacon_", Base/binary>>.

%% Get an integer environment variable.
get_env_int(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, <<"env_var_not_set">>};
        Value ->
            try list_to_integer(Value) of
                N -> {ok, N}
            catch
                error:badarg -> {error, <<"not_an_integer">>}
            end
    end.
