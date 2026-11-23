-module(brazier_web_push_ffi).
-export([generate_keys/0, public_key/1, ecdh/2, aes128gcm_encrypt/3,
         es256_sign/2, priv_file/1]).

%% Web Push's crypto (RFC 8291, RFC 8292), from OTP's crypto and
%% public_key. Every function that takes bytes from outside (a stored key,
%% a browser's p256dh) returns {error, Reason} for bytes that are not a
%% P-256 key, instead of raising: those bytes are data, not a bug.

-define(CURVE, prime256v1).
%% The order of P-256's base point: a private key is 1 to ORDER - 1.
-define(ORDER, 16#FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551).

%% A new P-256 key pair: {Public (65 bytes, uncompressed), Private (32)}.
generate_keys() ->
    {Public, Private} = crypto:generate_key(ecdh, ?CURVE),
    {Public, pad32(Private)}.

%% The public key of a 32-byte private key. OTP derives it from the private
%% key it is given, and takes a scalar past the curve's order without a
%% word, so the range is checked here.
public_key(<<Scalar:256/big-unsigned-integer>>) when Scalar =:= 0; Scalar >= ?ORDER ->
    {error, <<"a private key is a number from 1 to the order of P-256 less one">>};
public_key(Private) when byte_size(Private) =:= 32 ->
    try crypto:generate_key(ecdh, ?CURVE, Private) of
        {Public, _} when byte_size(Public) =:= 65 -> {ok, Public};
        {Public, _} -> {error, <<"the derived public key is ",
                                  (integer_to_binary(byte_size(Public)))/binary,
                                  " bytes, not 65">>}
    catch
        error:Reason -> {error, describe(Reason)}
    end;
public_key(Private) ->
    {error, <<"a private key is 32 bytes, got ",
              (integer_to_binary(byte_size(Private)))/binary>>}.

%% The ECDH shared secret (32 bytes, the x coordinate) of our private key
%% and their uncompressed public key. A point that is not on the curve is
%% refused by crypto, which raises; that is an error here.
ecdh(TheirPublic, OurPrivate) ->
    try crypto:compute_key(ecdh, TheirPublic, OurPrivate, ?CURVE) of
        Secret -> {ok, pad32(Secret)}
    catch
        error:Reason -> {error, describe(Reason)}
    end.

%% AES-128-GCM with no additional data: the ciphertext with its 16-byte
%% tag appended, as RFC 8188 records carry it.
aes128gcm_encrypt(Key, Nonce, Plaintext) ->
    {Ciphertext, Tag} =
        crypto:crypto_one_time_aead(aes_128_gcm, Key, Nonce, Plaintext, <<>>, 16, true),
    <<Ciphertext/binary, Tag/binary>>.

%% An ES256 signature of Message with a 32-byte private key, as JWS wants
%% it (RFC 7518 section 3.4): R and S, 32 bytes each, not crypto's DER.
es256_sign(Message, Private) ->
    Der = crypto:sign(ecdsa, sha256, Message, [Private, ?CURVE]),
    {'ECDSA-Sig-Value', R, S} = public_key:der_decode('ECDSA-Sig-Value', Der),
    <<R:256/big-unsigned-integer, S:256/big-unsigned-integer>>.

%% The text of a file in Brazier's priv directory.
priv_file(Name) ->
    case code:priv_dir(brazier) of
        {error, bad_name} ->
            {error, <<"the brazier application has no priv directory on the code path">>};
        Dir ->
            Path = filename:join(Dir, binary_to_list(Name)),
            case file:read_file(Path) of
                {ok, Bytes} -> {ok, Bytes};
                {error, Reason} ->
                    {error, iolist_to_binary(
                              io_lib:format("cannot read ~ts: ~p", [Path, Reason]))}
            end
    end.

%% crypto may hand back a scalar or coordinate shorter than 32 bytes when it
%% has leading zeros.
pad32(Bytes) when byte_size(Bytes) >= 32 -> Bytes;
pad32(Bytes) -> pad32(<<0, Bytes/binary>>).

describe({_Tag, _Where, Text}) when is_list(Text) ->
    unicode:characters_to_binary(Text);
describe(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
