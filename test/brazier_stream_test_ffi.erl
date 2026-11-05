-module(brazier_stream_test_ffi).
-export([encode_term/1]).

%% Encode a term that json:decode produced (or gleam/json parsed into a
%% Dynamic) back to JSON text. Maps of at most 32 keys iterate in key
%% order, so equal values encode to equal text.
encode_term(Term) ->
    iolist_to_binary(json:encode(Term)).
