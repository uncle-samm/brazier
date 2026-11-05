-module(brazier_bundle_manifest_ffi).
%% The node's loaded client bundle and dev build id (see brazier/ssr).
%%
%% `ssr.load_client_bundle` reads `brazier_client.manifest` once, when the
%% server starts (and again after each `brazier/dev` rebuild), and stores the
%% outcome here; every page render and every join reads it from here, with no
%% file access. persistent_term fits a value that is read on every request
%% and written once per start or rebuild: a read is a constant-time lookup
%% with no copy. A write makes every process holding the old value copy it
%% at its next GC, so a store only writes when the value changed.
-export([store_bundle/1, loaded_bundle/0, store_dev_build/1, dev_build/0]).

-define(BUNDLE, brazier_client_bundle).
-define(DEV_BUILD, brazier_dev_build).

%% Store the outcome of a manifest read: {ok, Name} or {error, Reason}.
%% Returns true when it differs from the stored one (and was written).
store_bundle(Loaded) ->
    case persistent_term:get(?BUNDLE, undefined) of
        Loaded -> false;
        _ ->
            persistent_term:put(?BUNDLE, Loaded),
            true
    end.

%% {ok, Loaded} with the stored outcome, {error, nil} before any load.
loaded_bundle() ->
    case persistent_term:get(?BUNDLE, undefined) of
        undefined -> {error, nil};
        Loaded -> {ok, Loaded}
    end.

store_dev_build(Id) when is_binary(Id) ->
    persistent_term:put(?DEV_BUILD, Id),
    nil.

%% {some, Id} under brazier/dev, none otherwise.
dev_build() ->
    case persistent_term:get(?DEV_BUILD, undefined) of
        undefined -> none;
        Id -> {some, Id}
    end.
