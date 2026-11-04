-module(brazier_effect_ffi).
-export([
    live_timer_count/0,
    register_timer/1,
    log_timer_limit_warning/2,
    unique_integer/0,
    register_key_generation/1,
    cancel_key_generation/1,
    is_current_key_generation/2,
    spawn_owned/1,
    start_interval/3,
    start_after/3,
    take_keyed_process/1,
    track_keyed_process/2,
    stop_process/1
]).

%% Effect process lifecycle.
%%
%% Every framework-spawned effect process (effect.background, effect.after,
%% effect.every) is OWNED by the process that performed the effect — in
%% production that is the runtime actor. Owned processes monitor their owner
%% and die when it dies, for any reason (normal stop, crash, kill), so a
%% runtime can never leave orphaned timers or background workers behind.
%%
%% Reference: Phoenix LiveView ties timers to the LiveView process
%% (Process.send_after to self()); Elixir Task.async links to its caller.
%% We cannot link (a crashing background effect must not crash the runtime,
%% and a normal runtime exit does not propagate through links), so we use
%% monitors instead.

%% Count timers that are still alive, pruning any dead pids from the
%% tracked list. Self-healing: a timer that exited no longer counts
%% against the limit. This runs inside the owner process, so the list
%% lives in that process dictionary.
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

%% Spawn Fun in a new process owned by the caller.
%%
%% The worker runs arbitrary user code, so it cannot itself watch its owner.
%% A small guardian process monitors the owner and links to the worker
%% (trapping exits): when the owner dies the guardian kills the worker; when
%% the worker exits the guardian exits too. Killing the guardian also kills
%% the worker through the link. The guardian pid is recorded in the worker's
%% process dictionary under brazier_effect_guardian for lifecycle tests.
spawn_owned(Fun) ->
    Owner = self(),
    Worker = spawn(fun() ->
        receive
            {brazier_effect_guardian, Guardian} ->
                erlang:put(brazier_effect_guardian, Guardian)
        end,
        Fun()
    end),
    Guardian = spawn(fun() -> guardian(Owner, Worker) end),
    Worker ! {brazier_effect_guardian, Guardian},
    Worker.

guardian(Owner, Worker) ->
    process_flag(trap_exit, true),
    OwnerRef = erlang:monitor(process, Owner),
    %% link/1 to an already-dead worker delivers {'EXIT', Worker, noproc}
    %% because we trap exits, so a fast worker cannot strand the guardian.
    link(Worker),
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

%% Start a one-shot timer owned by the caller: after Delay ms it calls
%% Dispatch(MakeMsg()) once and exits. Stops early if the owner dies.
start_after(Delay, MakeMsg, Dispatch) when is_integer(Delay), Delay >= 0 ->
    Owner = self(),
    spawn(fun() ->
        OwnerRef = erlang:monitor(process, Owner),
        TimerRef = erlang:send_after(Delay, self(), brazier_timer_fire),
        receive
            {'DOWN', OwnerRef, process, Owner, Reason} ->
                _ = erlang:cancel_timer(TimerRef),
                brazier_log_ffi:debug(<<"brazier.effect">>, "Owner ~p exited (~p); cancelling delayed effect ~p",
                                     [Owner, Reason, self()]),
                ok;
            brazier_timer_fire ->
                erlang:demonitor(OwnerRef, [flush]),
                Dispatch(MakeMsg())
        end
    end).

%% Remove and return the process tracked for Key, if any.
take_keyed_process(Key) ->
    Keyed = keyed_pids(),
    case maps:take(Key, Keyed) of
        {Pid, Rest} ->
            erlang:put(brazier_keyed_pids, Rest),
            {some, Pid};
        error ->
            none
    end.

%% Track Pid as the live process for Key.
track_keyed_process(Key, Pid) ->
    erlang:put(brazier_keyed_pids, maps:put(Key, Pid, keyed_pids())),
    nil.

keyed_pids() ->
    case erlang:get(brazier_keyed_pids) of
        undefined -> #{};
        Map when is_map(Map) -> Map
    end.

%% Kill Pid and drop it from the timer registry. Returns true if the process
%% was alive. is_process_alive/1 after exit/2 from the same process is
%% guaranteed to observe the exit signal (signal ordering between a pair of
%% processes), so the freed timer slot is visible immediately.
stop_process(Pid) ->
    WasAlive = is_process_alive(Pid),
    exit(Pid, kill),
    erlang:put(brazier_timer_pids, [P || P <- timer_pids(), P =/= Pid]),
    WasAlive.
