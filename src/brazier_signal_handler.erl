%% SIGTERM for `application.wait_forever`.
%%
%% The VM delivers OS signals as events to the `erl_signal_server` event
%% manager. OTP's own handler there, `erl_signal_handler`, answers SIGTERM
%% with `init:stop()`, which stops the node without draining Brazier's
%% connections. While at least one process waits in `wait_forever`, this
%% handler replaces it: SIGTERM is forwarded to every waiter as
%% `{brazier_signal, sigterm}`, and the waiter stops its applications (each
%% drains its connections) before it returns. SIGUSR1 and SIGQUIT keep OTP's
%% behaviour (halt).
%%
%% The waiters stay joined while they drain, so this handler still answers
%% a SIGTERM that arrives during the drain: it is logged and ignored, as
%% OTP's init:stop() ignores a second call while the node is stopping. Only
%% the first SIGTERM is forwarded, and a process that starts waiting after
%% it is told at once. (A waiter that left before draining let a second
%% SIGTERM reach init:stop() and cut the drain short.)
%%
%% Every change of handler happens inside the event manager process, so
%% concurrent waiters never race: the first waiter swaps OTP's handler for
%% this one, later waiters join it, and the handler swaps OTP's back in
%% itself when its last waiter leaves or dies (it monitors them).
%%
%% Reference (read on disk): OTP kernel `erl_signal_handler.erl`, the
%% default handler this one replaces and restores.
-module(brazier_signal_handler).
-behaviour(gen_event).

-export([install/1, uninstall/1]).
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2,
         code_change/3]).

-define(MANAGER, erl_signal_server).
-define(OTP_HANDLER, erl_signal_handler).

%% --- API (called by the waiting process) ---

%% Forward SIGTERM to Waiter until uninstall/1 or Waiter exits.
install(Waiter) when is_pid(Waiter) ->
    case join(Waiter) of
        ok -> {ok, nil};
        not_installed ->
            case gen_event:swap_handler(?MANAGER, {?OTP_HANDLER, []},
                                        {?MODULE, Waiter}) of
                ok ->
                    brazier_log_ffi:info(<<"brazier.application">>,
                                        "SIGTERM now stops the application gracefully (~p)",
                                        [Waiter]),
                    {ok, nil};
                {error, {error, otp_handler_not_installed}} ->
                    %% Another waiter swapped first, or OTP's handler was
                    %% removed by someone else: only joining can tell.
                    case join(Waiter) of
                        ok -> {ok, nil};
                        not_installed ->
                            refuse(<<"the OTP signal handler erl_signal_handler is not "
                                     "installed on erl_signal_server, so SIGTERM cannot be "
                                     "taken over">>)
                    end;
                Other ->
                    refuse(iolist_to_binary(
                             io_lib:format("installing the SIGTERM handler failed: ~p",
                                           [Other])))
            end
    end.

%% Stop forwarding SIGTERM to Waiter. The last waiter to leave restores
%% OTP's handler.
uninstall(Waiter) when is_pid(Waiter) ->
    case gen_event:call(?MANAGER, ?MODULE, {leave, Waiter}) of
        ok -> {ok, nil};
        {error, not_a_waiter} ->
            refuse(iolist_to_binary(
                     io_lib:format("~p is not waiting for SIGTERM", [Waiter])));
        {error, bad_module} ->
            refuse(<<"the Brazier SIGTERM handler is not installed">>);
        Other ->
            refuse(iolist_to_binary(
                     io_lib:format("removing the SIGTERM handler failed: ~p", [Other])))
    end.

join(Waiter) ->
    case gen_event:call(?MANAGER, ?MODULE, {join, Waiter}) of
        ok -> ok;
        {error, bad_module} -> not_installed
    end.

refuse(Reason) ->
    brazier_log_ffi:error(<<"brazier.application">>, "~ts", [Reason]),
    {error, Reason}.

%% --- gen_event callbacks (run in the event manager process) ---

