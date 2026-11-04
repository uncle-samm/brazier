-module(brazier_crdt_ffi).

%% Hashing for the anti-entropy digest of brazier/store/crdt.

-export([element_hash/1]).

%% The SHA-256 of Element's external term format, as a 256-bit integer.
%% Elements are tuples of atoms, binaries and integers, which the
%% deterministic, minor version 2 encoding writes the same way on every
%% node and OTP release, so two replicas hash one element alike.
element_hash(Element) ->
    Canonical = term_to_binary(Element, [deterministic, {minor_version, 2}]),
    <<Hash:256>> = crypto:hash(sha256, Canonical),
    Hash.
