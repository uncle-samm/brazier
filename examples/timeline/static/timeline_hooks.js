// The ChunkMeter hook: draws a step's progress meter from its data-chunks
// attribute. The step's span has `attribute.ignore_updates()`, so the
// page's morph leaves the meter's text to this hook, and
// `attribute.watch(["data-chunks"])`, so `update` runs only when the chunk
// count changes.
//
// The script is deferred: it runs after the Brazier bundle (at the end of
// the body) has added its own DOMContentLoaded listener, so the listener
// below runs after Brazier's boot has installed registerHook.
//
// window.timelineHooks counts the hook's calls and lists them with the
// step's key, for the browser test (test_all_cdp.py).
(() => {
  const record = { counts: { mount: 0, update: 0, unmount: 0 }, events: [] };
  window.timelineHooks = record;

  function stepKey(el) {
    const item = el.closest("[data-brazier-key]");
    if (!item) throw new Error("[timeline] ChunkMeter is not inside a stream item");
    return item.getAttribute("data-brazier-key");
  }

  function note(kind, el) {
    record.counts[kind] += 1;
    record.events.push([kind, stepKey(el)]);
  }

  function draw(el) {
    const raw = el.getAttribute("data-chunks");
    const chunks = Number(raw);
    if (!Number.isInteger(chunks) || chunks < 0) {
      throw new Error("[timeline] ChunkMeter needs a non-negative integer data-chunks, got " + JSON.stringify(raw));
    }
    el.textContent = chunks === 0 ? "" : "#".repeat(chunks);
  }

  function register() {
    const client = window.brazierClient;
    if (!client || typeof client.registerHook !== "function") {
      throw new Error("[timeline] window.brazierClient.registerHook is missing: the Brazier client did not boot before this script");
    }
    client.registerHook("ChunkMeter", {
      mount(el) {
        note("mount", el);
        draw(el);
        return null;
      },
      update(el) {
        note("update", el);
        draw(el);
      },
      unmount(el) {
        note("unmount", el);
      },
    });
    console.log("[timeline] Registered the ChunkMeter hook");
  }

  // A deferred script runs once the document is parsed ("interactive") and
  // before DOMContentLoaded; "complete" means it was loaded some other way,
  // after the event this script waits for.
  if (document.readyState === "complete") {
    throw new Error("[timeline] timeline_hooks.js must load with defer, before DOMContentLoaded");
  }
  document.addEventListener("DOMContentLoaded", register, { once: true });
})();
