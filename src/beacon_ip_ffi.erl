-module(beacon_ip_ffi).
%% IP address parsing and CIDR matching for trusted-proxy handling and
%% per-IP limits. IPv4-mapped IPv6 addresses (::ffff:a.b.c.d) are normalized
%% to plain IPv4 so a proxy listed as 10.0.0.1 also matches when the socket
%% is dual-stack.
-export([
    parse_cidrs/1, cidrs_match/2, parse_ip/1, ip_to_string/1,
    peer_ip/1, peer_ip_tuple/1, normalize/1, parse_ip_tuple_result/1,
    local_port/1
]).

%% Parse a list of CIDR or single-address strings.
%% Returns {ok, [{Family, Addr, PrefixLen}]} or {error, Reason}.
parse_cidrs(List) ->
    parse_cidrs(List, []).

parse_cidrs([], Acc) ->
    {ok, lists:reverse(Acc)};
parse_cidrs([Entry | Rest], Acc) ->
    case parse_cidr(Entry) of
        {ok, Parsed} -> parse_cidrs(Rest, [Parsed | Acc]);
        {error, Reason} -> {error, Reason}
    end.

parse_cidr(Entry) when is_binary(Entry) ->
    case binary:split(Entry, <<"/">>) of
        [AddrBin] ->
            case parse_ip_tuple(AddrBin) of
                {ok, Ip} -> {ok, {Ip, full_prefix(Ip)}};
                error -> {error, <<"invalid trusted proxy address: ", Entry/binary>>}
            end;
        [AddrBin, PrefixBin] ->
            case {parse_ip_tuple(AddrBin), parse_prefix(PrefixBin)} of
                {{ok, Ip}, {ok, Prefix}} ->
                    case Prefix =< full_prefix(Ip) of
                        true -> {ok, {mask(Ip, Prefix), Prefix}};
                        false -> {error, <<"trusted proxy prefix too long: ", Entry/binary>>}
                    end;
                _ ->
                    {error, <<"invalid trusted proxy CIDR: ", Entry/binary>>}
            end;
        _ ->
            {error, <<"invalid trusted proxy CIDR: ", Entry/binary>>}
    end.

parse_prefix(Bin) ->
    case byte_size(Bin) > 0 andalso byte_size(Bin) =< 3 andalso all_digits(Bin) of
        true -> {ok, binary_to_integer(Bin)};
        false -> error
    end.

all_digits(<<>>) -> true;
all_digits(<<C, Rest/binary>>) when C >= $0, C =< $9 -> all_digits(Rest);
all_digits(_) -> false.

full_prefix(Ip) when tuple_size(Ip) =:= 4 -> 32;
full_prefix(Ip) when tuple_size(Ip) =:= 8 -> 128.

%% Does the IP (tuple) fall inside any of the parsed CIDRs?
cidrs_match(Ip0, Cidrs) ->
    Ip = normalize(Ip0),
    lists:any(fun({Net, Prefix}) ->
        tuple_size(Net) =:= tuple_size(Ip) andalso mask(Ip, Prefix) =:= Net
    end, Cidrs).

mask(Ip, Prefix) when tuple_size(Ip) =:= 4 ->
    <<N:32>> = list_to_binary(tuple_to_list(Ip)),
    Masked = N band mask_bits(32, Prefix),
    <<A, B, C, D>> = <<Masked:32>>,
    {A, B, C, D};
mask(Ip, Prefix) when tuple_size(Ip) =:= 8 ->
    <<N:128>> = << <<W:16>> || W <- tuple_to_list(Ip) >>,
    Masked = N band mask_bits(128, Prefix),
    list_to_tuple([W || <<W:16>> <= <<Masked:128>>]).

mask_bits(Width, Prefix) ->
    ((1 bsl Prefix) - 1) bsl (Width - Prefix).

%% Parse a textual IP. Returns {ok, NormalizedString} or {error, nil}.
parse_ip(Bin) when is_binary(Bin) ->
    case parse_ip_tuple(Bin) of
        {ok, Ip} -> {ok, ip_to_string(Ip)};
        error -> {error, nil}
    end.

%% Gleam-shaped variant: {ok, IpTuple} | {error, nil}.
parse_ip_tuple_result(Bin) when is_binary(Bin) ->
    case parse_ip_tuple(Bin) of
        {ok, Ip} -> {ok, Ip};
        error -> {error, nil}
    end.

parse_ip_tuple(Bin) ->
    case byte_size(Bin) > 0 andalso byte_size(Bin) =< 45 of
        false -> error;
        true ->
            case inet:parse_strict_address(binary_to_list(Bin)) of
                {ok, Ip} -> {ok, normalize(Ip)};
                {error, _} -> error
            end
    end.

normalize({0, 0, 0, 0, 0, 16#ffff, Hi, Lo}) ->
    {Hi bsr 8, Hi band 16#ff, Lo bsr 8, Lo band 16#ff};
normalize(Ip) ->
    Ip.

ip_to_string(Ip) ->
    list_to_binary(inet:ntoa(normalize(Ip))).

%% Peer address of a connected socket as a normalized string.
peer_ip(Socket) ->
    case peer_ip_tuple(Socket) of
        {ok, Ip} -> {ok, ip_to_string(Ip)};
        {error, Reason} -> {error, Reason}
    end.

peer_ip_tuple(Socket) ->
    try inet:peername(Socket) of
        {ok, {Ip, _Port}} -> {ok, normalize(Ip)};
        {ok, Other} ->
            {error, list_to_binary(io_lib:format("unsupported peer address: ~p", [Other]))};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("peername failed: ~p", [Reason]))}
    catch
        Class:Err ->
            {error, list_to_binary(io_lib:format("peername raised ~p:~p", [Class, Err]))}
    end.

%% Local (listening) port of a connected socket. Used to scope per-listener
%% state such as per-IP WebSocket slots when the listener bound port 0.
local_port(Socket) ->
    try inet:sockname(Socket) of
        {ok, {_Ip, Port}} when is_integer(Port) -> {ok, Port};
        {ok, Other} ->
            {error, list_to_binary(io_lib:format("unsupported local address: ~p", [Other]))};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("sockname failed: ~p", [Reason]))}
    catch
        Class:Err ->
            {error, list_to_binary(io_lib:format("sockname raised ~p:~p", [Class, Err]))}
    end.
