# Chat

A multi-room chat with presence and typing indicators, built with
`brazier.full_application` and a `local.layer`.

## Features

- Three rooms: general, random and help. Each session subscribes only to
  its current room. `brazier.subscriptions` is recomputed after every
  update, so switching rooms moves the subscriptions too.
- Messages are appended to a `brazier/store` list keyed by room with
  `store.append_notify`, which also broadcasts on the room's topic. A
  session re-reads the room when that topic fires and shows the latest
  100 messages.
- Who is in each room comes from `brazier/presence`. A session tracks
  itself when it joins or switches rooms. The tracker monitors the session
  process, so a closed tab leaves the room on its own.
- Typing is part of the presence meta. A keydown handler throttled to one
  `Typing` a second sets the flag, and it clears after 3 seconds without
  one, or when the message is sent. Each user sees the others typing, not
  themselves.
- The name and message drafts are Local state, so typing sends nothing
  except the throttled typing signal. A blank name or message is refused
  in the browser.
- The server checks everything the browser sends: names of 1 to 32
  characters, messages of 1 to 500 characters, and only the three rooms. A
  rejected message is logged as a warning.
- The session keeps its presence key and typing flag on the server. Only
  the Model is synced to the browser.
- A failed presence call is logged and shown in the sidebar.

## Run

```bash
cd examples/chat
export SECRET_KEY="$(openssl rand -base64 48)"   # once per shell
gleam run -m brazier/build   # first, and after every change
gleam run
```

Open http://localhost:8080 in two tabs, join with a different name in
each, and chat between them.
