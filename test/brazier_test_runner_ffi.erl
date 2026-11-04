-module(brazier_test_runner_ffi).

%% The test suite's runner: gleeunit's discovery and options, with one more
%% test per module that fails when the module's tests left a telemetry
%% handler attached.
%%
%% Telemetry handlers are node-wide. One left attached by a test keeps
%% sending events to eunit's shared test process (eunit runs every module's
%% tests in one process), where a later module's test receives them: the
%% wave 4 failure in presence/scoped_cleanup_test was an event of that kind.
%% The check runs inside eunit, as a fixture of the module's group
%% (eunit's {setup, local, Setup, Instantiator}), so its failure is
%% reported against the module that leaked, as ExUnit reports an on_exit
%% failure against its test.

-export([run/0, handler_snapshot/0, handler_check/2]).

run() ->
    %% The production handler-failure logger is attached by the first
    %% telemetry start and stays for the node's life; start it here so that
    %% the first module to start telemetry is not reported for it.
    {ok, nil} = brazier_telemetry_ffi:start(),
    Files = gleeunit_ffi:find_files(<<"**/*.{erl,gleam}">>, <<"test">>),
    Tests = [module_tests(module_name(File)) || File <- Files],
    %% gleeunit.main's options, unchanged.
    Options = [verbose, no_tty, {report, {gleeunit_progress, [{colored, true}]}},
               {scale_timeouts, 10}],
    Code = case gleeunit_ffi:run_eunit(Tests, Options) of
        {ok, nil} -> 0;
        {error, _} -> 1
    end,
    erlang:halt(Code).

%% gleeunit's mapping: test/a/b.gleam is module a@b, test/x/y.erl is y.
module_name(File) ->
    Name = case filename:extension(File) of
        <<".gleam">> ->
            binary:replace(filename:rootname(File), <<"/">>, <<"@">>, [global]);
        <<".erl">> ->
            filename:rootname(filename:basename(File))
    end,
    binary_to_atom(Name, utf8).

%% A module with tests runs them, then the handler check, in the current
%% eunit process (local), as {module, M} alone would. A module without
%% tests, or one that does not load, is left to eunit as gleeunit leaves it.
module_tests(Module) ->
    case has_tests(Module) of
        true ->
            Check = atom_to_list(Module) ++ " leaves no telemetry handler attached",
            {setup, local, fun handler_snapshot/0, fun(Before) ->
                [{module, Module}, {Check, fun() -> handler_check(Module, Before) end}]
            end};
        false ->
            {module, Module}
    end.

%% eunit's naming convention: an exported *_test/0 or *_test_/0.
has_tests(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            lists:any(fun({Name, 0}) ->
                              Text = atom_to_list(Name),
                              lists:suffix("_test", Text) orelse lists:suffix("_test_", Text);
                         ({_Name, _Arity}) ->
                              false
                      end, Module:module_info(exports));
        {error, _} ->
            false
    end.

%% The attached handlers, as {Id, EventName} pairs in a stable order.
handler_snapshot() ->
    lists:sort([{Id, Name} || #{id := Id, event_name := Name} <- telemetry:list_handlers([])]).

%% Fail, naming Module and the handlers, if the handler table is not what
%% it was in Before.
handler_check(Module, Before) ->
    After = handler_snapshot(),
    case {After -- Before, Before -- After} of
        {[], []} ->
            nil;
        {Attached, Detached} ->
            erlang:error({telemetry_handlers_changed, Module,
                          #{left_attached => Attached, detached => Detached}})
    end.
