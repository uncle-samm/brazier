-module(beacon_await_ffi).
-export([barrier/2]).

%% A mailbox barrier on an OTP process (a gleam_otp actor, gen_server or any
%% sys-compliant process). sys:get_state/2 is answered in mailbox order, so
%% when it returns the process has handled every message sent to it before
%% the call. Anything it sent the caller while handling them is already in
%% the caller's mailbox: messages between one pair of processes keep their
%% order.
%%
%% Returns {error, Reason} instead of raising so the Gleam side can name the
%% process in its failure.
barrier(Pid, TimeoutMs) ->
    try sys:get_state(Pid, TimeoutMs) of
        _State -> {ok, nil}
    catch
        exit:{Reason, {sys, get_state, _}} -> {error, iolist_to_binary(io_lib:format("~0p", [Reason]))}
    end.
