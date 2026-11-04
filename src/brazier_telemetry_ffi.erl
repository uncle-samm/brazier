-module(brazier_telemetry_ffi).
%% Brazier's bridge to the Erlang `telemetry` library.
%%
%% Every Gleam handler is attached through ONE trampoline, dispatch/4, with
%% the Gleam closure stored in the handler config (the same shape
%% telemetry_metrics reporters use). Atom keys are turned into strings only
%% inside dispatch, so the conversion cost is paid only when a handler is
%% attached.
%%
%% Brazier's own events are emitted by the catalogue functions at the end of
%% this module. They use literal atoms, so emitting never creates atoms, and
%% with no handler attached an emit is one persistent_term read plus one ETS
%% lookup inside telemetry:execute/3.
%%
%% The prefix lives in one macro so a rename is a one-line change.
-define(PREFIX, brazier).
-define(FAILURE_LOGGER_ID, <<"brazier-telemetry-handler-failure-logger">>).
-define(MAX_SEGMENT_BYTES, 255).
-define(MAX_ID_BYTES, 255).

-export([
    start/0,
    prefix/0,
    attach/3,
    detach/1,
    execute/3,
    span/3,
    dispatch/4,
    log_handler_failure/4,
    lookup_int/2,
    lookup_string/2,
    %% Catalogue emitters.
    http_request_span/3,
    http_connection/3,
    ws_upgrade_span/2,
    ws_close/8,
    ws_rate_limited/3,
    ws_backpressure/3,
    runtime_span/5,
    runtime_render_span/4,
    runtime_stop/2,
    runtime_stop_failed/4,
    effect_run_span/2,
    effect_timer_rejected/1,
    effect_after_rejected/1,
    effect_background_rejected/1,
    ssr_join_token_too_large/2,
    store_write/4,
    store_sync_span/3,
    session_event/2,
    pubsub_broadcast/3,
    pubsub_forward_overloaded/2,
    subscription_changed/2,
    cluster_node/3,
    cluster_peer_rejected/2,
    cluster_connect_failed/2,
    presence_event/4,
    presence_replica/3,
    presence_transfer_span/3
]).

%% --- Lifecycle ---

