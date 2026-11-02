-module(beacon_connection_tracker_ffi).
%% Connection-slot API used by the transport handler code.
%%
%% Slots are owned by the listener's connection owner (beacon_http_conns),
%% which takes a slot when it starts a handler process and releases it when
%% that process exits for any reason. These functions only operate on the
%% calling handler's own slot:
%%   decrement/0 releases the caller's slot early (idempotent) and returns
%%               the listener's remaining live connection count.
%%   count/0     returns the listener's live connection count.
%% Both crash loudly when called outside a connection handler process.
-export([init/0, decrement/0, count/0]).

%% Kept for API compatibility: there is no global table to create any more.
init() ->
    nil.

decrement() ->
    beacon_http_conns:release_self().

count() ->
    beacon_http_conns:count_self().
