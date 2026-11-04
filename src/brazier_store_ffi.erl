-module(brazier_store_ffi).
-export([append/3, get_all/2, delete_key/2]).

%% List stores are `duplicate_bag` ETS tables created (idempotently, under a
%% long-lived owner) by brazier_ets_ffi:ensure_table/2. A duplicate_bag keeps
%% every inserted {Key, Value} -- two identical chat messages are two
%% messages. (A plain `bag` would silently drop the second one.) Values for a
%% key are returned in insertion order.

append(Store, Key, Value) ->
    ets:insert(Store, {Key, Value}),
    nil.

get_all(Store, Key) ->
    [V || {_, V} <- ets:lookup(Store, Key)].

delete_key(Store, Key) ->
    ets:delete(Store, Key),
    nil.
