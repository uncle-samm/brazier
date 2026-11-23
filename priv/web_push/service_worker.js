// brazier/web_push's service worker: shows each push message and opens
// its page when it is pressed. It has no fetch handler, so it never sees
// the app's requests.
//
// A message is the JSON `brazier/web_push.payload` writes:
//   {"title":T,"body":B,"url":"/path","tag":G,"icon":"/path"}
// with url, tag and icon left out when not set. Every push shows a
// notification: browsers take the subscription back from a worker that
// receives pushes and shows nothing, and so a message that can't be read
// is shown as one that says so.

function samePath(path) {
  if (typeof path !== "string" || !path.startsWith("/") || path.startsWith("//") || path.startsWith("/\\")) return null;
  return new URL(path, self.location.origin).href;
}

function read(event) {
  if (!event.data) return { title: "New notification", body: "" };
  try {
    const message = event.data.json();
    if (typeof message.title !== "string" || message.title === "") throw new Error("no title");
    return message;
  } catch (error) {
    console.error("[web-push] a push message that is not brazier/web_push's JSON:", error);
    return { title: "New notification", body: "A notification arrived that this app could not read." };
  }
}

self.addEventListener("install", () => {
  // A new worker takes over at once: it holds no caches to hand over.
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("push", (event) => {
  const message = read(event);
  const options = {
    body: typeof message.body === "string" ? message.body : "",
    data: { url: samePath(message.url) },
  };
  if (typeof message.tag === "string" && message.tag !== "") {
    options.tag = message.tag;
    // A message that replaces one shown before alerts again.
    options.renotify = true;
  }
  const icon = samePath(message.icon);
  if (icon) options.icon = icon;
  event.waitUntil(self.registration.showNotification(message.title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || new URL("/", self.location.origin).href;
  event.waitUntil(
    // Only windows this worker controls can be sent to another page, and
    // since it claims every window of the origin when it activates, those
    // are all the app's windows.
    self.clients.matchAll({ type: "window" }).then((windows) => {
      const open = windows.find((client) => new URL(client.url).origin === self.location.origin);
      if (!open) return self.clients.openWindow(url);
      return open.focus().then((focused) => focused.navigate(url));
    }),
  );
});
