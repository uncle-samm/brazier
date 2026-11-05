# Use-after-free in file name decoding on macOS hangs or aborts the VM

To: erlang-security@erlang.org (or a private advisory at
https://github.com/erlang/otp/security)

## Summary

On macOS, `prim_file:internal_native2name/1` returns a list built in heap
words it has already released when the name starts with a combining mark
(U+0300 and up). Listing a directory that holds such a file makes
`file:list_dir/1` spin at 100% CPU forever, and the node no longer stops on
SIGTERM. Sending the decoded name to another process aborts the VM. Anyone
who can name a file in a directory a node lists can stop that node. The
cause is one missing line in `cleanup_norm` in
`erts/emulator/beam/erl_unicode.c`.

## Versions

Hangs on macOS 26 (Darwin 25.6.0), Apple silicon, the default `utf8` file
name encoding, with the prebuilt OTP 28.4, 28.5.0.8 and 29.1.2. `master`
has the same code, which dates from R14B01. Linux is not affected (its
`utf8` encoding does not normalize), and neither is macOS with `+fnl`.

## Reproduction

```sh
mkdir d && printf x > "d/$(printf '\314\201b')"
```

The file name is U+0301 followed by `b` (bytes `cc 81 62`). Listing the
directory never returns, and SIGTERM does not stop the VM:

```sh
erl -noshell -eval 'io:format("~w~n", [file:list_dir("d")]), halt().' &
sleep 10; kill -TERM $!; sleep 2; kill -0 $! && echo "still running"; kill -KILL $!
```

This prints `still running`. The VM logs `SIGTERM received - shutting
down` but keeps running.

The decoder on its own, without a directory:

```sh
erl -noshell -eval 'erlang:display(prim_file:internal_native2name(<<204,129,$b>>)), halt().'
```

This prints `[<cp/header:0x00000000000000c0>` on macOS and `[769,98]` on
Linux. Sending that value to another process aborts the VM with
`size_object: bad tag for 0xc0` (exit status 134):

```sh
erl -noshell -eval 'L = prim_file:internal_native2name(<<204,129,$b>>), Pid = spawn(fun() -> receive X -> erlang:display(X) end end), Pid ! L, timer:sleep(100), halt().'
```

Expected: `file:list_dir("d")` returns `{ok, [[769, 98]]}`.

## Cause

On macOS the name encoding is `ERL_FILENAME_UTF8_MAC`, so
`prim_file_internal_native2name_1` (`erl_unicode.c:2735`) calls
`do_utf8_to_list_normalize` (line 1569). That function allocates with
`HAlloc` and walks the name backwards, holding back code points that may
compose. If some are still held at the start of the name, it calls
`cleanup_norm(&hp, ...)` (line 1624) to cons them, then
`HRelease(p, hp_end, hp)` (line 1627) to give back what it did not use.

`cleanup_norm` (lines 1475-1498) advances a local copy of the heap pointer
but never writes it back through `hpp`, so `HRelease` releases the cells it
just built and the returned list points into freed heap. The next
allocation overwrites them; in `prim_file:list_dir_convert/3` the name
becomes a list containing itself, which `file_server` then copies forever.
`handle_potential_norm` has the same shape and does write `*hpp = hp`
(line 1564).

## Fix

```diff
--- a/erts/emulator/beam/erl_unicode.c
+++ b/erts/emulator/beam/erl_unicode.c
@@ -1494,6 +1494,7 @@ static void cleanup_norm(Eterm **hpp, Uint16 *savepoints, int numpoints, Eterm *
 	    i += res;
 	}
     }
+    *hpp = hp;
     *retp = ret;
 }
```

Tested on macOS by building `OTP-29.1.2` from source with this line and
without it. With it, the decoder returns `[769,98]`,
`<<204,129,204,128,$b>>` gives `[769,768,98]`, `file:list_dir("d")` returns
`{ok, [[769, 98]]}` and `file:del_dir_r("d")` returns `ok`. Without it, the
same build hangs. OTP's own test suites were not run.

A regression test could check that `prim_file:internal_native2name(<<204,129,$b>>)`
equals `[769, 98]` and can be sent to another process.

I used an AI assistant (Claude) to help investigate this and write the
report, and reviewed it before sending.
