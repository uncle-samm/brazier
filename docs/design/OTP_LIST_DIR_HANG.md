# OTP list_dir hang on macOS

On macOS, OTP's file name decoder returns freed heap cells for a name that
starts with a combining mark, so `file:list_dir/1` on a directory holding
one never returns. The bug, its repro, cause and a tested one-line fix are
in [OTP_SECURITY_REPORT.md](OTP_SECURITY_REPORT.md), the text to send to
OTP. This file is what Brazier does while the bug stays open upstream.

**Status:** the report is not sent. It is a heap use-after-free reachable
from a file name, so it goes to the private channel in OTP's `SECURITY.md`,
not a public issue. OTP accepts reports only from humans (AI may help write
one, but the reporter must review it and send it), so Sam reviews and sends
it. The open issue is tracked in [docs/TODO.md](../TODO.md#open-issues).

Checked on 2026-11-05 before drafting: no issue, pull request or advisory
in erlang/otp mentions `cleanup_norm` or this hang; the last change to
`erl_unicode.c` (2e89d8fda, August 2025, GH-10072) does not touch it; and
`master`, `maint`, `maint-28` and `maint-29` have the same code. Every
command in the report was run as written, under zsh and sh, on OTP 29.1.2.

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
