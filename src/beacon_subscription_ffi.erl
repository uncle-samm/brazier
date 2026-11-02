-module(beacon_subscription_ffi).
-export([receive_with_commands/3]).

%% Receive a command from a Gleam Subject, a tagged PubSub notification, or
%% the DOWN message of the owning runtime's monitor.
%%
%% Subject is a Gleam record: {subject, Pid, Tag}
%% Messages sent via process.send(subject, msg) arrive as {Tag, Msg}.
%% PubSub broadcasts arrive as {beacon_pubsub, Topic, Message}.
%% OwnerMonitor is the reference returned by erlang:monitor(process, Runtime).
%%
%% Returns Gleam-compatible tuples matching ListenerReceiveResult variants:
%%   {command_received, Msg}                 — CommandReceived
%%   {notification_received, Topic, Message} — NotificationReceived
%%   {owner_exited, ReasonBinary}            — OwnerExited
%%   receive_timeout                         — ReceiveTimeout
receive_with_commands(Subject, OwnerMonitor, Timeout) ->
    {subject, _Pid, Tag} = Subject,
    receive
        {Tag, Msg} ->
            {command_received, Msg};
        {beacon_pubsub, Topic, Msg} ->
            {notification_received, Topic, Msg};
        {'DOWN', OwnerMonitor, process, _OwnerPid, Reason} ->
            {owner_exited, unicode:characters_to_binary(io_lib:format("~p", [Reason]))};
        Other ->
            logger:warning("[beacon.subscription] Discarding unexpected listener message: ~p", [Other]),
            receive_with_commands(Subject, OwnerMonitor, Timeout)
    after
        Timeout ->
            receive_timeout
    end.
