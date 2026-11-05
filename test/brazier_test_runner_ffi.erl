-module(brazier_test_runner_ffi).

%% The test suite's runner: gleeunit's discovery and options, with two
%% checks. Each test fails when it leaves a message in the test process's
%% mailbox (mailbox_checked/4), and one more test per module fails when the
%% module's tests left a telemetry handler attached.
%%
%% Telemetry handlers are node-wide. One left attached by a test keeps
%% sending events to eunit's shared test process (eunit runs every module's
%% tests in one process), where a later module's test receives them: the
%% wave 4 failure in presence/scoped_cleanup_test was an event of that kind.
%% The check runs inside eunit, as a fixture of the module's group
%% (eunit's {setup, local, Setup, Instantiator}), so its failure is
%% reported against the module that leaked, as ExUnit reports an on_exit
%% failure against its test.

-export([run/0, handler_snapshot/0, handler_check/2, mailbox_checked/4,
         checked_generated/3]).

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
                [checked_module(Module), {Check, fun() -> handler_check(Module, Before) end}]
            end};
        false ->
            {module, Module}
    end.

%% {module, Module} with each test wrapped in mailbox_checked/3: the tests
%% eunit would find (exported *_test/0 and *_test_/0, in export order),
%% under eunit's title for the module. eunit's other module conventions (a
%% Module_tests companion, a test wrapper) are not used by this suite; a
%% module that relies on one crashes here instead of losing its tests.
checked_module(Module) ->
    Exports = Module:module_info(exports),
    Companion = list_to_atom(atom_to_list(Module) ++ "_tests"),
    case {code:which(Companion), lists:member({eunit_wrapper_, 1}, Exports)} of
        {non_existing, false} -> ok;
        Unsupported -> erlang:error({unsupported_eunit_module_convention, Module, Unsupported})
    end,
    Tests = lists:filtermap(fun({Function, 0}) ->
                                    checked_test(Module, Function);
                               (_) ->
                                    false
                            end, Exports),
    {"module '" ++ atom_to_list(Module) ++ "'", Tests}.

checked_test(Module, Function) ->
    Name = atom_to_list(Function),
    Location = {Module, Function, 0},
    case {lists:suffix("_test", Name), lists:suffix("_test_", Name)} of
        {true, _} ->
            {true, {Location, fun() -> mailbox_checked(Module, Function, fun Module:Function/0) end}};
        {_, true} ->
            {true, {generator, fun() -> checked_generated(Module, Function, Module:Function()) end}};
        _ ->
            false
    end.

%% The suite's generators all return a Gleam Timeout, {timeout, Seconds,
%% Fun}. Any other shape crashes, naming the test, so a new one is added
%% here rather than run unchecked.
checked_generated(Module, Function, {timeout, Seconds, Run}) when is_function(Run, 0) ->
    {timeout, Seconds, {{Module, Function, 0}, fun() -> mailbox_checked(Module, Function, Run) end}};
checked_generated(Module, Function, Other) ->
    erlang:error({unsupported_test_generator, Module, Function, Other}).

mailbox_checked(Module, Function, Run) ->
    mailbox_checked(residue_pending(), Module, Function, Run).

%% Run one test, then fail it, naming the messages, if it left any in the
%% test process's mailbox. eunit runs every test of every module in this
%% process, so a message a test leaves (a late reply, an event it did not
%% assert on) reaches the next test's receive. Failing here blames the test
%% that left it, as the handler check blames the module (ExUnit runs every
%% test in a process of its own, so residue dies with it). A message that
%% arrives only after its test has ended is blamed on the test running
%% then: a test is done when it has received everything it caused.
%%
%% The mailbox is emptied either way, so residue never reaches the next
%% test. When the test itself failed its failure is the one reported. The
%% residue of a module in Pending is emptied without failing the test.
mailbox_checked(Pending, Module, Function, Run) ->
    try Run() of
        _ ->
            case drain_mailbox([]) of
                [] -> nil;
                Residue -> residue(Pending, Module, Function, Residue)
            end
    catch
        Class:Reason:Stack ->
            _ = drain_mailbox([]),
            erlang:raise(Class, Reason, Stack)
    end.

residue(Pending, Module, Function, Residue) ->
    case lists:member(Module, Pending) of
        true -> nil;
        false -> erlang:error({mailbox_residue, {Module, Function}, Residue})
    end.

%% Modules whose tests still leave messages in the mailbox, each waiting
%% for a fix by the workstream that owns it (docs/TESTING.md, "Mailbox
%% residue"). Their residue is emptied after each test without failing
%% it. Remove a module once its tests leave none; never add one.
residue_pending() ->
    [
     %% An unreceived model_sync and patch.
     'brazier@runtime_test',
     %% Event acks (empty patches), send_error and send_hard_navigate
     %% frames the telemetry assertions do not receive.
     'brazier@runtime_telemetry_test',
     %% Unreceived patches and bare {Ref, Int} replies.
     'brazier@runtime_versioning_test',
     %% [brazier, session, expired] events and a brazier_session_revoked
     %% message.
     'brazier@session_security_test'
    ].

drain_mailbox(Acc) ->
    receive
        Message -> drain_mailbox([Message | Acc])
    after 0 ->
        lists:reverse(Acc)
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
