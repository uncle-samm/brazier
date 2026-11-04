-module(brazier_presence_watch_test_ffi).

%% Helpers for the session presence tests: find a runtime's presence
%% watcher and hold its mailbox still.

-export([watcher_of/1, suspend/1, resume/1]).

%% The presence watcher linked to Runtime (labelled by the watcher with
%% {brazier_presence_watch, TrackerName}). Must run on Runtime's node.
watcher_of(Runtime) ->
    {links, Links} = erlang:process_info(Runtime, links),
    Watchers = [Pid || Pid <- Links, is_pid(Pid), is_watcher(Pid)],
    case Watchers of
        [Watcher] -> {ok, Watcher};
        _ -> {error, nil}
    end.

is_watcher(Pid) ->
    case proc_lib:get_label(Pid) of
        {brazier_presence_watch, _} -> true;
        _ -> false
    end.

%% Suspend Pid. The suspension ends when the calling process exits, so
%% suspend, act and resume from one process.
suspend(Pid) ->
    true = erlang:suspend_process(Pid),
    nil.

resume(Pid) ->
    true = erlang:resume_process(Pid),
    nil.
