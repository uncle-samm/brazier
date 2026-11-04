-module(brazier_effect_ffi).
-export([
    live_timer_count/0,
    register_timer/1,
    log_timer_limit_warning/2,
    live_background_count/1,
    register_background/1,
    unique_integer/0,
    register_key_generation/1,
    cancel_key_generation/1,
    is_current_key_generation/2,
    spawn_owned/1,
    start_interval/3,
    start_after_timer/2,
    pending_after_count/0,
    take_after_timer/1,
    cancel_after_timer/1,
    after_timer_of_message/1,
    take_keyed/1,
    track_keyed/2,
    stop_process/1,
    stop_all_owned/0
]).

%% Effect process lifecycle.
%%
%% Every framework-spawned effect process (effect.background, effect.every)
%% is OWNED by the process that performed the effect — in production that is
%% the runtime actor. Owned processes monitor their owner and die when it
%% dies, for any reason (normal stop, crash, kill), so a runtime can never
%% leave orphaned timers or background workers behind.
%%
%% effect.after spawns nothing: it is an erlang:send_after into the owner's
%% own mailbox (LiveView's Process.send_after(self(), ...)). The VM cancels
%% a timer whose destination process has exited, so it cannot outlive the
%% owner either.
%%
%% Reference: Phoenix LiveView ties timers to the LiveView process
%% (Process.send_after to self()); Elixir Task.async links to its caller.
%% A background worker is not linked to its owner (a crashing background
%% effect must not crash the runtime, and a normal runtime exit does not
%% propagate through links), so a guardian watches the owner instead.
%%
%% All registries below live in the owner's process dictionary, so every
%% count and limit is per runtime.

%% Count timers that are still alive, pruning any dead pids from the
%% tracked list. Self-healing: a timer that exited no longer counts
%% against the limit. The list is at most the timer limit long.
live_timer_count() ->
    Alive = [P || P <- timer_pids(), is_process_alive(P)],
    erlang:put(brazier_timer_pids, Alive),
    length(Alive).

%% Track a newly spawned timer pid so it counts toward the live limit.
register_timer(Pid) ->
    erlang:put(brazier_timer_pids, [Pid | timer_pids()]),
    nil.

timer_pids() ->
    case erlang:get(brazier_timer_pids) of
        undefined -> [];
        L when is_list(L) -> L
    end.

log_timer_limit_warning(Current, Max) ->
    brazier_log_ffi:warning(<<"brazier.effect">>, "Timer limit reached (~p/~p) - new timer rejected", [Current, Max]),
    nil.

%% Count live background workers. The tracked list is pruned of dead pids
%% only once it has reached Max entries, so the common case is length/1 of
%% a list never longer than Max: the cost per background effect is bounded
%% by the limit, not by how many workers ever ran.
live_background_count(Max) when is_integer(Max), Max > 0 ->
    Tracked = background_pids(),
    case length(Tracked) >= Max of
        false ->
            length(Tracked);
        true ->
            Alive = [P || P <- Tracked, is_process_alive(P)],
            erlang:put(brazier_background_pids, Alive),
            length(Alive)
    end.

register_background(Pid) ->
    erlang:put(brazier_background_pids, [Pid | background_pids()]),
    nil.

background_pids() ->
    case erlang:get(brazier_background_pids) of
        undefined -> [];
        L when is_list(L) -> L
    end.

unique_integer() ->
    erlang:unique_integer([monotonic, positive]).

register_key_generation(Key) ->
    Generations = generations(),
    Generation = maps:get(Key, Generations, 0) + 1,
    erlang:put(brazier_effect_generations, maps:put(Key, Generation, Generations)),
    Generation.

cancel_key_generation(Key) ->
    _ = register_key_generation(Key),
    nil.

is_current_key_generation(Key, Generation) ->
    maps:get(Key, generations(), 0) =:= Generation.

generations() ->
    case erlang:get(brazier_effect_generations) of
        undefined -> #{};
        Map when is_map(Map) -> Map
    end.

%% Spawn Fun in a new process owned by the caller and return its pid.
%%
%% The worker runs arbitrary user code, so it cannot itself watch its owner.
%% A small guardian process does: it is spawned FIRST, traps exits, monitors
%% the owner and only then starts the worker with spawn_link. There is no
%% moment at which the worker exists without a guardian watching the owner,
%% so a worker can never be orphaned: if the owner dies at any point after
%% the guardian's monitor is set, the monitor fires and the guardian kills
%% the worker (a monitor of an already-dead owner fires at once with
%% noproc). When the worker exits the guardian exits too; killing the
%% guardian kills the worker through the link.
%%
%% The caller learns the worker pid through a monitored request/reply (the
%% gen:call pattern): if the guardian dies before replying, the caller
%% crashes with the guardian's reason instead of waiting forever. The
%% guardian pid is recorded in the worker's process dictionary under
%% brazier_effect_guardian for lifecycle tests.
spawn_owned(Fun) ->
    Owner = self(),
    Reply = make_ref(),
    {Guardian, GuardianRef} =
        spawn_monitor(fun() -> guardian_start(Owner, Reply, Fun) end),
    receive
        {Reply, Worker} ->
            erlang:demonitor(GuardianRef, [flush]),
            Worker;
        {'DOWN', GuardianRef, process, Guardian, Reason} ->
            brazier_log_ffi:error(<<"brazier.effect">>,
                                  "Effect guardian ~p exited before starting its worker: ~0p",
                                  [Guardian, Reason]),
            erlang:error({brazier_effect_guardian_failed, Reason})
    end.

guardian_start(Owner, Reply, Fun) ->
    process_flag(trap_exit, true),
    OwnerRef = erlang:monitor(process, Owner),
    Guardian = self(),
    Worker = spawn_link(fun() ->
        erlang:put(brazier_effect_guardian, Guardian),
        Fun()
    end),
    Owner ! {Reply, Worker},
    guardian(Owner, OwnerRef, Worker).

guardian(Owner, OwnerRef, Worker) ->
    receive
        {'DOWN', OwnerRef, process, Owner, Reason} ->
            brazier_log_ffi:debug(<<"brazier.effect">>, "Owner ~p exited (~p); killing effect process ~p",
                                 [Owner, Reason, Worker]),
            exit(Worker, kill);
        {'EXIT', Worker, _WorkerReason} ->
            erlang:demonitor(OwnerRef, [flush]),
            ok
    end.

%% Start a periodic timer owned by the caller. Every Interval ms it calls
%% Dispatch(MakeMsg()). Implemented as erlang:send_after re-armed each tick
%% (the LiveView Process.send_after pattern) inside a receive that also
%% watches the owner, so the timer stops the moment its owner dies.
start_interval(Interval, MakeMsg, Dispatch) when is_integer(Interval), Interval > 0 ->
    Owner = self(),
    spawn(fun() ->
        OwnerRef = erlang:monitor(process, Owner),
        interval_loop(Owner, OwnerRef, Interval, MakeMsg, Dispatch)
    end).

interval_loop(Owner, OwnerRef, Interval, MakeMsg, Dispatch) ->
    TimerRef = erlang:send_after(Interval, self(), brazier_timer_tick),
    receive
        {'DOWN', OwnerRef, process, Owner, Reason} ->
            _ = erlang:cancel_timer(TimerRef),
            brazier_log_ffi:debug(<<"brazier.effect">>, "Owner ~p exited (~p); stopping interval timer ~p",
                                 [Owner, Reason, self()]),
            ok;
        brazier_timer_tick ->
            Dispatch(MakeMsg()),
            interval_loop(Owner, OwnerRef, Interval, MakeMsg, Dispatch)
    end.

%% effect.after: arm a one-shot erlang:send_after into the caller's own
%% mailbox (LiveView: Process.send_after(self(), msg, ms)) and remember
%% Fire under a fresh id. The owner hands the {brazier_effect_after, Id}
%% message to take_after_timer/1 when it arrives. Returns the id.
start_after_timer(Delay, Fire) when is_integer(Delay), Delay >= 0 ->
    Id = make_ref(),
    TimerRef = erlang:send_after(Delay, self(), {brazier_effect_after, Id}),
    erlang:put(brazier_after_timers, maps:put(Id, {TimerRef, Fire}, after_timers())),
    Id.

%% Timers armed and neither fired nor cancelled.
pending_after_count() ->
    map_size(after_timers()).

%% The fire function of a timer whose message arrived, removed from the
%% registry. none when the timer was cancelled after its message had been
%% sent (erlang:cancel_timer cannot recall a message already in flight).
take_after_timer(Id) ->
    Timers = after_timers(),
    case maps:take(Id, Timers) of
        {{_TimerRef, Fire}, Rest} ->
            erlang:put(brazier_after_timers, Rest),
            {some, Fire};
        error ->
            none
    end.

%% Cancel a pending timer and drop it from the registry. Returns true when
%% the timer was still registered (its fire function will never run).
cancel_after_timer(Id) ->
    Timers = after_timers(),
    case maps:take(Id, Timers) of
        {{TimerRef, _Fire}, Rest} ->
            erlang:put(brazier_after_timers, Rest),
            _ = erlang:cancel_timer(TimerRef),
            true;
        error ->
            false
    end.

%% The timer id in a {brazier_effect_after, Id} message (the selector hands
%% over the whole record). Any other shape is a broken invariant and
%% crashes with function_clause.
after_timer_of_message({brazier_effect_after, Id}) when is_reference(Id) ->
    Id.

after_timers() ->
    case erlang:get(brazier_after_timers) of
        undefined -> #{};
        Map when is_map(Map) -> Map
    end.

%% Remove and return what is tracked for Key (a process or a timer), if any.
take_keyed(Key) ->
    Keyed = keyed_owned(),
    case maps:take(Key, Keyed) of
        {Owned, Rest} ->
            erlang:put(brazier_keyed_pids, Rest),
            {some, Owned};
        error ->
            none
    end.

%% Track Owned (a process or a timer) as the live effect for Key.
track_keyed(Key, Owned) ->
    erlang:put(brazier_keyed_pids, maps:put(Key, Owned, keyed_owned())),
    nil.

keyed_owned() ->
    case erlang:get(brazier_keyed_pids) of
        undefined -> #{};
        Map when is_map(Map) -> Map
    end.

%% Kill Pid and drop it from the registries. Returns true if the process
%% was alive. is_process_alive/1 after exit/2 from the same process is
%% guaranteed to observe the exit signal (signal ordering between a pair of
%% processes), so the freed slot is visible immediately.
stop_process(Pid) ->
    WasAlive = is_process_alive(Pid),
    exit(Pid, kill),
    erlang:put(brazier_timer_pids, [P || P <- timer_pids(), P =/= Pid]),
    erlang:put(brazier_background_pids, [P || P <- background_pids(), P =/= Pid]),
    WasAlive.

%% Stop everything the caller owns: kill every live timer and background
%% worker and cancel every pending after timer. Returns
%% {ProcessesStopped, TimersCancelled}. Every registry is bounded by its
%% limit, so this is too.
stop_all_owned() ->
    Live = [P || P <- timer_pids() ++ background_pids(), is_process_alive(P)],
    lists:foreach(fun(P) -> exit(P, kill) end, Live),
    Timers = after_timers(),
    maps:foreach(fun(_Id, {TimerRef, _Fire}) -> _ = erlang:cancel_timer(TimerRef) end, Timers),
    erlang:put(brazier_timer_pids, []),
    erlang:put(brazier_background_pids, []),
    erlang:put(brazier_after_timers, #{}),
    erlang:put(brazier_keyed_pids, #{}),
    {length(Live), map_size(Timers)}.
