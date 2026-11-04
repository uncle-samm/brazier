-module(brazier_crdt_test_ffi).
-export([reductions/1, sorted_digest/1]).

%% The digest a replica broadcast before brazier/store/crdt kept one up to
%% date: the SHA-256 of the sorted fingerprint (crdt_oracle.fingerprint),
%% computed afresh on every tick.
sorted_digest(Fingerprint) ->
    crypto:hash(sha256, term_to_binary(Fingerprint, [deterministic, {minor_version, 2}])).

%% The reductions the calling process spends running Fun. Reductions count
%% work done, not time, so a cost bound on them does not depend on how
%% loaded the machine is.
reductions(Fun) ->
    {reductions, Before} = erlang:process_info(self(), reductions),
    _ = Fun(),
    {reductions, After} = erlang:process_info(self(), reductions),
    After - Before.
