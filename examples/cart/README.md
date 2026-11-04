# Shopping Cart

A product catalog with a per-tab cart and stock shared by every shopper,
built with `brazier.full_application`.

## Features

- Derived values in the view: subtotal, tax and total are not stored
- Add, remove, increment and decrement cart items
- Stock shared by every session, kept in a `brazier/store` list as an
  append-only log of takes and returns. Every session replays the same log
  in the same order, so when two shoppers race for the last unit exactly
  one of them gets it
- Server-only state: the session's random cart id is part of the server
  state and `sync` leaves it out, so it never reaches the browser
- The store broadcasts on its topic; every session re-reads the log
  (`brazier.subscriptions` and `brazier.on_notify`)

A closed tab's cart keeps its units off the shelf until the server
restarts; a real shop would expire reservations.

## Run

```bash
cd examples/cart
gleam run -m brazier/build   # first, and after every change
gleam run
```

Open http://localhost:8080 in two tabs and add products in each: the stock
changes in both, the cart only in its own tab.
