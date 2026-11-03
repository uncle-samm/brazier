# Private Session

A `beacon.full_application` whose session holds private state next to a
public Model.

- The session keeps a signing key, an audit trail of the newest 100
  entries, a count of audited events, and a count of denied transfers.
- `sync` hands only the Model to the browser. The build compiles only what
  `view` reaches, so none of the private state is in the HTML, the model
  sync or the client bundle.
- Approving a transfer moves 25 out of the visible balance. When the
  balance is too low, the server refuses it, logs a warning and says so on
  the page.
- "Refresh public summary" copies one private value, the number of audited
  events, into the Model on purpose.

The browser integration tests use this example to check that the signing
key and audit entries never reach the page or the bundle.

```sh
gleam run -m beacon/build   # after changing the source
gleam run -m private_session
```
