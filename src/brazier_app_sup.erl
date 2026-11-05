-module(brazier_app_sup).
%% The root supervisor of a Brazier application (application.start_supervised):
%%
%%   rest_for_one, intensity 2 per 5 s, auto_shutdown never
%%   table owner -> PubSub -> [cluster manager] -> session scope
%%     -> [presence tracker] -> listener
%%
%% Child N (0-based, in start order) has the id N. The children are
%% gleam_otp child specifications (supervision.ChildSpecification), turned
%% into OTP child maps as gleam_otp's static_supervisor turns them: the
%% same restart type, significant flag, child type and shutdown (a worker's
%% shutdown_ms, infinity for a supervisor), and a start function whose
%% actor.Started is reduced to its pid. Strategy, intensity, period and
%% auto_shutdown are the values the root had as a static_supervisor built
%% with supervisor.new(RestForOne) (gleam_otp 1.3's defaults), so restarts
%% behave as they did.
%%
%% WHY THE CHILDREN ARE ADDED AFTER THE START. A supervisor whose init/1
%% lists children fails its start_link when one of them fails to start: it
%% exits with {shutdown, {failed_to_start_child, Id, Reason}}, and that exit
%% reaches the caller through the link. A caller that does not trap exits
%% (an app's main process in brazier.start, with its port taken) was killed
%% before start_link returned, and one that does got gleam_otp's
%% InitFailed("shutdown"), the cause lost. Here init/1 has no children, so
%% the start cannot fail, and start_link/1 then adds the children in order
%% with supervisor:start_child/2, which returns a child's start error to
%% the caller and leaves the supervisor running. On an error the partly
%% started tree is stopped (unlinked first, so its exit reaches nobody) and
%% the child's own start error is returned: a listener that cannot bind
%% reads InitFailed("cannot listen on port N: eaddrinuse (address already
%% in use)").
%%
%% A child added with start_child/2 is a child like one listed in init/1:
%% it is permanent (or what its spec says), restarted in start order under
%% rest_for_one, and stopped in reverse start order. Its start function
%% runs in this supervisor, as it did in init/1, so it links to the
%% supervisor and not to the caller.
%%
%% Reference: ranch:start_listener/5 adds a listener to the running
%% ranch_sup with supervisor:start_child/2, so a listener that cannot bind
%% is an {error, _} return and kills no caller (ranch master, read
%% 2026-11-05); brazier_http_listener_sup does the same for its own three
%% children.
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).
%% The start function of every child spec this module builds.
-export([start_child_callback/1]).

-define(INTENSITY, 2).
-define(PERIOD_S, 5).
%% How long a partly started tree gets to stop before it is killed. The
%% listener is the last child, so a partly started tree has no connections
%% to drain; every child's own shutdown timeout is shorter.
-define(PARTIAL_STOP_TIMEOUT_MS, 15000).

%% Gleam shape: start_link(List(ChildSpecification(Nil))) ->
%%   {ok, Pid} | {error, actor.StartError}.
%% The supervisor is linked to the caller on success; on an error no
%% process of the tree is left and the caller got no exit signal.
start_link(Children) when is_list(Children), Children =/= [] ->
    %% INVARIANT: init/1 returns a fixed child-less spec and no name is
    %% registered, so the start cannot fail; a failure here is a crash.
    {ok, Sup} = supervisor:start_link(?MODULE, []),
    Specs = lists:zipwith(fun child_spec/2,
                          lists:seq(0, length(Children) - 1), Children),
    case start_children(Sup, Specs) of
        ok ->
            brazier_log_ffi:debug(<<"brazier.app_sup">>,
                                  "root supervisor ~p started its ~b children",
                                  [Sup, length(Specs)]),
            {ok, Sup};
        {error, Id, Reason} ->
            brazier_log_ffi:info(<<"brazier.app_sup">>,
                                 "child ~b failed to start (~0p): stopping the partly started tree ~p",
                                 [Id, Reason, Sup]),
            nil = stop_partial(Sup),
            {error, start_error(Reason)}
    end.

init([]) ->
    {ok, {#{strategy => rest_for_one,
            intensity => ?INTENSITY,
            period => ?PERIOD_S,
            auto_shutdown => never}, []}}.

%% A gleam_otp ChildSpecification(start, restart, significant, child_type)
%% as an OTP child map, as gleam_otp's static_supervisor:convert_child/2
%% builds it.
child_spec(Id, {child_specification, Start, Restart, Significant, ChildType})
  when is_function(Start, 0), is_boolean(Significant),
       (Restart =:= permanent orelse Restart =:= transient orelse Restart =:= temporary) ->
    {Type, Shutdown} = case ChildType of
        supervisor -> {supervisor, infinity};
        {worker, Ms} when is_integer(Ms), Ms < 0 -> {worker, infinity};
        {worker, Ms} when is_integer(Ms) -> {worker, Ms}
    end,
    #{id => Id,
      start => {?MODULE, start_child_callback, [Start]},
      restart => Restart,
      significant => Significant,
      type => Type,
      shutdown => Shutdown}.

%% Run a Gleam start function in the supervisor: an actor.Started is the
%% child's pid, an actor.StartError the start's error.
start_child_callback(Start) ->
    case Start() of
        {ok, {started, Pid, _Data}} when is_pid(Pid) -> {ok, Pid};
        {error, StartError} -> {error, StartError}
    end.

start_children(_Sup, []) ->
    ok;
start_children(Sup, [Child = #{id := Id} | Rest]) ->
    %% supervisor:start_child/2 returns a child's start error as
    %% {error, {Reason, ChildRecord}}. start_child_callback/1 never returns
    %% ignore, and the ids are distinct in a fresh supervisor, so any other
    %% return (an {ok, undefined}, already_started, already_present) is a
    %% broken invariant and crashes.
    case supervisor:start_child(Sup, Child) of
        {ok, Pid} when is_pid(Pid) -> start_children(Sup, Rest);
        {error, {Reason, _ChildRecord}} when Reason =/= already_started,
                                             Reason =/= already_present ->
            {error, Id, Reason}
    end.

%% The child's error as a Gleam actor.StartError. A Gleam start function
%% returns one; a start function that raised is caught by the supervisor as
%% {'EXIT', Reason}, an abnormal exit of the start.
start_error(init_timeout) -> init_timeout;
start_error({init_failed, Reason}) when is_binary(Reason) -> {init_failed, Reason};
start_error({init_exited, ExitReason}) -> {init_exited, ExitReason};
start_error(Other) -> {init_exited, {abnormal, Other}}.

%% Stop a partly started tree linked to the caller. The link goes first, so
%% the caller gets no exit signal (or 'EXIT' message when it traps exits);
%% an exit from its parent makes the supervisor stop its children in
%% reverse start order.
stop_partial(Sup) ->
    Ref = erlang:monitor(process, Sup),
    true = unlink(Sup),
    exit(Sup, shutdown),
    receive
        {'DOWN', Ref, process, Sup, _Reason} -> nil
    after ?PARTIAL_STOP_TIMEOUT_MS ->
        brazier_log_ffi:error(<<"brazier.app_sup">>,
                              "the partly started tree ~p ignored shutdown for ~pms, killing it",
                              [Sup, ?PARTIAL_STOP_TIMEOUT_MS]),
        exit(Sup, kill),
        receive
            {'DOWN', Ref, process, Sup, _} -> nil
        end
    end.
