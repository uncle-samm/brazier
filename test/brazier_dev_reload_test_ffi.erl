-module(brazier_dev_reload_test_ffi).
-export([classify_reload/1]).

%% How a WebSocket handler classifies the dev rebuild broadcast when it
%% arrives on Topic.
classify_reload(Topic) ->
    brazier_transport_ffi:ws_classify_message({brazier_pubsub, Topic, brazier_dev_reload}).
