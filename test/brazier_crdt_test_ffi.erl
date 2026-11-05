-module(brazier_crdt_test_ffi).
-export([reductions/1, sorted_digest/1]).

%% Room the measured process has on top of the closure it is given, at
%% first: an append or join allocates a few thousand words. A function that
%% allocates more (the sorting oracle) is measured again with the room
%% doubled, at most HEAP_DOUBLINGS times (16M words, 128 MB).
-define(HEAP_MARGIN_WORDS, 1000000).
-define(HEAP_DOUBLINGS, 4).

%% The digest a replica broadcast before brazier/store/crdt kept one up to
%% date: the SHA-256 of the sorted fingerprint (crdt_oracle.fingerprint),
%% computed afresh on every tick.
sorted_digest(Fingerprint) ->
    crypto:hash(sha256, term_to_binary(Fingerprint, [deterministic, {minor_version, 2}])).

%% The reductions spent running Fun. Reductions count work done, not time,
%% so a cost bound on them does not depend on how loaded the machine is.
%%
%% A garbage collection is charged to the reductions of the process it runs
%% in, and when one runs depends on how full the heap already was, not on
%% Fun: measured in the caller, a 10,000 value append once cost 3427
%% reductions against 992 for 10 values. So Fun runs in a fresh process
%% whose heap holds its closure with room to spare, and a trace session
%% proves no collection ran there. What Fun allocates does not depend on
%% the machine, so a collection means the room was too small for Fun: the
%% measurement is run again with twice the room. If even the largest heap
%% collects, this crashes rather than return a count that is not Fun's.
reductions(Fun) ->
    reductions(Fun, erts_debug:flat_size(Fun), ?HEAP_MARGIN_WORDS, ?HEAP_DOUBLINGS).

reductions(Fun, ClosureWords, Margin, Doublings) ->
    case measure(Fun, ClosureWords + Margin) of
        {ok, Cost} ->
            Cost;
        {collected, _Words, _Events} when Doublings > 0 ->
            reductions(Fun, ClosureWords, Margin * 2, Doublings - 1);
        {collected, Words, Events} ->
            erlang:error({garbage_collected_while_measuring, Words, Events})
    end.

measure(Fun, Words) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Monitor} =
        spawn_opt(
            fun() ->
                receive
                    {Ref, go} -> ok
                end,
                {reductions, Before} = erlang:process_info(self(), reductions),
                _ = Fun(),
                {reductions, After} = erlang:process_info(self(), reductions),
                Parent ! {Ref, cost, After - Before}
            end,
            [monitor, {min_heap_size, Words}, {min_bin_vheap_size, Words}]
        ),
    Session = trace:session_create(?MODULE, Parent, []),
    1 = trace:process(Session, Pid, true, [garbage_collection]),
    Pid ! {Ref, go},
    Cost =
        receive
            {Ref, cost, Spent} -> Spent;
            {'DOWN', Monitor, process, Pid, Reason} -> erlang:error({measured_fun_crashed, Reason})
        end,
    receive
        {'DOWN', Monitor, process, Pid, normal} -> ok
    end,
    Delivered = erlang:trace_delivered(Pid),
    receive
        {trace_delivered, Pid, Delivered} -> ok
    end,
    true = trace:session_destroy(Session),
    case collections(Pid, []) of
        [] -> {ok, Cost};
        Events -> {collected, Words, Events}
    end.

collections(Pid, Events) ->
    receive
        {trace, Pid, Event, _Info} -> collections(Pid, [Event | Events])
    after 0 -> lists:reverse(Events)
    end.
