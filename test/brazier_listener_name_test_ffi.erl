-module(brazier_listener_name_test_ffi).
%% Helpers for listener_name_test: the atom table, the connection owner
%% registry's persistent_term entries, and the via registry's callbacks.
-export([atom_count/0, atoms_since/1, registry_entries/0, register/2, unregister/1,
         whereis/1, send_raises_badarg/1, forget/1, restart_only_child/1]).

atom_count() ->
    erlang:system_info(atom_count).

%% The atoms created since the table held From atoms, by index: the
%% external term format's ATOM_INDEX tag (75) names an atom by its index.
atoms_since(From) when is_integer(From), From >= 0 ->
    [atom_to_binary(binary_to_term(<<131, 75, Index:24>>))
     || Index <- lists:seq(From, erlang:system_info(atom_count) - 1)].

%% persistent_term entries brazier_http_conns keeps (owners, bound ports).
registry_entries() ->
    length([Key || {{brazier_http_conns, _, _} = Key, _} <- persistent_term:get()]).

register(Ref, Pid) ->
    case brazier_http_conns:register_name(Ref, Pid) of
        yes -> true;
        no -> false
    end.

unregister(Ref) ->
    brazier_http_conns:unregister_name(Ref).

whereis(Ref) ->
    case brazier_http_conns:whereis_name(Ref) of
        undefined -> {error, nil};
        Pid -> {ok, Pid}
    end.

%% Whether a send to Ref exits with badarg; a send that returns is false.
send_raises_badarg(Ref) ->
    try brazier_http_conns:send(Ref, ping) of
        _Pid -> false
    catch
        error:badarg -> true
    end.

forget(Ref) ->
    brazier_http_conns:forget_port({via, brazier_http_conns, Ref}).

%% Stop the only child of Parent in order (supervisor:terminate_child/2
%% waits for it to exit) and start it again from the same child spec: a
%% restart by the parent, as when an earlier sibling restarts under
%% rest_for_one. Anything else is a test failure.
restart_only_child(Parent) ->
    [{Id, _Pid, _Type, _Modules}] = supervisor:which_children(Parent),
    ok = supervisor:terminate_child(Parent, Id),
    {ok, _Restarted} = supervisor:restart_child(Parent, Id),
    nil.
