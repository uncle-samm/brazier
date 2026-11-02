-module(beacon_application_ffi).
-export([trap_exit/0, receive_shutdown_signal/1, get_env_int/1, generate_strong_secret/0,
         fail_loudly/1]).

%% Enable trapping of exit signals (SIGTERM etc.)
trap_exit() ->
    process_flag(trap_exit, true),
    nil.

%% Wait for an exit signal from a linked process.
%% Returns no_signal on timeout, shutdown_requested for a shutdown/normal
%% exit, and {linked_process_exited, ReasonBin} for any other exit: because
%% the caller traps exits, swallowing those would leave the application
%% running with a dead child (for example the HTTP listener).
receive_shutdown_signal(Timeout) ->
    receive
        {'EXIT', _From, shutdown} -> shutdown_requested;
        {'EXIT', _From, {shutdown, _}} -> shutdown_requested;
        {'EXIT', _From, normal} -> shutdown_requested;
        {'EXIT', From, Reason} ->
            {linked_process_exited,
             iolist_to_binary(io_lib:format("~p exited with ~p", [From, Reason]))}
    after Timeout ->
        no_signal
    end.

%% Generate a cryptographically secure secret key using crypto:strong_rand_bytes/1.
%% Returns a URL-safe base64-encoded string prefixed with "beacon_".
generate_strong_secret() ->
    Bytes = crypto:strong_rand_bytes(32),
    Base = base64:encode(Bytes, #{mode => urlsafe, padding => false}),
    <<"beacon_", Base/binary>>.

%% Get an integer environment variable.
%% {ok, N} | {error, env_not_set} | {error, {env_not_integer, ValueBin}}.
get_env_int(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, env_not_set};
        Value ->
            try list_to_integer(string:trim(Value)) of
                N -> {ok, N}
            catch
                error:badarg ->
                    {error, {env_not_integer, unicode:characters_to_binary(Value)}}
            end
    end.

%% Stop the calling process with an error. Used where continuing would
%% hide a configuration or supervision failure.
fail_loudly(Reason) when is_binary(Reason) ->
    erlang:error({beacon_application, Reason}).
