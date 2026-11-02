-module(beacon_telemetry_test_ffi).
-export([rescue/1, handler_ids/1, bench_no_handler_emit/1, print_to_user/1,
         exit_abnormally/1]).

%% Exit Pid with an abnormal reason (not normal, shutdown or kill), as an
%% unexpected crash of a connection process would.
exit_abnormally(Pid) ->
    true = exit(Pid, {beacon_test, abnormal_exit}),
    nil.

%% eunit captures a test's standard output; the user process is the
%% terminal, so benchmark results appear in the test run's output.
print_to_user(Line) ->
    io:format(user, "~ts~n", [Line]),
    nil.

%% Run Fun and return {ok, Result} or {error, {Class, Reason}} if it raised.
rescue(Fun) ->
    try
        {ok, Fun()}
    catch
        Class:Reason -> {error, {atom_to_binary(Class, utf8), Reason}}
    end.

%% Ids of the handlers attached to exactly EventName (a list of binaries).
handler_ids(EventName) ->
    Atoms = [binary_to_atom(S, utf8) || S <- EventName],
    [Id || #{id := Id, event_name := Name} <- telemetry:list_handlers(Atoms), Name =:= Atoms].

%% Average cost in nanoseconds of one no-handler emit of
%% [beacon, store, write], and of one iteration of an empty loop, over N
%% iterations. Returns {EmitNs, LoopNs} as floats.
bench_no_handler_emit(N) ->
    [] = telemetry:list_handlers([beacon, store, write]),
    LoopNs = time_loop(N, fun() -> ok end),
    EmitNs = time_loop(N, fun() ->
        beacon_telemetry_ffi:store_write(1, <<"bench">>, <<"put">>, <<"local">>)
    end),
    {EmitNs, LoopNs}.

time_loop(N, Fun) ->
    Start = erlang:monotonic_time(nanosecond),
    loop(N, Fun),
    (erlang:monotonic_time(nanosecond) - Start) / N.

loop(0, _Fun) -> ok;
loop(N, Fun) -> Fun(), loop(N - 1, Fun).
