-module(brazier_web_push_test_ffi).
-export([decrypt/3, es256_verify/3]).

%% The browser's side of RFC 8291, written apart from the module under
%% test: decrypt an aes128gcm body with the browser's private key and auth
%% secret. Returns {ok, Plaintext} or {error, Reason}.
decrypt(Body, UaPrivate, Auth) ->
    try
        <<Salt:16/binary, Rs:32, IdLen:8, Rest/binary>> = Body,
        <<AsPublic:IdLen/binary, Ciphertext/binary>> = Rest,
        {UaPublic, _} = crypto:generate_key(ecdh, prime256v1, UaPrivate),
        Ecdh = crypto:compute_key(ecdh, AsPublic, UaPrivate, prime256v1),
        Ikm = hkdf(Auth, Ecdh, <<"WebPush: info", 0, UaPublic/binary, AsPublic/binary>>, 32),
        Cek = hkdf(Salt, Ikm, <<"Content-Encoding: aes128gcm", 0>>, 16),
        Nonce = hkdf(Salt, Ikm, <<"Content-Encoding: nonce", 0>>, 12),
        TagAt = byte_size(Ciphertext) - 16,
        <<Encrypted:TagAt/binary, Tag:16/binary>> = Ciphertext,
        case crypto:crypto_one_time_aead(aes_128_gcm, Cek, Nonce, Encrypted, <<>>, Tag, false) of
            error -> {error, <<"the tag does not match">>};
            Record ->
                case strip(Record) of
                    {ok, Plain} when Rs >= 18 -> {ok, Plain};
                    {ok, _} -> {error, <<"record size under 18">>};
                    Error -> Error
                end
        end
    catch
        Class:Reason -> {error, iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.

hkdf(Salt, Ikm, Info, Length) ->
    Prk = crypto:mac(hmac, sha256, Salt, Ikm),
    <<Okm:Length/binary, _/binary>> = crypto:mac(hmac, sha256, Prk, <<Info/binary, 1>>),
    Okm.

%% The last record ends in 2 then zero or more zeros of padding.
strip(<<>>) -> {error, <<"no delimiter">>};
strip(Record) ->
    Size = byte_size(Record) - 1,
    case Record of
        <<Rest:Size/binary, 0>> -> strip(Rest);
        <<Plain:Size/binary, 2>> -> {ok, Plain};
        _ -> {error, <<"the delimiter is not 2">>}
    end.

%% Check a JWS ES256 signature (R and S, 32 bytes each) with an
%% uncompressed public key.
es256_verify(Message, <<R:256, S:256>>, Public) ->
    Der = public_key:der_encode('ECDSA-Sig-Value', {'ECDSA-Sig-Value', R, S}),
    crypto:verify(ecdsa, sha256, Message, Der, [Public, prime256v1]);
es256_verify(_, _, _) ->
    false.
