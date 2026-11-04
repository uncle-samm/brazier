-module(brazier_cookie_ffi).
%% Byte-level RFC 6265 section 4.1.1 grammar checks for Set-Cookie.
-export([valid_name/1, valid_value/1, valid_path/1]).

%% cookie-name = token (RFC 7230 tchar): visible ASCII except separators.
valid_name(<<>>) -> false;
valid_name(Name) when is_binary(Name) -> all_bytes(fun is_tchar/1, Name).

%% cookie-value = *cookie-octet / ( DQUOTE *cookie-octet DQUOTE )
%% cookie-octet = %x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E
%% (no CTLs, whitespace, DQUOTE, comma, semicolon or backslash).
valid_value(<<$", Rest/binary>>) when byte_size(Rest) >= 1 ->
    Inner = binary:part(Rest, 0, byte_size(Rest) - 1),
    binary:last(Rest) =:= $" andalso all_bytes(fun is_cookie_octet/1, Inner);
valid_value(Value) when is_binary(Value) ->
    all_bytes(fun is_cookie_octet/1, Value).

%% path-value = <any CHAR except CTLs or ";">
valid_path(Path) when is_binary(Path) ->
    all_bytes(fun(B) -> B >= 16#20 andalso B =< 16#7E andalso B =/= $; end,
              Path).

all_bytes(Pred, Bin) ->
    lists:all(Pred, binary_to_list(Bin)).

is_cookie_octet(16#21) -> true;
is_cookie_octet(B) when B >= 16#23, B =< 16#2B -> true;
is_cookie_octet(B) when B >= 16#2D, B =< 16#3A -> true;
is_cookie_octet(B) when B >= 16#3C, B =< 16#5B -> true;
is_cookie_octet(B) when B >= 16#5D, B =< 16#7E -> true;
is_cookie_octet(_) -> false.

is_tchar(B) when B >= $a, B =< $z -> true;
is_tchar(B) when B >= $A, B =< $Z -> true;
is_tchar(B) when B >= $0, B =< $9 -> true;
is_tchar(B) -> lists:member(B, "!#$%&'*+-.^_`|~").
