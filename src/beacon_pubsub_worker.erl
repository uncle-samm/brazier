-module(beacon_pubsub_worker).
-behaviour(gen_server).

%% Cross-node forwarding worker, the port of Phoenix.PubSub.PG2Worker.
%%
%% Each node runs pool_size workers. Worker Shard joins the pg group
%% {beacon_pubsub, Shard} in the beacon_pubsub_pg scope. A broadcast on
%% another node sends ONE {forward_to_local, Topic, Message} to the member
%% of its shard group on each remote node, and that worker delivers the
%% message to its node's local subscribers.
%%
%% Overload: the worker never drops a message. When its queue is longer than
%% max_forward_queue it logs at error level and emits
%% [beacon, pubsub, forward, overloaded], at most once per second.

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SCOPE, beacon_pubsub_pg).
-define(OVERLOAD_REPORT_INTERVAL_MS, 1000).

start_link(Shard, Config) ->
    Name = list_to_atom("beacon_pubsub_worker_" ++ integer_to_list(Shard)),
    gen_server:start_link({local, Name}, ?MODULE, {Shard, Config}, []).

init({Shard, Config}) ->
    #{max_forward_queue := MaxQueue} = Config,
    ok = pg:join(?SCOPE, {beacon_pubsub, Shard}, self()),
    beacon_log_ffi:debug(<<"beacon.pubsub">>, "Forwarding worker ~b joined its pg group", [Shard]),
    {ok, #{shard => Shard, max_queue => MaxQueue, last_overload_report => undefined}}.

handle_call(Request, From, State = #{shard := Shard}) ->
    beacon_log_ffi:warning(<<"beacon.pubsub">>, "Worker ~b received unexpected call ~p from ~p",
                           [Shard, Request, From]),
    {reply, {error, unexpected_call}, State}.

handle_cast(Request, State = #{shard := Shard}) ->
    beacon_log_ffi:warning(<<"beacon.pubsub">>, "Worker ~b received unexpected cast ~p", [Shard, Request]),
    {noreply, State}.

handle_info({forward_to_local, Topic, Message}, State) ->
    State1 = check_overload(State),
    case beacon_pubsub_ffi:deliver_local(Topic, Message) of
        {ok, _Count} -> ok;
        {error, not_started} ->
            %% The worker runs under the PubSub supervisor, so the registry
            %% is gone only while that supervisor is shutting down.
            beacon_log_ffi:warning(<<"beacon.pubsub">>, "Worker ~b could not deliver a forwarded "
                                   "message on ~ts: PubSub is stopping", [maps:get(shard, State), Topic])
    end,
    {noreply, State1};
handle_info(Message, State = #{shard := Shard}) ->
    beacon_log_ffi:warning(<<"beacon.pubsub">>, "Worker ~b received unexpected message ~p", [Shard, Message]),
    {noreply, State}.

terminate(Reason, #{shard := Shard}) ->
    beacon_log_ffi:info(<<"beacon.pubsub">>, "Forwarding worker ~b stopping: ~p", [Shard, Reason]),
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
                    beacon_log_ffi:error(<<"beacon.pubsub">>, "Forwarding worker ~b is overloaded: ~b queued "
                                         "messages (limit ~b). Messages are not dropped; the node is not "
                                         "keeping up with remote broadcasts.",
                                         [Shard, QueueLen, MaxQueue]),
                    beacon_telemetry_ffi:pubsub_forward_overloaded(QueueLen, Shard),
                    State#{last_overload_report := Now}
            end
    end.
