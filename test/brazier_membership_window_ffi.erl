-module(brazier_membership_window_ffi).

%% Helpers for test/brazier/cluster/membership_window_test.gleam: the
%% windows in which the membership could disagree with the connection it
%% is about (a row outliving its connection, a manager restart with
%% waiters in flight, a check that only one side has passed).

-export([member_row/1, verified/1, disconnect/1, connect/1]).

-define(MEMBERS, brazier_cluster_members).

%% Whether the manager's member table holds a row for Node, whatever its
%% connection.
member_row(Node) ->
    ets:member(?MEMBERS, Node).

verified(Node) ->
    brazier_cluster_ffi:verified(Node).

%% Drop the connection to Node; returns once this node no longer lists it.
disconnect(Node) ->
    true = erlang:disconnect_node(Node),
    false = lists:member(Node, nodes()),
    nil.

%% Connect to Node; returns once the connection is up.
connect(Node) ->
    true = net_kernel:connect_node(Node),
    true = lists:member(Node, nodes()),
    nil.
