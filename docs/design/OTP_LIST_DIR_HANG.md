# OTP list_dir hang on macOS: upstream report draft

This file has two parts:

- a draft bug report for erlang/otp, written to be pasted as is;
- the decision Brazier took while the bug stays open upstream.

**Status:** drafted, not posted. Posting it needs the maintainer's
permission. The open issue is tracked in [docs/TODO.md](../TODO.md#open-issues).

---

## Draft report

### Title

`prim_file:internal_native2name/1` returns freed heap cells on macOS for a
file name that starts with a combining mark, so `file:list_dir/1` never
returns.

### Versions

| | Affected | Not affected |
|---|---|---|
| OTP | 28.4 (erts 16.3) | 28.5.0.8 (`erlang:28` Docker image) |
| OS | macOS, Darwin 25.6.0, APFS | Debian 13, aarch64, Linux 7.0.14-linuxkit |
| Name encoding | `utf8` (the default, and `+fnu`) | `utf8`, locale `C.UTF-8` |

On macOS, `+fnl` avoids the bug, because it stops the VM from decoding the
name. The code at fault is the same on `master` today, at the same line
numbers. It dates from the macOS file name normalization added in R14B01
(commit 9622ab2132, 2010), so every release since then is likely affected.

### Minimal repro

Create a directory that holds one file. The file's name is U+0301
(COMBINING ACUTE ACCENT) followed by `b`, which is the bytes `cc 81 62`:

```sh
mkdir d && printf x > "d/$(printf '\314\201b')"
```

Then list the directory. Run this under a kill timeout, because the VM does
not stop by itself:

```sh
timeout -s KILL 10 erl -noshell -eval 'io:format("~w~n", [file:list_dir("d")]), halt().'
```

The same corruption, seen without a hang:

```erlang
L = prim_file:internal_native2name(<<204, 129, $b>>),
Y = [a | L],
{erts_debug:same(Y, L), hd(L), erts_debug:same(tl(L), L)}.
%% macOS: {true, a, true}   the next cons cell was built on top of L
%% Linux: {false, 769, false}
```

### Observed

On macOS, all of the following spin at 100% CPU and never return:

- `file:list_dir/1` and `file:list_dir_all/1`, with the directory given as
  a string or as a binary;
- `prim_file:list_dir/1` and `prim_file:list_dir_all/1`;
- `file:del_dir_r/1`, which lists the directory first;
- anything built on these, such as `filelib:wildcard/1`.

Once the hang starts, the VM no longer runs timers, and `erlang:halt/1`
called from another process does not stop it. Only SIGKILL does. The node
ignores SIGTERM.

Other results on macOS:

- `prim_file:internal_native2name(<<204, 129, $b>>)` returns `[0]`, where
  `[769, 98]` is expected. The cells it returns have already been reused.
- `prim_file:list_dir/1` on the directory returns `{ok, [Name]}`, where
  `hd(Name)` is `Name` itself, so `Name = [Name]`. The process that prints
  or copies the name loops forever.
- A name with a mark in the middle decodes correctly:
  `internal_native2name(<<$a, 204, 129, $b>>)` returns `[225, 98]` (NFC
  `áb`).
- With `+fnl`, `file:list_dir/1` returns `{ok, [[204, 129, 98]]}`.

### Expected

`{ok, [[769, 98]]}`. On macOS, the name may also come back NFC-normalized,
but U+0301 has nothing before it to compose with, so it stays as is. Linux
returns `{ok, [[769, 98]]}`, and there `file:del_dir_r/1` returns `ok`.

### Root cause

On macOS, `erts/emulator/sys/common/erl_sys_common_misc.c:122` sets the
file name encoding to `ERL_FILENAME_UTF8_MAC`.

The listing goes through these steps:

1. `file_server` handles `{list_dir, Name}` by calling
   `prim_file:list_dir/1` and replying with the result
   (`lib/kernel/src/file_server.erl:128-131`).
2. `prim_file:list_dir_convert/3` (`erts/preloaded/src/prim_file.erl:595-621`)
   decodes each raw name through `prim_file:internal_native2name/1`
   (declared at `prim_file.erl:92`).
3. `prim_file_internal_native2name_1`
   (`erts/emulator/beam/erl_unicode.c:2735`) calls
   `do_utf8_to_list_normalize` (line 2793) for `ERL_FILENAME_UTF8_MAC`.

`do_utf8_to_list_normalize` (`erl_unicode.c:1569`) works like this:

- At line 1584 it takes room for `2 * num` words with `HAlloc`.
- It then walks the name backwards, consing code points onto `ret`.
- A code point that may compose with the one before it (`is_candidate`,
  line 1418, for any code point from 768 up) is saved in `savepoints`
  rather than consed.
- If points are still saved when the walk reaches the start of the name,
  it calls `cleanup_norm(&hp, savepoints, numpoints, &ret)` (line 1624).
  This happens when the name starts with a candidate.
- Finally it calls `HRelease(p, hp_end, hp)` (line 1627) to give back the
  words it did not use.

`cleanup_norm` (lines 1475-1498) copies the heap pointer at line 1477
(`Eterm *hp = *hpp;`). It then builds one cons cell for each saved point,
advancing its local `hp`. But at line 1497 it writes back only `*retp = ret`,
never `*hpp = hp`.

So the caller's `hp` still points below the cells `cleanup_norm` just
built, and `HRelease` hands those cells back to the heap. The list returned
to Erlang starts in freed memory. The next allocation (for example the
`[Converted | Result]` cons in `list_dir_convert`) is built in the same words.
That is how the name becomes `[Name]`.

`handle_potential_norm` (lines 1500-1566) has the same structure and does
write `*hpp = hp` (line 1564). Only the cleanup path is missing it.

Linux is not affected, because it uses `ERL_FILENAME_UTF8`, which does not
normalize.

### Suggested fix

Write the heap pointer back in `cleanup_norm`:

```c
static void cleanup_norm(Eterm **hpp, Uint16 *savepoints, int numpoints, Eterm *retp)
{
    ...
    *hpp = hp;
    *retp = ret;
}
```

A regression test is the `erts_debug:same/2` check from the repro, run on a
name whose first code point is a combining mark.

---

## What Brazier does

Brazier lists directories in these places:

- the client bundle build: `publish`, `runtime_files` and `write_project` in
  `brazier/build/client_bundle`;
- `brazier/build` and `brazier/build/discovery`, through
  `brazier/build/files`;
- the three walkers in `brazier/lint`;
- the dev reload of an `ebin` directory, in `brazier_dev_ffi:reload_modules/1`.

On macOS, a single file named this way in an app's static directory would
have hung the build. With OTP's listing, there is no way to guard against
it. No timeout helps, because the VM stops running timers once the hang
starts.

So every one of those sites now lists through `brazier_dir_ffi`
([src/brazier_dir_ffi.erl](../../src/brazier_dir_ffi.erl)), which:

- **Lists with find(1)**, started with `open_port({spawn_executable, Find})`
  and no shell. The arguments are
  `-H Dir -mindepth 1 -maxdepth 1 -print0`.
- **Reads the names as raw bytes.** The VM never decodes them, so the bug
  cannot be reached.
- **Returns names exactly as written on disk.** A name is not NFC-composed
  (OTP gives `café.txt` for `cafe` + U+0301 + `.txt`).
- **Fails loudly on a name that is not valid UTF-8.** Gleam's `String`
  cannot hold such a name, so Brazier returns an error naming the directory
  and the name's bytes, rather than skipping the name.
- **Checks find's output strictly.** Each entry must:
  - start with the directory it was asked for;
  - be followed by a NUL;
  - hold a name with no `/`.

  Anything else is an error that quotes the output.
- **Deletes trees with `delete_tree/1`.** It walks with the same listing,
  does not follow symlinks, and removes entries with raw `file:delete/2` and
  `file:del_dir/1`, which do not list.

The listing works with:

- the find on macOS;
- GNU findutils 4.10.0 (Debian, the `erlang:28` image);
- BusyBox find (`erlang:28-alpine`).

A missing `find` is an error that says why it is needed.

### Tests

[test/brazier/dir_listing_test.gleam](../../test/brazier/dir_listing_test.gleam)
covers this. Any test that touches a name starting with a combining mark
runs the call in a child VM ([test/brazier/child_vm.gleam](../../test/brazier/child_vm.gleam)).
The child is killed with SIGKILL when it does not answer in time, so a
regression fails that test instead of hanging the suite.

Two of those tests are tripwires for OTP itself:

- the `erts_debug:same/2` probe must be true exactly on macOS;
- `file:list_dir/1` must time out on macOS and return elsewhere.

When an OTP release fixes `cleanup_norm`, these tests fail. That failure is
the signal to revisit the find-based listing for that release.
