-module(brazier_csrf_ffi).
-export([new_store/1, put_token/3, consume_token/3]).

%% SECURITY: Atom creation constraint.
%% CSRF store names come from developer code at compile time, not from runtime
%% user input. The validate_atom_name/1 guard restricts names to alphanumeric/
%% underscore/hyphen (max 255 bytes). Each distinct store creates one atom.

new_store(Name) ->
    case validate_atom_name(Name) of
        ok ->
            AtomName = binary_to_atom(<<"brazier_csrf_", Name/binary>>, utf8),
            ets:new(AtomName, [set, public, named_table]);
        {error, Reason} ->
            error(Reason)
    end.

%% Validate that a name is safe for atom conversion.
%% Max 255 bytes, alphanumeric + underscore + hyphen only (no spaces, no special chars).
%% This prevents atom table exhaustion from arbitrary user-controlled input.
validate_atom_name(Name) when byte_size(Name) > 255 ->
    {error, <<"Name too long (max 255 bytes)">>};
validate_atom_name(Name) ->
    case re:run(Name, <<"^[a-zA-Z0-9_-]+$">>) of
        {match, _} -> ok;
        nomatch -> {error, <<"Invalid name: must be alphanumeric, underscore, or hyphen">>}
    end.

put_token(Store, Key, Value) ->
    ets:insert(Store, {Key, Value}),
    nil.

%% Check Token against the stored token for Key in constant time
%% (crypto:hash_equals), then delete exactly that row. select_delete matches
%% the stored value, so if a concurrent request consumed it (or a new token
%% replaced it) between the lookup and the delete, nothing is deleted and
%% this request fails: a token is accepted at most once.
consume_token(Store, Key, Token) ->
    case ets:lookup(Store, Key) of
        [] -> {error, <<"no token issued or already used">>};
        [{_, Stored}] ->
            case byte_size(Stored) =:= byte_size(Token)
                 andalso crypto:hash_equals(Stored, Token) of
                false -> {error, <<"token mismatch">>};
                true ->
                    case ets:select_delete(Store, [{{Key, Stored}, [], [true]}]) of
                        1 -> {ok, nil};
                        0 -> {error, <<"token already used">>}
                    end
            end
    end.
