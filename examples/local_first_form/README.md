# Local First Form

Focused example for Brazier's Model + Local split, built with
`brazier.full_application` and `local.layer`.

It exercises:

- Draft input, filter selection and the options menu in `Local`:
  `update_local` returns `local.handled`, so they render in the browser
  with no server traffic
- Submit forwards the form's fields (`event.on_submit`) with
  `local.forward`; the server validates them and saves them in the `Model`
- Server-side validation: a missing field, an over-long query or an
  unknown filter is rejected with a logged warning

```sh
cd examples/local_first_form
gleam run -m brazier/build   # first, and after every change
gleam run -m local_first_form
```

Open http://localhost:8080.
