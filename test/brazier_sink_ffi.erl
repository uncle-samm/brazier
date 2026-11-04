-module(brazier_sink_ffi).
-behaviour(gen_server).

%% A gen_server that accepts any message and does nothing with it, for
%% tests of the sys debug hooks in brazier_await_ffi. A gleam_otp actor
%% cannot stand in for it: gleam_otp 1.3 answers only the get_state,
%% get_status, suspend and resume system messages and discards the rest,
%% so sys:install/2 on an actor times out.

-export([start/0, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Unlinked: the test stops it explicitly.
start() ->
    {ok, Pid} = gen_server:start(?MODULE, nil, []),
    Pid.

stop(Pid) ->
    ok = gen_server:stop(Pid),
    nil.

init(nil) -> {ok, nil}.

handle_call(_Request, _From, State) -> {reply, nil, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info(_Message, State) -> {noreply, State}.
