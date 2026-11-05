# Rows

A 1000-row list, each row with a click handler: the browser bench of the
client's DOM morph.

## Features

- `brazier.application`: the update runs on the server, so every click
  comes back as one patch and one render of the page
- "Relabel" changes every tenth label and moves the selection, the change
  the node client bench (`test/brazier/bench/client_bench.gleam`) patches
- A click on a row selects it

## Run

```bash
cd examples/rows
export SECRET_KEY="$(openssl rand -base64 48)"   # once per shell
gleam run -m brazier/build   # first, and after every change
gleam run
```

Open http://localhost:8080 and click Relabel.

## Browser bench

`test_all_cdp.py rows` checks the page, then times the client's work for
each Relabel in Chrome. It observes the client's `brazier:morph` (the
morph, the event listeners and the stream containers of a render) and
`brazier:patch` (`handlePatch`, from the patch to the rendered page, without
the frame's `JSON.parse`) User Timing measures. It prints
`browser.morph.rows_1000` and `browser.patch.rows_1000` as µs median and
p99, and writes them to `build/bench/cdp_morph_<viewport>.json`
(`cdp_morph_desktop.json`, `cdp_morph_mobile.json`) in the bench report
format. They are not gated: there is no baseline for them yet.
