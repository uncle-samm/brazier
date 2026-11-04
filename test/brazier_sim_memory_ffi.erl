-module(brazier_sim_memory_ffi).
-export([kept_state/0, describe_change/2]).

%% What the VM holds outside process heaps that a connection could leave
%% behind: every ETS table with its object count (and its memory in words,
%% for the report), and the number of atoms (atoms are never collected, so
%% one made per connection is a leak for the life of the node). Unlike heap
%% memory, none of these depends on when a process last collected garbage.
kept_state() ->
    Tables = lists:sort([table_state(T) || T <- ets:all()]),
    {[S || S <- Tables, S =/= gone], erlang:system_info(atom_count)}.

%% A table deleted between ets:all/0 and ets:info/2 is `gone`.
table_state(Table) ->
    case {ets:info(Table, name), ets:info(Table, size), ets:info(Table, memory)} of
        {Name, Size, Words} when is_integer(Size), is_integer(Words) ->
            {Table, Name, Size, Words};
        _ ->
            gone
    end.

%% "" when nothing was kept, else each table that appeared, went or holds
%% a different number of objects, and the atom count change. A table's
%% words alone are not compared: a hash table that grew its buckets for a
%% round's peak of concurrent connections keeps them after the objects
%% are gone (ETS shrinks lazily), which is capacity, not kept state.
describe_change({TablesBefore, AtomsBefore}, {TablesAfter, AtomsAfter}) ->
    Before = maps:from_list([{T, {N, S, W}} || {T, N, S, W} <- TablesBefore]),
    After = maps:from_list([{T, {N, S, W}} || {T, N, S, W} <- TablesAfter]),
    Keys = lists:usort(maps:keys(Before) ++ maps:keys(After)),
    Tables = [describe_table(maps:get(K, Before, none), maps:get(K, After, none))
              || K <- Keys, objects(maps:get(K, Before, none)) =/= objects(maps:get(K, After, none))],
    Atoms = case AtomsAfter - AtomsBefore of
        0 -> [];
        Delta -> [io_lib:format("atom count changed by ~w", [Delta])]
    end,
    unicode:characters_to_binary(lists:join("; ", Tables ++ Atoms)).

objects(none) -> none;
objects({_Name, Size, _Words}) -> Size.

describe_table(none, {Name, Size, Words}) ->
    io_lib:format("new table ~p (~w objects, ~w words)", [Name, Size, Words]);
describe_table({Name, Size, Words}, none) ->
    io_lib:format("table ~p deleted (had ~w objects, ~w words)", [Name, Size, Words]);
describe_table({Name, SizeB, WordsB}, {_, SizeA, WordsA}) ->
    io_lib:format("table ~p: ~w -> ~w objects, ~w -> ~w words",
                  [Name, SizeB, SizeA, WordsB, WordsA]).
