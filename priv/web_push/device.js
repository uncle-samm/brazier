// brazier/web_push's device script: runs the subscribe and unsubscribe
// buttons that `brazier/web_push/device` puts in the page.
//
// The element with `device.control(...)` has the hook BrazierWebPush and
// the server's public key in data-web-push-key. Inside it, a press on an
// element with data-web-push="subscribe" asks for permission and
// subscribes this browser to the key; data-web-push="unsubscribe" takes the
// subscription back. After each, and once when the element appears, the
// hook dispatches a "brazier-web-push" event on the element whose detail is
// a JSON report (`brazier/web_push.parse_report` reads it):
//
//   {"state":"subscribed","endpoint":E,"p256dh":K,"auth":A,"agent":UA}
//   {"state":"not-subscribed","permission":"default|granted|denied","removed":E}
//   {"state":"unsupported","reason":"needs-home-screen|not-secure|no-service-worker|no-push-manager|no-notifications"}
//   {"state":"failed","reason":TEXT}
//
// "agent" is the browser's user agent string, cut to 200 characters, for
// telling one subscribed device from another. "removed" is there only when this browser just unsubscribed from E. A
// subscription made with another key (the server's key changed) is taken
// back when the element appears and reported as removed.
//
// The service worker is the server's, at /brazier-web-push-sw.js with the
// whole origin as its scope; it handles push and notificationclick only.
//
// The script is deferred and registers the hook once Brazier's client has
// booted (see examples/timeline/static/timeline_hooks.js).
(() => {
  const HOOK = "BrazierWebPush";
  const EVENT = "brazier-web-push";
  const WORKER = "/brazier-web-push-sw.js";
  const MAX_REASON = 300;

  function fail(message) {
    throw new Error("[web-push] " + message);
  }

  function isAppleMobile() {
    return /iPad|iPhone|iPod/.test(navigator.userAgent) ||
      (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  }

  function standalone() {
    return window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
  }

  // Why this browser can't subscribe here, or null.
  function unsupported() {
    if (!window.isSecureContext) return "not-secure";
    const homeScreen = isAppleMobile() && !standalone();
    if (!("serviceWorker" in navigator)) return homeScreen ? "needs-home-screen" : "no-service-worker";
    if (!("PushManager" in window)) return homeScreen ? "needs-home-screen" : "no-push-manager";
    if (!("Notification" in window)) return homeScreen ? "needs-home-screen" : "no-notifications";
    return null;
  }

  function keyOf(el) {
    const text = el.getAttribute("data-web-push-key");
    if (!text || !/^[A-Za-z0-9_-]+={0,2}$/.test(text)) {
      fail("the element needs data-web-push-key, the server's public key in base64url; got " + JSON.stringify(text));
    }
    const base64 = text.replace(/=+$/, "").replace(/-/g, "+").replace(/_/g, "/");
    const binary = atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    if (bytes.length !== 65 || bytes[0] !== 4) fail("data-web-push-key is not an uncompressed P-256 key (65 bytes starting with 4)");
    return bytes;
  }

  function sameKey(subscription, key) {
    const held = subscription.options && subscription.options.applicationServerKey;
    // A browser that doesn't say which key it subscribed with is taken at
    // its word; the push service refuses a request signed with another.
    if (!held) return true;
    const bytes = new Uint8Array(held);
    return bytes.length === key.length && bytes.every((b, i) => b === key[i]);
  }

  function subscribed(subscription) {
    const json = subscription.toJSON();
    if (!json.keys || !json.keys.p256dh || !json.keys.auth) fail("the browser's subscription has no p256dh and auth keys");
    return {
      state: "subscribed",
      endpoint: json.endpoint,
      p256dh: json.keys.p256dh,
      auth: json.keys.auth,
      agent: navigator.userAgent.slice(0, 200),
    };
  }

  function notSubscribed(removed) {
    const report = { state: "not-subscribed", permission: Notification.permission };
    if (removed) report.removed = removed;
    return report;
  }

  function registration() {
    // register() with the same script and scope is the registration the
    // browser already has; ready waits for its worker to be active.
    return navigator.serviceWorker.register(WORKER, { scope: "/" }).then(() => navigator.serviceWorker.ready);
  }

  async function current(el) {
    const why = unsupported();
    if (why) return { state: "unsupported", reason: why };
    const reg = await registration();
    const subscription = await reg.pushManager.getSubscription();
    if (subscription && !sameKey(subscription, keyOf(el))) {
      const endpoint = subscription.endpoint;
      await subscription.unsubscribe();
      console.log("[web-push] took back a subscription made with another key");
      return notSubscribed(endpoint);
    }
    if (subscription && Notification.permission === "granted") return subscribed(subscription);
    return notSubscribed(null);
  }

  async function subscribe(el) {
    const why = unsupported();
    if (why) return { state: "unsupported", reason: why };
    // Asked first, inside the press: Safari shows the prompt only then.
    const permission = await Notification.requestPermission();
    if (permission !== "granted") return notSubscribed(null);
    const reg = await registration();
    const key = keyOf(el);
    const old = await reg.pushManager.getSubscription();
    let removed = null;
    if (old && !sameKey(old, key)) {
      removed = old.endpoint;
      await old.unsubscribe();
    }
    const subscription = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
    const report = subscribed(subscription);
    if (removed && removed !== report.endpoint) console.log("[web-push] replaced a subscription made with another key");
    return report;
  }

  async function unsubscribe() {
    const why = unsupported();
    if (why) return { state: "unsupported", reason: why };
    const reg = await registration();
    const subscription = await reg.pushManager.getSubscription();
    if (!subscription) return notSubscribed(null);
    const endpoint = subscription.endpoint;
    const done = await subscription.unsubscribe();
    if (!done) fail("the browser did not take the subscription back");
    return notSubscribed(endpoint);
  }

  function report(el, value) {
    el.dispatchEvent(new CustomEvent(EVENT, { detail: JSON.stringify(value), bubbles: false }));
  }

  // Runs `work` and reports what it found, or why it failed. Each report is
  // dispatched in a task of its own, never inside Brazier's render.
  function run(el, state, what, work) {
    if (state.busy) {
      console.warn("[web-push] " + what + " ignored: the last press is still being carried out");
      return;
    }
    state.busy = true;
    el.setAttribute("aria-busy", "true");
    Promise.resolve()
      .then(work)
      .then(
        (value) => value,
        (error) => {
          console.error("[web-push] " + what + " failed:", error);
          const text = error && error.message ? error.message : String(error);
          return { state: "failed", reason: text.slice(0, MAX_REASON) };
        },
      )
      .then((value) => {
        state.busy = false;
        el.removeAttribute("aria-busy");
        if (!state.mounted) return;
        console.log("[web-push] " + what + ": " + value.state);
        window.setTimeout(() => report(el, value), 0);
      });
  }

  function register() {
    const client = window.brazierClient;
    if (!client || typeof client.registerHook !== "function") {
      fail("window.brazierClient.registerHook is missing: the Brazier client did not boot before this script");
    }
    client.registerHook(HOOK, {
      mount(el) {
        keyOf(el);
        const state = { mounted: true, busy: false, key: el.getAttribute("data-web-push-key") };
        state.onClick = (event) => {
          const button = event.target instanceof Element ? event.target.closest("[data-web-push]") : null;
          if (!button || !el.contains(button)) return;
          const action = button.getAttribute("data-web-push");
          event.preventDefault();
          if (action === "subscribe") run(el, state, "subscribe", () => subscribe(el));
          else if (action === "unsubscribe") run(el, state, "unsubscribe", unsubscribe);
          else if (action === "check") run(el, state, "check", () => current(el));
          else fail("data-web-push is subscribe, unsubscribe or check; got " + JSON.stringify(action));
        };
        el.addEventListener("click", state.onClick);
        run(el, state, "check", () => current(el));
        return state;
      },
      update(el, state) {
        const key = el.getAttribute("data-web-push-key");
        if (key === state.key) return;
        state.key = key;
        run(el, state, "check", () => current(el));
      },
      unmount(el, state) {
        state.mounted = false;
        el.removeEventListener("click", state.onClick);
      },
    });
    console.log("[web-push] Registered the " + HOOK + " hook");
  }

  if (document.readyState === "complete") {
    fail("brazier-web-push.js must load with defer, before DOMContentLoaded");
  }
  document.addEventListener("DOMContentLoaded", register, { once: true });
})();