%% Start the telemetry application and attach the handler-failure logger.
%% Idempotent: an already attached logger is the state we want.
start() ->
    case application:ensure_all_started(telemetry) of
        {ok, _Started} ->
            case telemetry:attach(?FAILURE_LOGGER_ID, [telemetry, handler, failure],
                                  fun ?MODULE:log_handler_failure/4, #{}) of
                ok ->
                    brazier_log_ffi:info(<<"brazier.telemetry">>, "started; handler-failure logger attached"),
                    {ok, nil};
                {error, already_exists} ->
                    {ok, nil}
            end;
        {error, Reason} ->
            brazier_log_ffi:error(<<"brazier.telemetry">>, "could not start the telemetry application: ~p",
                                 [Reason]),
            {error, {start_failed, format(Reason)}}
    end.

prefix() ->
    atom_to_binary(?PREFIX, utf8).

%% --- Handlers ---

%% Attach a Gleam handler to a list of event names. Event names come from
%% developer code, so their segments become atoms (bounded by the code).
attach(Id, Events, Handler) ->
    case validate_id(Id) of
        {error, _} = Error -> Error;
        ok ->
            case to_atom_names(Events, []) of
                {error, _} = Error -> Error;
                {ok, AtomEvents} ->
                    case start() of
                        {error, _} = Error -> Error;
                        {ok, nil} ->
                            case telemetry:attach_many(Id, AtomEvents, fun ?MODULE:dispatch/4,
                                                       #{handler => Handler}) of
                                ok ->
                                    brazier_log_ffi:info(<<"brazier.telemetry">>, "attached handler ~ts to ~p",
                                                        [Id, AtomEvents]),
                                    {ok, nil};
                                {error, already_exists} ->
                                    {error, {already_attached, Id}}
                            end
                    end
            end
    end.

detach(Id) ->
    case telemetry:detach(Id) of
        ok ->
            brazier_log_ffi:info(<<"brazier.telemetry">>, "detached handler ~ts", [Id]),
            {ok, nil};
        {error, not_found} ->
            {error, {not_attached, Id}}
    end.

%% The trampoline every Gleam handler runs through. Builds the Gleam
%% `Event(name, measurements, metadata)` record.
dispatch(Name, Measurements, Metadata, #{handler := Handler}) ->
    Event = {event,
             [segment_to_binary(Segment) || Segment <- Name],
             keys_to_binary(Measurements),
             keys_to_binary(Metadata)},
    Handler(Event),
    ok.

%% Logs `[telemetry, handler, failure]`. telemetry has already detached the
%% failing handler; the emitting process is unaffected. The handler config is
%% never logged: for Gleam handlers it is a closure that may capture secrets.
log_handler_failure(_Name, _Measurements, Metadata, _Config) ->
    %% telemetry always sets these keys on the failure event.
    #{handler_id := HandlerId, event_name := EventName, kind := Kind,
      reason := Reason, stacktrace := Stacktrace} = Metadata,
    brazier_log_ffi:error(<<"brazier.telemetry">>, "handler ~p crashed on event ~p and was detached: ~p:~p~n~p",
                         [HandlerId, EventName, Kind, Reason, Stacktrace]),
    ok.

%% --- Emitting from Gleam ---

%% Execute an event from Gleam code. Name segments must already exist as
%% atoms: attaching a handler creates them, so when one does not exist no
%% handler can be listening and there is nothing to deliver. Measurement and
%% metadata keys stay strings, so this never creates atoms.
execute(Name, Measurements, Metadata) ->
    case validate_name(Name) of
        {error, _} = Error -> Error;
        ok ->
            case existing_atom_name(Name, []) of
                none -> {ok, nil};
                {ok, AtomName} ->
                    telemetry:execute(AtomName, Measurements, Metadata),
                    {ok, nil}
            end
    end.

%% Run Run inside a telemetry span. The stop event carries the same metadata
%% as the start event, as telemetry recommends.
span(Name, Metadata, Run) ->
    case validate_name(Name) of
        {error, Reason} -> erlang:error({brazier_telemetry_invalid_span_name, Reason});
        ok ->
            case existing_atom_name(Name, []) of
                none -> Run();
                {ok, AtomName} ->
                    telemetry:span(AtomName, Metadata, fun() -> {Run(), Metadata} end)
            end
    end.

%% --- Typed accessors ---

lookup_int(Map, Key) ->
    case maps:find(Key, Map) of
        {ok, Value} when is_integer(Value) -> {ok, Value};
        _ -> {error, nil}
    end.

lookup_string(Map, Key) ->
    case maps:find(Key, Map) of
        {ok, Value} when is_binary(Value) -> {ok, Value};
        {ok, Value} when is_atom(Value) -> {ok, atom_to_binary(Value, utf8)};
        _ -> {error, nil}
    end.

%% --- Catalogue emitters (literal atoms only) ---

%% [brazier, http, request] span. The route is only known once the handler
%% has routed the request, so Run returns it:
%% {Result, Route, Status, ReqBytes, RespBytes}. Start (and exception)
%% metadata is method and connection_id; stop adds route and status.
http_request_span(Method, ConnectionId, Run) ->
    Meta = #{method => Method, connection_id => ConnectionId},
    telemetry:span([?PREFIX, http, request], Meta, fun() ->
        {Result, Route, Status, ReqBytes, RespBytes} = Run(),
        {Result,
         #{req_body_bytes => ReqBytes, resp_body_bytes => RespBytes},
         Meta#{route => Route, status => Status}}
    end).

%% [brazier, http, connection, accepted | rejected | closed]
http_connection(Outcome, Duration, Reason) ->
    telemetry:execute([?PREFIX, http, connection, connection_outcome(Outcome)],
                      #{count => 1, duration => Duration},
                      #{reason => Reason}).

connection_outcome(accepted) -> accepted;
connection_outcome(rejected) -> rejected;
connection_outcome(closed) -> closed.

%% [brazier, ws, upgrade] span. Run returns {Result, ResultLabel}.
ws_upgrade_span(Route, Run) ->
    Meta = #{route => Route},
    telemetry:span([?PREFIX, ws, upgrade], Meta, fun() ->
        {Result, Label} = Run(),
        {Result, Meta#{result => Label}}
    end).

%% [brazier, ws, close]
ws_close(Duration, FramesIn, FramesOut, BytesIn, BytesOut, CloseCode, Reason, ConnectionId) ->
    telemetry:execute([?PREFIX, ws, close],
                      #{duration => Duration, frames_in => FramesIn, frames_out => FramesOut,
                        bytes_in => BytesIn, bytes_out => BytesOut},
                      #{close_code => CloseCode, reason => Reason,
                        connection_id => ConnectionId}).

%% [brazier, ws, rate_limited]
ws_rate_limited(Violations, Kind, ConnectionId) ->
    telemetry:execute([?PREFIX, ws, rate_limited], #{count => 1, violations => Violations},
                      #{kind => Kind, connection_id => ConnectionId}).

%% [brazier, ws, backpressure]
ws_backpressure(QueueLen, Reason, ConnectionId) ->
    telemetry:execute([?PREFIX, ws, backpressure], #{queue_len => QueueLen},
                      #{reason => Reason, connection_id => ConnectionId}).

%% [brazier, runtime, mount | handle_event | navigate] span.
runtime_span(Kind, Route, Event, ConnectionId, Run) ->
    Meta = #{route => Route, event => Event, connection_id => ConnectionId},
    telemetry:span([?PREFIX, runtime, runtime_kind(Kind)], Meta, fun() -> {Run(), Meta} end).

runtime_kind(mount) -> mount;
runtime_kind(handle_event) -> handle_event;
runtime_kind(navigate) -> navigate.

%% [brazier, runtime, render] span. Run returns {Result, PatchBytes}.
runtime_render_span(Route, Event, ConnectionId, Run) ->
    Meta = #{route => Route, event => Event, connection_id => ConnectionId},
    telemetry:span([?PREFIX, runtime, render], Meta, fun() ->
        {Result, PatchBytes} = Run(),
        {Result, #{patch_bytes => PatchBytes}, Meta}
    end).

%% [brazier, runtime, stop]
runtime_stop(Uptime, Reason) ->
    telemetry:execute([?PREFIX, runtime, stop], #{uptime => Uptime}, #{reason => Reason}).

%% [brazier, runtime, stop] for a runtime that did not stop on Shutdown:
%% Reason is `crash` or `exit`, Kind the exception class (`exit` for an
%% exit signal) and Error the bounded description of the reason.
runtime_stop_failed(Uptime, Reason, Kind, Error) ->
    telemetry:execute([?PREFIX, runtime, stop], #{uptime => Uptime},
                      #{reason => Reason, kind => Kind, error => Error}).

%% [brazier, effect, run] span. The label is `effect`, not `kind`: telemetry
%% writes the exception class to `kind` on the exception event, which would
%% overwrite it.
effect_run_span(Effect, Run) ->
    Meta = #{effect => Effect},
    telemetry:span([?PREFIX, effect, run], Meta, fun() -> {Run(), Meta} end).

%% [brazier, effect, timer, rejected]
effect_timer_rejected(Limit) ->
    telemetry:execute([?PREFIX, effect, timer, rejected], #{}, #{limit => Limit}).

%% [brazier, effect, after, rejected]
effect_after_rejected(Limit) ->
    telemetry:execute([?PREFIX, effect, 'after', rejected], #{}, #{limit => Limit}).

%% [brazier, effect, background, rejected]
effect_background_rejected(Limit) ->
    telemetry:execute([?PREFIX, effect, background, rejected], #{}, #{limit => Limit}).

%% [brazier, ssr, join_token, too_large]
ssr_join_token_too_large(Bytes, Budget) ->
    telemetry:execute([?PREFIX, ssr, join_token, too_large], #{bytes => Bytes},
                      #{budget => Budget}).

%% [brazier, store, write]
store_write(Count, Store, Op, Mode) ->
    telemetry:execute([?PREFIX, store, write], #{count => Count},
                      #{store => Store, op => Op, mode => Mode}).

%% [brazier, store, sync] span. Run returns {Result, Entries, Bytes}.
store_sync_span(Store, Peer, Run) ->
    Meta = #{store => Store, peer => Peer},
    telemetry:span([?PREFIX, store, sync], Meta, fun() ->
        {Result, Entries, Bytes} = Run(),
        {Result, #{entries => Entries, bytes => Bytes}, Meta}
    end).

%% [brazier, session, created | revoked | expired | contention]
session_event(Kind, Reason) ->
    telemetry:execute([?PREFIX, session, session_kind(Kind)], #{count => 1},
                      #{reason => Reason}).

session_kind(created) -> created;
session_kind(revoked) -> revoked;
session_kind(expired) -> expired;
session_kind(contention) -> contention.

%% [brazier, pubsub, broadcast]
pubsub_broadcast(LocalSubscribers, RemoteNodes, Scope) ->
    telemetry:execute([?PREFIX, pubsub, broadcast],
                      #{local_subscribers => LocalSubscribers, remote_nodes => RemoteNodes},
                      #{scope => Scope}).

%% [brazier, pubsub, forward, overloaded]
pubsub_forward_overloaded(QueueLen, Shard) ->
    telemetry:execute([?PREFIX, pubsub, forward, overloaded], #{queue_len => QueueLen},
                      #{shard => Shard}).

%% [brazier, subscription, changed]
subscription_changed(Action, Subscriptions) ->
    telemetry:execute([?PREFIX, subscription, changed], #{subscriptions => Subscriptions},
                      #{action => subscription_action(Action)}).

subscription_action(subscribe) -> subscribe;
subscription_action(unsubscribe) -> unsubscribe.

%% [brazier, cluster, node, up | down]
cluster_node(Direction, Node, Reason) ->
    telemetry:execute([?PREFIX, cluster, node, node_direction(Direction)], #{count => 1},
                      #{node => Node, reason => Reason}).

node_direction(node_up) -> up;
node_direction(node_down) -> down.

%% [brazier, cluster, peer, rejected]
cluster_peer_rejected(Node, Reason) ->
    telemetry:execute([?PREFIX, cluster, peer, rejected], #{count => 1},
                      #{node => Node, reason => Reason}).

%% [brazier, cluster, connect, failed]
cluster_connect_failed(Node, Reason) ->
    telemetry:execute([?PREFIX, cluster, connect, failed], #{count => 1},
                      #{node => Node, reason => Reason}).

%% [brazier, presence, track | untrack | limit_exceeded]
presence_event(Kind, Count, Tracker, Shard) ->
    telemetry:execute([?PREFIX, presence, presence_kind(Kind)], #{count => Count},
                      #{tracker => Tracker, shard => Shard}).

presence_kind(track) -> track;
presence_kind(untrack) -> untrack;
presence_kind(limit_exceeded) -> limit_exceeded.

%% [brazier, presence, replica, up | down | permdown]
presence_replica(State, Replica, Tracker) ->
    telemetry:execute([?PREFIX, presence, replica, replica_state(State)], #{},
                      #{replica => Replica, tracker => Tracker}).

replica_state(replica_up) -> up;
replica_state(replica_down) -> down;
replica_state(replica_permdown) -> permdown.

%% [brazier, presence, transfer] span. Run returns {Result, Entries, Bytes}.
presence_transfer_span(Tracker, Peer, Run) ->
    Meta = #{tracker => Tracker, peer => Peer},
    telemetry:span([?PREFIX, presence, transfer], Meta, fun() ->
        {Result, Entries, Bytes} = Run(),
        {Result, #{entries => Entries, bytes => Bytes}, Meta}
    end).

%% --- Helpers ---

validate_id(Id) when is_binary(Id), byte_size(Id) > 0, byte_size(Id) =< ?MAX_ID_BYTES -> ok;
validate_id(Id) -> {error, {invalid_handler_id, Id}}.

validate_name([]) ->
    {error, {invalid_event_name, <<"event name must have at least one segment">>}};
validate_name(Name) ->
    case lists:all(fun valid_segment/1, Name) of
        true -> ok;
        false -> {error, {invalid_event_name, join(Name)}}
    end.

valid_segment(Segment) ->
    is_binary(Segment) andalso byte_size(Segment) > 0
        andalso byte_size(Segment) =< ?MAX_SEGMENT_BYTES.

to_atom_names([], []) ->
    {error, {invalid_event_name, <<"handler must listen to at least one event">>}};
to_atom_names([], Acc) ->
    {ok, lists:reverse(Acc)};
to_atom_names([Name | Rest], Acc) ->
    case validate_name(Name) of
        {error, _} = Error -> Error;
        ok -> to_atom_names(Rest, [[binary_to_atom(S, utf8) || S <- Name] | Acc])
    end.

existing_atom_name([], Acc) ->
    {ok, lists:reverse(Acc)};
existing_atom_name([Segment | Rest], Acc) ->
    try binary_to_existing_atom(Segment, utf8) of
        Atom -> existing_atom_name(Rest, [Atom | Acc])
    catch
        error:badarg -> none
    end.

segment_to_binary(Segment) when is_atom(Segment) -> atom_to_binary(Segment, utf8);
segment_to_binary(Segment) when is_binary(Segment) -> Segment;
segment_to_binary(Segment) -> erlang:error({brazier_telemetry_non_atom_event_segment, Segment}).

keys_to_binary(Map) ->
    maps:fold(fun(Key, Value, Acc) -> Acc#{key_to_binary(Key) => Value} end, #{}, Map).

key_to_binary(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
key_to_binary(Key) when is_binary(Key) -> Key;
key_to_binary(Key) -> erlang:error({brazier_telemetry_non_string_key, Key}).

join(Name) ->
    iolist_to_binary(lists:join(<<".">>, [format(S) || S <- Name])).

format(Term) when is_binary(Term) -> Term;
format(Term) -> iolist_to_binary(io_lib:format("~p", [Term])).
