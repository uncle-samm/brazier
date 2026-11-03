-module(beacon_presence_watch_ffi).
-export([receive_event/4, exit/1, trap_exits/0, set_label/1]).

%% FFI of beacon/internal/presence_watch: the receive loop of a session's
%% presence watcher.

-define(MAX_BATCH, 100).

%% Wait for the next event of a watcher. The results match the Gleam type
%% presence_watch.Event:
%%   {command_received, Msg}           a command sent on Subject
%%   {diffs, DiffTopic, [Msg]}         a diff delivery followed by up to 99
%%                                     more already queued for DiffTopic
%%   {owner_down, ReasonBin}           the runtime exited (DOWN or EXIT)
%%   {partition_down, ReasonBin}       the PubSub partition exited
%%   {monitor_down, Pid, ReasonBin}    another monitored process (a shard)
%%   {linked_exit, Pid, ReasonBin}     a linked process other than the
%%                                     runtime exited (a PubSub partition)
%% Anything else is logged and skipped.
receive_event({subject, _Pid, Tag} = Subject, {OwnerMonitor, Owner}, PartitionMonitor, Name) ->
    receive
        {Tag, Msg} ->
            {command_received, Msg};
        {beacon_pubsub, DiffTopic, Msg} when is_binary(DiffTopic) ->
            {diffs, DiffTopic, [Msg | drain(DiffTopic, ?MAX_BATCH - 1)]};
        {'DOWN', OwnerMonitor, process, _, Reason} ->
            {owner_down, format(Reason)};
        {'EXIT', Owner, Reason} ->
            {owner_down, format(Reason)};
        {'DOWN', PartitionMonitor, process, _, Reason} ->
            {partition_down, format(Reason)};
        {'DOWN', _Ref, process, Pid, Reason} ->
            {monitor_down, Pid, format(Reason)};
        {'EXIT', Pid, Reason} ->
            {linked_exit, Pid, format(Reason)};
        Other ->
            beacon_log_ffi:warning(<<"beacon.presence">>, "Watcher ~p of tracker ~ts skipping an "
                                   "unexpected message: ~p", [self(), Name, Other]),
            receive_event(Subject, {OwnerMonitor, Owner}, PartitionMonitor, Name)
    end.

%% Up to Count deliveries for DiffTopic that are already queued, oldest
%% first. Deliveries for other topics keep their places.
drain(_DiffTopic, 0) ->
    [];
drain(DiffTopic, Count) ->
    receive
        {beacon_pubsub, DiffTopic, Msg} -> [Msg | drain(DiffTopic, Count - 1)]
    after 0 ->
        []
    end.

%% Exit the calling process with Reason.
exit(Reason) ->
    erlang:exit(Reason).

trap_exits() ->
    process_flag(trap_exit, true),
    nil.

%% Label the process for observer and tests (proc_lib:get_label/1).
set_label(Name) ->
    ok = proc_lib:set_label({beacon_presence_watch, Name}),
    nil.

format(Term) ->
    unicode:characters_to_binary(io_lib:format("~p", [Term])).
