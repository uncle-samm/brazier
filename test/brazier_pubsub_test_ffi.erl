-module(brazier_pubsub_test_ffi).
-export([receive_pubsub/1, node_named/1, linked/2, rescue/1, pause/1]).

%% Wait Ms milliseconds between polls of a condition with a deadline.
pause(Ms) ->
    receive after Ms -> nil end.

%% Receive one PubSub delivery: {ok, {Topic, Message}}, or {error, nil}
%% after TimeoutMs.
receive_pubsub(TimeoutMs) ->
    receive
        {brazier_pubsub, Topic, Message} -> {ok, {Topic, Message}}
    after TimeoutMs ->
        {error, nil}
    end.

%% A node value for a name; the node does not have to exist.
node_named(Name) ->
    binary_to_atom(Name, utf8).

%% Whether Pid is linked to Other.
linked(Pid, Other) ->
    case erlang:process_info(Pid, links) of
        {links, Links} -> lists:member(Other, Links);
        undefined -> false
    end.

%% Run Fun: {ok, Result}, or {error, ClassBinary} if it raised.
rescue(Fun) ->
    try
        {ok, Fun()}
    catch
        Class:_Reason -> {error, atom_to_binary(Class, utf8)}
    end.
