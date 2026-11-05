-module(brazier_session_bindings_test_ffi).

%% Helpers for test/brazier/session_bindings_test.gleam: the session pg
%% group names (which every connected node can list) and the node-local
%% bindings table that maps them back to session ids.

-export([spawn_holder/0, bind/3, stop/1, binding_rows/1, bound_sessions/1,
         group_names/0, names_mention/2, group_key/2, fingerprint/1,
         plain_sha256/1, start_maintenance/1, await_sweep/1, stop_owner/1]).

-define(BINDINGS, brazier_bound_sessions).
-define(SCOPE, brazier_session_pg).
-define(WAIT_MS, 5000).

%% A process that does nothing until stopped.
spawn_holder() ->
    spawn(fun() -> receive stop -> ok end end).

%% Bind Pid to SessionId in Namespace (the registry must be running);
%% returns the local member count.
bind(Namespace, SessionId, Pid) ->
    nil = brazier_session_ffi:ensure_registry(),
    brazier_session_ffi:bind_process(Namespace, SessionId, Pid).

%% Kill Pid; returns once it is gone.
stop(Pid) ->
    Ref = monitor(process, Pid),
    true = exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _} -> nil
    after ?WAIT_MS -> error({stop, still_running})
    end.

%% How many rows the bindings table holds for Namespace.
binding_rows(Namespace) ->
    length(ets:match_object(?BINDINGS, {{Namespace, '_', '_'}, '_'})).

bound_sessions(Namespace) ->
    brazier_session_ffi:local_bound_sessions(Namespace).

%% Every group name in the session scope, as pg:which_groups/1 lists it on
%% this node.
group_names() ->
    pg:which_groups(?SCOPE).

%% Whether Needle appears anywhere in the external term format of the group
%% names (inside a binary, an atom or any nested term).
names_mention(Names, Needle) when byte_size(Needle) > 0 ->
    binary:match(term_to_binary(Names), Needle) =/= nomatch.

%% The third element of the group name.
group_key(Namespace, SessionId) ->
    {brazier_session, Namespace, Key} = brazier_session_ffi:session_group(Namespace, SessionId),
    Key.

fingerprint(SessionId) ->
    brazier_session_ffi:binding_fingerprint(SessionId).

plain_sha256(Bytes) ->
    crypto:hash(sha256, Bytes).

%% Start a store's maintenance process for Namespace, owned by a fresh
%% owner process, sweeping every 5ms; each sweep (which runs after the
%% bindings prune) tells the caller. Returns the owner, which stop_owner/1
%% stops (and the maintenance process with it).
start_maintenance(Namespace) ->
    Parent = self(),
    Owner = spawn_holder(),
    _Maintenance = brazier_session_ffi:start_maintenance(
                     Owner, Namespace, 5,
                     fun() -> Parent ! {swept, Owner}, nil end,
                     fun(_Node) -> nil end),
    Owner.

%% Wait for a whole sweep of Owner's maintenance process (prune included)
%% that began after this call did. Notices already queued are taken first;
%% the first one after that may come from a sweep that pruned before the
%% call, but the one after it comes from a sweep that started later.
await_sweep(Owner) ->
    flush_sweeps(Owner),
    nil = next_sweep(Owner),
    next_sweep(Owner).

next_sweep(Owner) ->
    receive
        {swept, Owner} -> nil
    after ?WAIT_MS -> error({await_sweep, no_sweep})
    end.

flush_sweeps(Owner) ->
    receive
        {swept, Owner} -> flush_sweeps(Owner)
    after 0 -> ok
    end.

stop_owner(Owner) ->
    nil = stop(Owner),
    flush_sweeps(Owner),
    nil.
