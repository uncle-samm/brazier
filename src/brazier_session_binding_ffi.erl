-module(brazier_session_binding_ffi).
%% Whether a process is bound to a session on this node.
%%
%% The scope and group must be the ones brazier_session_ffi:bind_process/3
%% joins: scope brazier_session_pg, group {brazier_session, Namespace,
%% SessionId}. They are repeated here because that module is owned
%% elsewhere; session_security_test binds through brazier/session and checks
%% this answer, so the two cannot drift apart unnoticed.
-export([is_bound/3]).

-define(PG_SCOPE, brazier_session_pg).

%% A process cannot have been bound when the scope is not running:
%% bind_process/3 crashes instead of binding then.
is_bound(Namespace, SessionId, Pid) ->
    case whereis(?PG_SCOPE) of
        undefined -> false;
        _ ->
            Group = {brazier_session, Namespace, SessionId},
            lists:member(Pid, pg:get_local_members(?PG_SCOPE, Group))
    end.
