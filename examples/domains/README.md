# Multi-File Domains

A `beacon.simple` app whose Model is built from types in other modules.

## Features

- The types live in `domains/auth.gleam` (User, Role) and
  `domains/items.gleam` (Item). The Model refers to them as `auth.User`
  and `List(items.Item)`.
- The build follows those modules. It generates the codec for their types
  and compiles the functions that `update` and `view` call from them, such
  as `auth.parse_role` and `auth.role_label`, to JavaScript.
- Changing the role, adding an item and toggling one update the page at
  once in the browser. The server runs the same update and stays
  authoritative.
- The server rejects what the view cannot produce, and logs a warning for
  each: an unknown role, a toggle of an unknown item, or an item over 200
  characters. A blank item is ignored.

## Run

```bash
cd examples/domains
gleam run -m beacon/build   # first, and after every change
gleam run -m app
```

Open http://localhost:8080. Change the role, add items, and toggle them.
