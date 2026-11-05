%% ASCII case folding for brazier/internal/ascii on Erlang: the one
%% implementation of it on this target. The render folds every attribute
%% name of every render with it, and the HTTP server every request's field
%% names, so it scans bytes and copies nothing when there is nothing to
%% fold.
-module(brazier_ascii_ffi).

-export([lowercase/1]).

%% `Text` with `A-Z` lowercased, every other byte unchanged: a byte of a
%% multibyte UTF-8 sequence is never in `A-Z`, so a character outside ASCII
%% is kept as it is. Text with no `A-Z` is returned as it is, without a
%% copy. Unlike `string:lowercase/1`, which lowercases in Unicode and
%% raises and catches an exception internally for every string that is
%% already lowercase, this only scans bytes.
-spec lowercase(binary()) -> binary().
lowercase(Text) ->
    case has_upper(Text) of
        false -> Text;
        true -> << <<(lower_byte(C))>> || <<C>> <= Text >>
    end.

has_upper(<<>>) -> false;
has_upper(<<C, _/binary>>) when C >= $A, C =< $Z -> true;
has_upper(<<_, Rest/binary>>) -> has_upper(Rest).

lower_byte(C) when C >= $A, C =< $Z -> C + 32;
lower_byte(C) -> C.
