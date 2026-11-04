# Triple Counter

Three counters, one per Brazier state layer, built with
`brazier.full_application`.

## Features

- Shared counter: every session sees the same value. Clicks append +1/-1
  to a `brazier/store` list, so concurrent clicks are never lost; the store
  broadcasts on its topic and every session re-reads it
  (`brazier.subscriptions` and `brazier.on_notify`)
- Server counter: per tab, held by the tab's server process
- Local counter: per tab, in the browser's Local layer, with no server
  traffic
- The shared counter writes the store in an effect, which is why this is a
  `full_application` and not a `simple` app

## Run

```bash
cd examples/triple_counter
gleam run -m brazier/build   # first, and after every change
gleam run
```

Open http://localhost:8080 in several tabs: the shared counter changes
everywhere, the server and local counters only in their own tab.
