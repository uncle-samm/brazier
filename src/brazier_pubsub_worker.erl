-module(brazier_pubsub_worker).
-behaviour(gen_server).

%% Cross-node forwarding worker, the port of Phoenix.PubSub.PG2Worker.
%%
%% Each node runs pool_size workers. Worker Shard joins the pg group
%% {brazier_pubsub, Shard} in the brazier_pubsub_pg scope. A broadcast on
%% another node sends ONE {forward_to_local, FromNode, Topic, Message} to
%% the member of its shard group on each remote node, and that worker
%% delivers the message to its node's local subscribers.
%%
%% A forward from a node that is not a verified cluster member
%% (brazier_cluster_ffi:verified/1) is dropped: a debug line per message,
%% and a warning with the count at most once per second.
%%
%% Overload: the worker never drops a message. When its queue is longer than
%% max_forward_queue it logs at error level and emits
%% [brazier, pubsub, forward, overloaded], at most once per second.

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SCOPE, brazier_pubsub_pg).
-define(OVERLOAD_REPORT_INTERVAL_MS, 1000).
-define(DROP_REPORT_INTERVAL_MS, 1000).

start_link(Shard, Config) ->
    Name = list_to_atom("brazier_pubsub_worker_" ++ integer_to_list(Shard)),
    gen_server:start_link({local, Name}, ?MODULE, {Shard, Config}, []).

init({Shard, Config}) ->
    #{max_forward_queue := MaxQueue} = Config,
    ok = pg:join(?SCOPE, {brazier_pubsub, Shard}, self()),
    brazier_log_ffi:debug(<<"brazier.pubsub">>, "Forwarding worker ~b joined its pg group", [Shard]),
    {ok, #{shard => Shard, max_queue => MaxQueue, last_overload_report => undefined,
           dropped => 0, last_drop_report => undefined}}.

handle_call(Request, From, State = #{shard := Shard}) ->
    brazier_log_ffi:warning(<<"brazier.pubsub">>, "Worker ~b received unexpected call ~p from ~p",
                           [Shard, Request, From]),
    {reply, {error, unexpected_call}, State}.

handle_cast(Request, State = #{shard := Shard}) ->
    brazier_log_ffi:warning(<<"brazier.pubsub">>, "Worker ~b received unexpected cast ~p", [Shard, Request]),
    {noreply, State}.

handle_info({forward_to_local, FromNode, Topic, Message}, State) when is_atom(FromNode) ->
    State1 = check_overload(State),
    case brazier_cluster_ffi:verified(FromNode) of
        true ->
            deliver(Topic, Message, State1),
            {noreply, State1};
        false ->
            {noreply, dropped_unverified(FromNode, Topic, State1)}
    end;
handle_info({forward_to_local, _Topic, _Message}, State = #{shard := Shard}) ->
    %% The pre-membership forward names no sender, so it cannot be checked.
    brazier_log_ffi:warning(<<"brazier.pubsub">>, "Worker ~b dropped a forward without a sender node "
                           "(a peer runs an older Brazier)", [Shard]),
    {noreply, State};
handle_info(Message, State = #{shard := Shard}) ->
    brazier_log_ffi:warning(<<"brazier.pubsub">>, "Worker ~b received unexpected message ~0P",
                           [Shard, Message, 10]),
    {noreply, State}.

deliver(Topic, Message, State) ->
    case brazier_pubsub_ffi:deliver_local(Topic, Message) of
        {ok, _Count} -> ok;
        {error, not_started} ->
            %% The worker runs under the PubSub supervisor, so the registry
            %% is gone only while that supervisor is shutting down.
            brazier_log_ffi:warning(<<"brazier.pubsub">>, "Worker ~b could not deliver a forwarded "
                                   "message on ~ts: PubSub is stopping", [maps:get(shard, State), Topic])
    end,
    ok.

dropped_unverified(FromNode, Topic, State = #{shard := Shard, dropped := Dropped,
                                              last_drop_report := Last}) ->
    brazier_log_ffi:debug(<<"brazier.pubsub">>, "Worker ~b dropped a forward on ~ts from ~p: not a "
                         "verified cluster member", [Shard, Topic, FromNode]),
    Now = erlang:monotonic_time(millisecond),
    case Last =:= undefined orelse Now - Last >= ?DROP_REPORT_INTERVAL_MS of
        false ->
            State#{dropped := Dropped + 1};
        true ->
            brazier_log_ffi:warning(<<"brazier.pubsub">>, "Worker ~b dropped ~b forwards from nodes that are "
                                   "not verified cluster members (latest from ~p)",
                                   [Shard, Dropped + 1, FromNode]),
            State#{dropped := 0, last_drop_report := Now}
    end.

terminate(Reason, #{shard := Shard}) ->
    brazier_log_ffi:info(<<"brazier.pubsub">>, "Forwarding worker ~b stopping: ~p", [Shard, Reason]),
    ok.

check_overload(State = #{shard := Shard, max_queue := MaxQueue, last_overload_report := Last}) ->
    {message_queue_len, QueueLen} = erlang:process_info(self(), message_queue_len),
    case QueueLen > MaxQueue of
        false ->
            State;
        true ->
            Now = erlang:monotonic_time(millisecond),
            case Last =:= undefined orelse Now - Last >= ?OVERLOAD_REPORT_INTERVAL_MS of
                false ->
                    State;
                true ->
                    brazier_log_ffi:error(<<"brazier.pubsub">>, "Forwarding worker ~b is overloaded: ~b queued "
                                         "messages (limit ~b). Messages are not dropped; the node is not "
                                         "keeping up with remote broadcasts.",
                                         [Shard, QueueLen, MaxQueue]),
                    brazier_telemetry_ffi:pubsub_forward_overloaded(QueueLen, Shard),
                    State#{last_overload_report := Now}
            end
    end.