%% Swapped in for OTP's handler: its terminate/2 returned `ok`. When it was
%% not installed, swap_handler passes `error` and this handler is not added.
%% The state is {Waiters, Signalled}: Waiters maps each waiter to its
%% monitor, and Signalled is true once SIGTERM was forwarded.
init({Waiter, ok}) ->
    {ok, {#{Waiter => erlang:monitor(process, Waiter)}, false}};
init({_Waiter, error}) ->
    {error, otp_handler_not_installed}.

handle_event(sigterm, {Waiters, false}) ->
    brazier_log_ffi:info(<<"brazier.application">>,
                        "SIGTERM received, telling ~b waiting process(es) to stop",
                        [map_size(Waiters)]),
    maps:foreach(fun(Waiter, _Monitor) -> tell(Waiter) end, Waiters),
    {ok, {Waiters, true}};
handle_event(sigterm, {Waiters, true}) ->
    brazier_log_ffi:warning(<<"brazier.application">>,
                           "SIGTERM received again while ~b process(es) drain: ignored, "
                           "the drain goes on (SIGQUIT or SIGKILL stops the node now)",
                           [map_size(Waiters)]),
    {ok, {Waiters, true}};
handle_event(sigusr1, State) ->
    erlang:halt("Received SIGUSR1"),
    {ok, State};
handle_event(sigquit, State) ->
    erlang:halt(),
    {ok, State};
handle_event(_Signal, State) ->
    %% OTP's handler ignores every other signal too.
    {ok, State}.

handle_call({join, Waiter}, {Waiters, Signalled} = State) ->
    case maps:is_key(Waiter, Waiters) of
        true -> {ok, ok, State};
        false ->
            case Signalled of
                true ->
                    brazier_log_ffi:info(<<"brazier.application">>,
                                        "~p started waiting after SIGTERM, telling it to stop",
                                        [Waiter]),
                    tell(Waiter);
                false -> ok
            end,
            {ok, ok, {Waiters#{Waiter => erlang:monitor(process, Waiter)}, Signalled}}
    end;
handle_call({leave, Waiter}, {Waiters, Signalled} = State) ->
    case maps:take(Waiter, Waiters) of
        {Monitor, Rest} ->
            erlang:demonitor(Monitor, [flush]),
            leave(ok, {Rest, Signalled});
        error ->
            {ok, {error, not_a_waiter}, State}
    end.

handle_info({'DOWN', Monitor, process, Waiter, Reason}, {Waiters, Signalled} = State) ->
    case Waiters of
        #{Waiter := Monitor} ->
            brazier_log_ffi:info(<<"brazier.application">>,
                                "~p stopped waiting for SIGTERM: it exited with ~p",
                                [Waiter, Reason]),
            leave(no_reply, {maps:remove(Waiter, Waiters), Signalled});
        _ ->
            %% Another handler's monitor: every handler sees every message.
            {ok, State}
    end;
handle_info(_Info, State) ->
    {ok, State}.

tell(Waiter) ->
    Waiter ! {brazier_signal, sigterm}.

%% The last waiter gone: OTP's handler answers SIGTERM again.
leave(Reply, {Waiters, _Signalled} = State) when map_size(Waiters) =:= 0 ->
    brazier_log_ffi:info(<<"brazier.application">>,
                        "No process waits for SIGTERM any more, restoring OTP's handler", []),
    case Reply of
        no_reply -> {swap_handler, restore, State, ?OTP_HANDLER, []};
        _ -> {swap_handler, Reply, restore, State, ?OTP_HANDLER, []}
    end;
leave(no_reply, State) ->
    {ok, State};
leave(Reply, State) ->
    {ok, Reply, State}.

terminate(_Arg, {Waiters, _Signalled}) when is_map(Waiters) ->
    maps:foreach(fun(_Waiter, Monitor) -> erlang:demonitor(Monitor, [flush]) end, Waiters),
    ok;
terminate(_Arg, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
