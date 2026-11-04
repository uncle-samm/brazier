%% Test helpers for sigterm_test.
-module(brazier_sigterm_test_ffi).
-export([sigterm_and_wait/0]).

%% Deliver SIGTERM to the signal server as the VM does (an event on
%% erl_signal_server), and return once every handler has run it, so the
%% test needs no wait for the signal to arrive.
sigterm_and_wait() ->
    ok = gen_event:sync_notify(erl_signal_server, sigterm),
    nil.
