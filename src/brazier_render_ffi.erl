%% Name checks and HTML escaping for brazier/internal/render on Erlang.
%%
%% These run once per element, attribute and text node of every render, so
%% they scan bytes instead of splitting the string into graphemes. Names are
%% ASCII-only: any byte outside the allowed set, including every byte of a
%% multibyte UTF-8 sequence, refuses the name.
%%
%% The escapers make one pass over the bytes and build iodata from slices of
%% the input and the replacement entities, as Phoenix.HTML's
%% `Phoenix.HTML.Engine.html_escape/1` does. With nothing to escape the
%% accumulator stays empty and the input is returned unchanged. They work on
%% bytes, not graphemes: every `&`, `"`, `<` and `>` is escaped, even one
%% that a combining mark follows.
-module(brazier_render_ffi).

-export([is_markup_name/1, is_event_name/1, ascii_lowercase/1, escape_html/1, escape_attr/1,
         identity/1, iodata_to_string/1]).

-define(IS_ALNUM(C),
    ((C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9))
).

%% A tag or attribute name: one or more of `a-z A-Z 0-9 - _ : .`.
-spec is_markup_name(binary()) -> boolean().
is_markup_name(<<>>) -> false;
is_markup_name(Name) -> markup_bytes(Name).

markup_bytes(<<>>) ->
    true;
markup_bytes(<<C, Rest/binary>>) when
    ?IS_ALNUM(C) orelse C =:= $- orelse C =:= $_ orelse C =:= $: orelse C =:= $.
->
    markup_bytes(Rest);
markup_bytes(_) ->
    false.

%% An event name: one or more of `a-z A-Z 0-9 - _`.
-spec is_event_name(binary()) -> boolean().
is_event_name(<<>>) -> false;
is_event_name(Name) -> event_bytes(Name).

event_bytes(<<>>) ->
    true;
event_bytes(<<C, Rest/binary>>) when ?IS_ALNUM(C) orelse C =:= $- orelse C =:= $_ ->
    event_bytes(Rest);
event_bytes(_) ->
    false.

%% `Name` with `A-Z` lowercased, every other byte unchanged. A name with no
%% `A-Z` is returned as it is, without a copy. Unlike `string:lowercase/1`,
%% which raises and catches an exception for every name that is already
%% lowercase, this only scans bytes; it is the same for the ASCII names
%% `is_markup_name/1` accepts.
-spec ascii_lowercase(binary()) -> binary().
ascii_lowercase(Name) ->
    case has_upper(Name) of
        false -> Name;
        true -> << <<(lower_byte(C))>> || <<C>> <= Name >>
    end.

has_upper(<<>>) -> false;
has_upper(<<C, _/binary>>) when C >= $A, C =< $Z -> true;
has_upper(<<_, Rest/binary>>) -> has_upper(Rest).

lower_byte(C) when C >= $A, C =< $Z -> C + 32;
lower_byte(C) -> C.

%% Escape `&`, `<` and `>`.
-spec escape_html(binary()) -> binary().
escape_html(Text) -> html(Text, Text, 0, 0, []).

html(<<$&, Rest/binary>>, Text, Skip, Len, Acc) ->
    html(Rest, Text, Skip + Len + 1, 0, [Acc, binary_part(Text, Skip, Len), <<"&amp;">>]);
html(<<$<, Rest/binary>>, Text, Skip, Len, Acc) ->
    html(Rest, Text, Skip + Len + 1, 0, [Acc, binary_part(Text, Skip, Len), <<"&lt;">>]);
html(<<$>, Rest/binary>>, Text, Skip, Len, Acc) ->
    html(Rest, Text, Skip + Len + 1, 0, [Acc, binary_part(Text, Skip, Len), <<"&gt;">>]);
html(<<_, Rest/binary>>, Text, Skip, Len, Acc) ->
    html(Rest, Text, Skip, Len + 1, Acc);
html(<<>>, Text, _Skip, _Len, []) ->
    Text;
html(<<>>, Text, Skip, Len, Acc) ->
    iolist_to_binary([Acc, binary_part(Text, Skip, Len)]).

%% Escape `&`, `"`, `<` and `>`.
-spec escape_attr(binary()) -> binary().
escape_attr(Text) -> attr(Text, Text, 0, 0, []).

attr(<<$&, Rest/binary>>, Text, Skip, Len, Acc) ->
    attr(Rest, Text, Skip + Len + 1, 0, [Acc, binary_part(Text, Skip, Len), <<"&amp;">>]);
attr(<<$", Rest/binary>>, Text, Skip, Len, Acc) ->
    attr(Rest, Text, Skip + Len + 1, 0, [Acc, binary_part(Text, Skip, Len), <<"&quot;">>]);
attr(<<$<, Rest/binary>>, Text, Skip, Len, Acc) ->
    attr(Rest, Text, Skip + Len + 1, 0, [Acc, binary_part(Text, Skip, Len), <<"&lt;">>]);
attr(<<$>, Rest/binary>>, Text, Skip, Len, Acc) ->
    attr(Rest, Text, Skip + Len + 1, 0, [Acc, binary_part(Text, Skip, Len), <<"&gt;">>]);
attr(<<_, Rest/binary>>, Text, Skip, Len, Acc) ->
    attr(Rest, Text, Skip, Len + 1, Acc);
attr(<<>>, Text, _Skip, _Len, []) ->
    Text;
attr(<<>>, Text, Skip, Len, Acc) ->
    iolist_to_binary([Acc, binary_part(Text, Skip, Len)]).

%% `Value` unchanged, typed as `Dynamic` on the Gleam side: a stream
%% container's `item_ref`, compared and never called.
-spec identity(term()) -> term().
identity(Value) -> Value.

%% The string a render's `StringTree` holds. The tree is built only from
%% Gleam strings, which are UTF-8 binaries, so it is an iolist of valid
%% UTF-8 and `iolist_to_binary/1` gives the same bytes as
%% `string_tree.to_string` (`unicode:characters_to_binary/1`) without
%% validating them again. On the deep left-nested iolist a walk builds,
%% `characters_to_binary` grows faster than the tree: 0.017 µs a piece at
%% 3,000 pieces, 0.121 µs at 300,000, where `iolist_to_binary` stays at
%% 0.011 to 0.015 µs (docs/PERFORMANCE.md, "Growth with size").
-spec iodata_to_string(iodata()) -> binary().
iodata_to_string(Tree) -> iolist_to_binary(Tree).
