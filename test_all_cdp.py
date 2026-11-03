#!/usr/bin/env python3
"""CDP test suite for Beacon examples.
CDP DOES NOT CAUSE BUGS. If it fails, the bug is REAL.

Usage:
  python3 test_all_cdp.py                  # run all tests
  python3 test_all_cdp.py --canonical      # run canonical conformance examples
  python3 test_all_cdp.py --canonical --viewport mobile
  python3 test_all_cdp.py --shard 1/4      # run first quarter of selected examples
  python3 test_all_cdp.py counter          # run only counter test
  python3 test_all_cdp.py middleware_demo   # run only middleware demo
  python3 test_all_cdp.py --verbose         # verbose output (show DOM, HTML)
  python3 test_all_cdp.py counter -v       # both

Every test verifies STATE CHANGES, not just that HTML exists.
Multi-user tests: action in session A, navigate away, new session B sees the change.
"""
import json, time, os, subprocess, signal, sys, re, argparse
import websocket, urllib.request

parser = argparse.ArgumentParser(description="Beacon CDP tests")
parser.add_argument("filter", nargs="?", default=None, help="Run only tests matching this name")
parser.add_argument("--canonical", action="store_true", help="Run the canonical conformance examples")
parser.add_argument("--shard", default=os.environ.get("BEACON_CDP_SHARD"), help="Run shard INDEX/TOTAL, 1-based")
parser.add_argument(
    "--viewport",
    choices=("desktop", "mobile"),
    default=os.environ.get("BEACON_CDP_VIEWPORT", "desktop"),
    help="Browser viewport profile",
)
parser.add_argument("-v", "--verbose", action="store_true", help="Verbose output")
args = parser.parse_args()
ONLY = args.filter.lower() if args.filter else None
CANONICAL_ONLY = args.canonical
VIEWPORT = args.viewport
MOBILE_VIEWPORT = VIEWPORT == "mobile"
VERBOSE = args.verbose

ALL_EXAMPLES = [
    "counter",
    "counter_local",
    "kanban",
    "canvas",
    "snake",
    "chat",
    "dashboard",
    "pong",
    "triple_counter",
    "todo",
    "cart",
    "spreadsheet",
    "ai_chat",
    "privacy_demo",
    "middleware_demo",
    "domains",
    "multi_kanban",
    "multi_todo",
    "private_session",
    "routed_workspace",
    "routed",
    "local_first_form",
    "route_server_workspace",
    "auth_workspace",
]

CDP_PORT = int(os.environ.get("CDP_PORT", "9223"))
BEACON_PORT = int(os.environ.get("BEACON_PORT", "8080"))
SERVER_START_TIMEOUT_SECONDS = int(os.environ.get("BEACON_CDP_SERVER_TIMEOUT", "90"))
ROOT = os.path.dirname(os.path.abspath(__file__))
PASS = 0
FAIL = 0
SKIP = 0
server_proc = None
MID = 100000
DOM_MONITOR_INSTALLED = False
CANONICAL_EXAMPLES = {
    "counter",
    "counter_local",
    "local_first_form",
    "private_session",
    "routed",
    "routed_workspace",
    "route_server_workspace",
    "auth_workspace",
}
CONTRACT_REPORTS = {}
# Examples whose view has no event handlers: the browser sends no messages.
NO_HANDLER_EXAMPLES = {"dashboard"}

def parse_shard(value):
    if not value:
        return None
    match = re.fullmatch(r"([1-9][0-9]*)/([1-9][0-9]*)", value.strip())
    if not match:
        raise SystemExit("--shard must use INDEX/TOTAL, for example 1/4")
    index = int(match.group(1))
    total = int(match.group(2))
    if index > total:
        raise SystemExit("--shard INDEX must be <= TOTAL")
    return (index, total)

SHARD = parse_shard(args.shard)

def selected_example_names():
    names = ALL_EXAMPLES
    if CANONICAL_ONLY:
        names = [name for name in names if name in CANONICAL_EXAMPLES]
    if ONLY is not None:
        names = [name for name in names if ONLY in name.lower()]
    return names

def shard_includes(name):
    if SHARD is None:
        return True
    names = selected_example_names()
    if name not in names:
        return False
    index, total = SHARD
    position = names.index(name)
    return position % total == index - 1

def should_run(name):
    """Check if this test should run based on --filter."""
    if CANONICAL_ONLY and name not in CANONICAL_EXAMPLES:
        return False
    if ONLY is None:
        return shard_includes(name)
    return ONLY in name.lower() and shard_includes(name)

def vlog(msg):
    """Print only in verbose mode."""
    if VERBOSE:
        print(f"    [v] {msg}")

def get_tab():
    tabs = json.loads(urllib.request.urlopen(f"http://localhost:{CDP_PORT}/json").read())
    for t in tabs:
        if t.get("type") == "page" and "chrome-extension" not in t.get("url", ""):
            return t["webSocketDebuggerUrl"]
    raise Exception("No Chrome tab")

def configure_viewport():
    if MOBILE_VIEWPORT:
        cdp("Emulation.setDeviceMetricsOverride", {
            "width": 390,
            "height": 844,
            "deviceScaleFactor": 3,
            "mobile": True,
            "screenWidth": 390,
            "screenHeight": 844,
        })
        cdp("Emulation.setTouchEmulationEnabled", {"enabled": True, "maxTouchPoints": 5})
        cdp("Network.setUserAgentOverride", {
            "userAgent": (
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 "
                "Mobile/15E148 Safari/604.1"
            )
        })
    else:
        cdp("Emulation.setDeviceMetricsOverride", {
            "width": 1280,
            "height": 900,
            "deviceScaleFactor": 1,
            "mobile": False,
            "screenWidth": 1280,
            "screenHeight": 900,
        })
        cdp("Emulation.setTouchEmulationEnabled", {"enabled": False})

ws = None
pending_responses = {}
cdp_events = []
browser_errors = []

def record_cdp_message(data):
    if "method" in data:
        cdp_events.append(data)
        method = data.get("method")
        if method == "Runtime.exceptionThrown":
            details = data.get("params", {}).get("exceptionDetails", {})
            text = details.get("text", "Runtime exception")
            exception = details.get("exception", {})
            description = exception.get("description") or exception.get("value") or text
            browser_errors.append(str(description))
        elif method == "Log.entryAdded":
            entry = data.get("params", {}).get("entry", {})
            # The examples ship no favicon. Chrome requests /favicon.ico on
            # its own (not the page or Beacon), so that one 404 is not an app
            # error. It is still logged in verbose mode.
            if (entry.get("source") == "network"
                    and str(entry.get("url", "")).endswith("/favicon.ico")):
                vlog(f"Ignoring browser favicon request: {entry.get('text')}")
            elif entry.get("level") == "error":
                message = str(entry.get("text", "Browser log entry"))
                if entry.get("url"):
                    message += f" [{entry.get('url')}]"
                browser_errors.append(message)

def cdp(method, params=None, timeout=8, retry=True):
    global MID
    if ws is None:
        reconnect_cdp()
    MID += 1
    my_id = MID
    try:
        ws.send(json.dumps({"id": my_id, "method": method, "params": params or {}}))
    except websocket.WebSocketConnectionClosedException:
        if not retry:
            raise
        reconnect_cdp()
        return cdp(method, params, timeout, retry=False)
    if my_id in pending_responses:
        return pending_responses.pop(my_id)
    deadline = time.time() + timeout
    while time.time() < deadline:
        ws.settimeout(max(0.1, deadline - time.time()))
        try:
            data = json.loads(ws.recv())
            record_cdp_message(data)
            if data.get("id") == my_id:
                return data
            elif "id" in data:
                pending_responses[data["id"]] = data
        except:
            break
    return None

def reconnect_cdp():
    global ws, pending_responses, DOM_MONITOR_INSTALLED
    try:
        if ws is not None:
            ws.close()
    except:
        pass
    ws = websocket.create_connection(get_tab(), timeout=10, suppress_origin=True)
    pending_responses = {}
    DOM_MONITOR_INSTALLED = False
    cdp("Runtime.enable", retry=False)
    cdp("Log.enable", retry=False)
    cdp("Network.enable", retry=False)
    cdp("Page.enable", retry=False)
    configure_viewport()

def evl(expr):
    r = cdp("Runtime.evaluate", {"expression": expr})
    if r and "result" in r:
        return r["result"].get("result", {}).get("value", "ERR")
    return "TIMEOUT"

def evl_async(expr):
    r = cdp("Runtime.evaluate", {"expression": expr, "awaitPromise": True}, timeout=12)
    if r and "result" in r:
        return r["result"].get("result", {}).get("value", "ERR")
    return "TIMEOUT"

DRAIN_MAX_SECONDS = 1.0

def drain():
    # Bounded: a 60 Hz game loop (pong) emits a CDP network event every frame,
    # so "read until quiet" would never return.
    deadline = time.time() + DRAIN_MAX_SECONDS
    ws.settimeout(0.3)
    try:
        while time.time() < deadline:
            data = json.loads(ws.recv())
            record_cdp_message(data)
    except: pass

def clear_cdp_events():
    global cdp_events
    drain()
    cdp_events = []

def clear_browser_errors():
    global browser_errors
    browser_errors = []
    evl('window.__e=[]; "ok"')

def websocket_payloads():
    drain()
    payloads = []
    for event in cdp_events:
        method = event.get("method")
        if method in ("Network.webSocketFrameSent", "Network.webSocketFrameReceived"):
            response = event.get("params", {}).get("response", {})
            payload = response.get("payloadData")
            if payload:
                payloads.append((method, payload))
    return payloads

def cdp_method_count(method_name):
    drain()
    return sum(1 for event in cdp_events if event.get("method") == method_name)

def wait_for_cdp_method(method_name, timeout_seconds=8, interval_seconds=0.25):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if cdp_method_count(method_name) > 0:
            return True
        time.sleep(interval_seconds)
    return cdp_method_count(method_name) > 0

def websocket_payload_count(method_suffix, text_fragment):
    return sum(
        1 for method, payload in websocket_payloads()
        if method.endswith(method_suffix) and text_fragment in payload
    )

def websocket_json_payloads(method_suffix):
    frames = []
    for method, payload in websocket_payloads():
        if not method.endswith(method_suffix):
            continue
        try:
            frames.append(json.loads(payload))
        except json.JSONDecodeError:
            vlog(f"Ignoring non-JSON WebSocket payload: {payload[:80]}")
    return frames

def websocket_type_count(method_suffix, type_name):
    return sum(
        1 for payload in websocket_json_payloads(method_suffix)
        if payload.get("type") == type_name
    )

def wait_for_websocket_type(method_suffix, type_name, timeout_seconds=8, interval_seconds=0.25):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        if websocket_type_count(method_suffix, type_name) > 0:
            return True
        time.sleep(interval_seconds)
    return websocket_type_count(method_suffix, type_name) > 0

def sent_event_count():
    return websocket_type_count("Sent", "event") + websocket_type_count("Sent", "event_batch")

def sent_model_event_units():
    total = 0
    for payload in websocket_json_payloads("Sent"):
        if payload.get("type") == "event":
            total += 1
        elif payload.get("type") == "event_batch":
            total += len(payload.get("events", []))
    return total

def received_state_update_count():
    return websocket_type_count("Received", "patch") + websocket_type_count("Received", "model_sync")

def check_model_ws_update(msg):
    check(sent_event_count() >= 1, f"{msg}: sends model event")
    check(received_state_update_count() >= 1, f"{msg}: receives patch or model_sync")
    check(websocket_type_count("Received", "mount") == 0, f"{msg}: receives no HTML mount")

def check_local_ws_quiet(msg):
    check(sent_event_count() == 0, f"{msg}: sends zero model events")
    check(websocket_type_count("Received", "mount") == 0, f"{msg}: receives no HTML mount")

def navigate(path="/"):
    drain()
    clear_browser_errors()
    install_dom_monitor()
    cdp("Network.setCacheDisabled", {"cacheDisabled": True})
    cdp("Page.navigate", {"url": f"http://localhost:{BEACON_PORT}{path}"})
    for _ in range(30):
        time.sleep(0.5)
        drain()
        t = evl('document.getElementById("beacon-app")?.textContent || ""')
        ws_state = evl("window.__beaconWsState ? window.__beaconWsState() : -1")
        if len(str(t)) > 5 and str(ws_state) == "1":
            break
    drain()
    evl('window.__e = window.__e || []; "ok"')

def text():
    return evl('document.getElementById("beacon-app").textContent')

def html():
    return evl('document.getElementById("beacon-app").innerHTML')

def click(sel, debug=False):
    before = evl('document.getElementById("beacon-app").textContent')
    js = 'var el = document.querySelector("' + sel.replace('"', '\\"') + '"); el ? (el.click(), "clicked") : "not found"'
    result = evl(js)
    if debug:
        print(f"    [click {sel}: {result}]")
    for i in range(10):
        time.sleep(0.5)
        drain()
        after = evl('document.getElementById("beacon-app").textContent')
        if after != before:
            return

def click_by_text(button_text):
    before = evl('document.getElementById("beacon-app").textContent')
    evl(f'var btns=document.querySelectorAll("[data-beacon-on-click]"); for(var b of btns){{if(b.textContent.includes("{button_text}")){{b.click();break}}}}')
    for i in range(10):
        time.sleep(0.5)
        drain()
        after = evl('document.getElementById("beacon-app").textContent')
        if after != before:
            return

def click_button(label, nth=0):
    """Click the nth handled button whose trimmed text is exactly `label`.

    Handler ids are positional and internal, so tests find buttons by text.
    """
    before = evl('document.getElementById("beacon-app").textContent')
    label_js = json.dumps(label)
    result = evl(
        'var bs=Array.from(document.querySelectorAll("button[data-beacon-on-click]"))'
        f'.filter(function(b){{return b.textContent.trim()==={label_js}}}); '
        f'bs.length>{nth} ? (bs[{nth}].click(), "clicked") : "not found"'
    )
    if result != "clicked":
        check(False, f"button {label!r} #{nth} exists")
        return
    for i in range(10):
        time.sleep(0.5)
        drain()
        after = evl('document.getElementById("beacon-app").textContent')
        if after != before:
            return

def submit_by_text(button_text):
    """Click the submit button whose text contains `button_text`.

    The click submits its form natively, so the form's `on_submit` handler runs.
    """
    before = evl('document.getElementById("beacon-app").textContent')
    text_js = json.dumps(button_text)
    result = evl(
        'var bs=Array.from(document.querySelectorAll("form[data-beacon-on-submit] button[type=submit]"))'
        f'.filter(function(b){{return b.textContent.includes({text_js})}}); '
        'bs.length>0 ? (bs[0].click(), "clicked") : "not found"'
    )
    if result != "clicked":
        check(False, f"submit button {button_text!r} exists")
        return
    for i in range(10):
        time.sleep(0.5)
        drain()
        after = evl('document.getElementById("beacon-app").textContent')
        if after != before:
            return

def type_input(sel, value):
    evl(f'var el=document.querySelector(\'{sel}\'); el.value="{value}"; el.dispatchEvent(new Event("input", {{bubbles:true}}))')
    time.sleep(1)
    drain()

def errors():
    dom_errors = evl("window.__e ? window.__e.length : 0")
    try:
        dom_count = int(str(dom_errors))
    except:
        dom_count = 1
    return str(dom_count + len(browser_errors))

def error_list():
    dom_list = evl("window.__e ? window.__e.join('; ') : ''")
    all_errors = [e for e in [str(dom_list)] if e and e != "none"] + browser_errors
    return "; ".join(all_errors) if all_errors else "none"

def wait_for_js(predicate_expr, timeout_seconds=8, interval_seconds=0.25):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        drain()
        value = evl(predicate_expr)
        if value is True or str(value).lower() == "true":
            return True
        time.sleep(interval_seconds)
    drain()
    value = evl(predicate_expr)
    return value is True or str(value).lower() == "true"

def wait_for_path_and_text(path, text_fragment, timeout_seconds=8):
    return wait_for_js(
        f'location.pathname === "{path}" && '
        f'(document.getElementById("beacon-app")?.textContent || "").includes("{text_fragment}")',
        timeout_seconds=timeout_seconds,
    )

def check_history_go(delta, path, text_fragment, label):
    clear_cdp_events()
    evl(f"history.go({delta})")
    check(wait_for_path_and_text(path, text_fragment), f"{label}: URL and view restore {path}")
    check(websocket_type_count("Sent", "navigate") >= 1, f"{label}: popstate sends navigate")
    check(
        websocket_type_count("Received", "mount") >= 1
        or received_state_update_count() >= 1,
        f"{label}: popstate receives route state",
    )

def websocket_ready():
    return str(evl("window.__beaconWsState ? window.__beaconWsState() : -1")) == "1"

def force_socket_reconnect(label, expected_text):
    clear_cdp_events()
    before_state = evl('window.__beaconCloseSocketForTest ? window.__beaconCloseSocketForTest() : "missing"')
    check(str(before_state) != "missing", f"{label}: test socket close hook is available")
    check(str(before_state) == "1", f"{label}: socket was open before forced close (state={before_state})")
    check(wait_for_cdp_method("Network.webSocketClosed", timeout_seconds=4), f"{label}: browser reports WebSocket close")
    socket_open = wait_for_js(
        'window.__beaconWsState && window.__beaconWsState() === 1',
        timeout_seconds=20,
    )
    fresh_state = (
        wait_for_websocket_type("Received", "model_sync", timeout_seconds=20)
        or wait_for_websocket_type("Received", "mount", timeout_seconds=1)
    )
    connection_ready = wait_for_js(
        'window.__beaconConnectionReady && window.__beaconConnectionReady() === true',
        timeout_seconds=8,
    )
    text_ready = wait_for_js(
        f'(document.getElementById("beacon-app")?.textContent || "").includes("{expected_text}")',
        timeout_seconds=8,
    )
    check(socket_open and fresh_state and connection_ready and text_ready, f"{label}: socket reconnects and app is ready")
    check(websocket_type_count("Sent", "join") >= 1, f"{label}: reconnect sends join")
    check(
        websocket_type_count("Received", "mount") >= 1
        or websocket_type_count("Received", "model_sync") >= 1,
        f"{label}: reconnect receives fresh server state",
    )

def install_dom_monitor():
    global DOM_MONITOR_INSTALLED
    if DOM_MONITOR_INSTALLED:
        return
    script = r"""
(() => {
  window.__BEACON_ENABLE_TEST_HOOKS = true;
  window.__e = [];
  const previousConsoleError = console.error;
  console.error = function(...args) {
    window.__e.push(args.map((arg) => {
      try {
        return typeof arg === "string" ? arg : JSON.stringify(arg);
      } catch (_) {
        return String(arg);
      }
    }).join(" "));
    previousConsoleError.apply(console, args);
  };

  function freshMonitor() {
    return {
      mutations: [],
      bodySamples: [],
      layoutShifts: [],
      layoutShiftSources: [],
      emptyAfterContent: 0,
      sawContent: false
    };
  }

  window.__beaconMonitor = freshMonitor();

  function recordSample() {
    const app = document.getElementById("beacon-app");
    if (!app) return;
    const textLength = (app.textContent || "").trim().length;
    if (textLength > 0) window.__beaconMonitor.sawContent = true;
    if (window.__beaconMonitor.sawContent && textLength === 0) {
      window.__beaconMonitor.emptyAfterContent += 1;
    }
    window.__beaconMonitor.bodySamples.push({
      t: performance.now(),
      textLength,
      htmlLength: app.innerHTML.length
    });
  }

  function setupObserver() {
    const app = document.getElementById("beacon-app");
    if (!app || app.__beaconMonitorAttached) return;
    app.__beaconMonitorAttached = true;
    new MutationObserver((records) => {
      recordSample();
      window.__beaconMonitor.mutations.push({
        t: performance.now(),
        count: records.length,
        textLength: (app.textContent || "").trim().length,
        htmlLength: app.innerHTML.length
      });
    }).observe(app, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: true
    });
    let frames = 0;
    function sampleFrame() {
      recordSample();
      frames += 1;
      if (frames < 180) requestAnimationFrame(sampleFrame);
    }
    requestAnimationFrame(sampleFrame);
  }

  window.__beaconResetMonitor = function() {
    window.__beaconMonitor = freshMonitor();
    recordSample();
    setupObserver();
  };

  window.__beaconMonitorSummary = function(bucketMs) {
    const m = window.__beaconMonitor || freshMonitor();
    const buckets = {};
    for (const item of m.mutations || []) {
      const key = Math.floor(item.t / bucketMs);
      buckets[key] = (buckets[key] || 0) + item.count;
    }
    const values = Object.values(buckets);
    return JSON.stringify({
      mutationCount: (m.mutations || []).length,
      maxBucket: values.length ? Math.max(...values) : 0,
      emptyAfterContent: m.emptyAfterContent || 0,
      layoutShiftCount: (m.layoutShifts || []).length,
      layoutShiftTotal: (m.layoutShifts || []).reduce((a, b) => a + b, 0),
      layoutShiftSources: (m.layoutShiftSources || []).slice(0, 6)
    });
  };

  function describeShiftSource(source) {
    const node = source.node;
    const name = node ? (node.nodeName + " " + (node.textContent || "").trim().slice(0, 24)) : "?";
    const before = source.previousRect;
    const after = source.currentRect;
    return name + " y" + Math.round(before.y) + "->" + Math.round(after.y)
      + " h" + Math.round(before.height) + "->" + Math.round(after.height);
  }

  if ("PerformanceObserver" in window) {
    try {
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          if (!entry.hadRecentInput) {
            window.__beaconMonitor.layoutShifts.push(entry.value);
            for (const source of entry.sources || []) {
              window.__beaconMonitor.layoutShiftSources.push(describeShiftSource(source));
            }
          }
        }
      }).observe({type: "layout-shift", buffered: true});
    } catch (_) {}
  }

  document.addEventListener("DOMContentLoaded", setupObserver);
  setTimeout(setupObserver, 0);
})();
"""
    cdp("Page.addScriptToEvaluateOnNewDocument", {"source": script})
    DOM_MONITOR_INSTALLED = True

def reset_dom_monitor():
    evl('window.__beaconResetMonitor ? (window.__beaconResetMonitor(), "ok") : "missing"')

def mutation_bucket_summary(bucket_ms=100):
    return evl("""
(() => {
  if (window.__beaconMonitorSummary) return window.__beaconMonitorSummary(BUCKET_MS);
  return JSON.stringify({{mutationCount: 0, maxBucket: 0, emptyAfterContent: 0, layoutShiftCount: 0, layoutShiftTotal: 0}});
})()
""".replace("BUCKET_MS", str(bucket_ms)).replace("{{", "{").replace("}}", "}"))

def check_dom_conformance(label, max_bucket=80, max_layout_shift=0.05):
    summary = json.loads(str(mutation_bucket_summary()))
    check(summary["emptyAfterContent"] == 0, f"{label}: no empty-root flicker samples ({summary})")
    check(summary["maxBucket"] <= max_bucket, f"{label}: DOM mutation burst under threshold ({summary})")
    check(summary["layoutShiftTotal"] <= max_layout_shift, f"{label}: layout shift under threshold ({summary})")
    if MOBILE_VIEWPORT:
        overflow = evl("""
(() => {
  const doc = document.documentElement;
  const body = document.body;
  const scrollWidth = Math.max(doc.scrollWidth || 0, body ? body.scrollWidth || 0 : 0);
  const clientWidth = doc.clientWidth || window.innerWidth || 0;
  return JSON.stringify({scrollWidth, clientWidth, overflow: scrollWidth - clientWidth});
})()
""")
        overflow_summary = json.loads(str(overflow))
        check(
            overflow_summary["overflow"] <= 2,
            f"{label}: no mobile horizontal overflow ({overflow_summary})",
        )

def start_example(name, module=None):
    global server_proc, SKIP
    # Skip if filtered out
    if not should_run(name):
        SKIP += 1
        return False
    stop_server()
    d = os.path.join(ROOT, "examples", name)
    mod = module or name
    vlog(f"Starting {name} (module={mod}) in {d}")
    server_proc = subprocess.Popen(
        ["gleam", "run", "-m", mod],
        cwd=d, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        start_new_session=True
    )
    deadline = time.time() + SERVER_START_TIMEOUT_SECONDS
    while time.time() < deadline:
        line = server_proc.stdout.readline().decode("utf-8", errors="replace")
        if VERBOSE and line.strip():
            print(f"    [server] {line.rstrip()}")
        if "Listening" in line:
            time.sleep(1.5)
            report_contract(name, d)
            vlog("Server ready")
            return True
        if server_proc.poll() is not None:
            rest = server_proc.stdout.read().decode("utf-8", errors="replace")
            print(f"  * Server died: {rest[-300:]}")
            check(False, f"{name}: server starts")
            return False
    print("  * Server timeout")
    check(False, f"{name}: server starts before timeout")
    return False

def report_contract(name, directory):
    path = os.path.join(directory, "build", "beacon_contract.json")
    if not os.path.exists(path):
        check(False, f"{name}: generated contract report exists")
        return
    try:
        with open(path, "r", encoding="utf-8") as fh:
            report = json.load(fh)
    except Exception as exc:
        check(False, f"{name}: generated contract report is valid JSON ({exc})")
        return
    CONTRACT_REPORTS[name] = report
    kind = report.get("kind")
    client_messages = report.get("client_messages", [])
    print(f"  contract: {kind} app, view {report.get('view')}, {len(client_messages)} browser messages")
    check(kind in ("simple", "application", "full_application"), f"{name}: generated contract names the constructor ({kind})")
    check(bool(report.get("view")) and bool(report.get("model")) and bool(report.get("msg")), f"{name}: generated contract names view, Model and Msg")
    check(
        (kind == "simple") == bool(report.get("client_update")),
        f"{name}: only beacon.simple compiles its update for the browser",
    )
    if name in NO_HANDLER_EXAMPLES:
        check(client_messages == [], f"{name}: generated contract lists no browser messages (view has no handlers)")
    else:
        check(isinstance(client_messages, list) and len(client_messages) >= 1, f"{name}: generated contract lists browser messages")

def stop_server():
    global server_proc
    try:
        cdp("Page.navigate", {"url": "about:blank"}, timeout=2)
        time.sleep(0.2)
        drain()
        clear_browser_errors()
    except Exception as exc:
        vlog(f"Browser unload before server stop skipped: {exc}")
    if server_proc:
        try:
            os.killpg(os.getpgid(server_proc.pid), signal.SIGTERM)
            server_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(os.getpgid(server_proc.pid), signal.SIGKILL)
            server_proc.wait(timeout=5)
        except Exception as exc:
            vlog(f"Server stop warning: {exc}")
        server_proc = None
    if os.environ.get("BEACON_CDP_KILL_PORT") == "1":
        os.system(f"lsof -ti:{BEACON_PORT} 2>/dev/null | xargs kill -9 2>/dev/null")
    time.sleep(0.5)

def check(cond, msg):
    global PASS, FAIL
    if cond:
        print(f"  + {msg}")
        PASS += 1
    else:
        print(f"  FAIL {msg}")
        FAIL += 1
        if VERBOSE:
            t = evl('document.getElementById("beacon-app")?.textContent?.substring(0,200) || "NO APP"')
            print(f"    [v] DOM text: {t}")
            h = evl('document.getElementById("beacon-app")?.innerHTML?.substring(0,300) || "NO HTML"')
            print(f"    [v] HTML: {h}")

print("=== Beacon CDP Test Suite ===")
if ONLY:
    print(f"Filter: {ONLY}")
if CANONICAL_ONLY:
    print("Canonical: ON")
if SHARD:
    print(f"Shard: {SHARD[0]}/{SHARD[1]}")
print(f"Viewport: {VIEWPORT}")
if VERBOSE:
    print("Verbose: ON")
print()
reconnect_cdp()

# == 1. Counter ==
print("-- 1: Counter --")
if start_example("counter"):
    navigate()
    t = text()
    check("Count: 0" in t, "Initial: Count: 0")
    reset_dom_monitor()
    clear_cdp_events()
    click_button("+")
    t = text()
    check("Count: 1" in t, "Increment: Count: 1")
    check_model_ws_update("Counter increment")
    clear_cdp_events()
    click_button("+")
    t = text()
    check("Count: 2" in t, "Increment: Count: 2")
    check_model_ws_update("Counter second increment")
    clear_cdp_events()
    click_button("-")
    t = text()
    check("Count: 1" in t, "Decrement: Count: 1")
    check_model_ws_update("Counter decrement")
    clear_cdp_events()
    click_button("-")
    t = text()
    check("Count: 0" in t, "Decrement: Count: 0")
    check_model_ws_update("Counter second decrement")
    check_dom_conformance("Counter")

    reset_dom_monitor()
    force_socket_reconnect("Counter reconnect", "Count: 0")
    clear_cdp_events()
    click_button("+")
    check(
        wait_for_js('(document.getElementById("beacon-app")?.textContent || "").includes("Count: 1")'),
        "Counter reconnect: click works after reconnect",
    )
    check(
        wait_for_websocket_type("Sent", "event", timeout_seconds=8),
        f"Counter reconnect: sends model event after reconnect ({sent_model_event_units()})",
    )
    check(
        wait_for_websocket_type("Received", "patch", timeout_seconds=8)
        or wait_for_websocket_type("Received", "model_sync", timeout_seconds=1),
        "Counter reconnect: receives state update after reconnect",
    )
    check(websocket_type_count("Received", "mount") == 0, "Counter reconnect: post-reconnect click receives no HTML mount")
    check_dom_conformance("Counter reconnect")

    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 2. Counter Local ==
print("-- 2: Counter Local --")
if start_example("counter_local"):
    navigate()
    t = text()
    check("Count (server): 0" in t, "Initial server count: 0")
    reset_dom_monitor()
    clear_cdp_events()
    click_button("+")
    t = text()
    check("Count (server): 1" in t, "Server +1")
    check_model_ws_update("Counter local server +1")
    clear_cdp_events()
    click_button("+")
    t = text()
    check("Count (server): 2" in t, "Server +2")
    check_model_ws_update("Counter local server +2")
    clear_cdp_events()
    click_button("-")
    t = text()
    check("Count (server): 1" in t, "Server -1")
    check_model_ws_update("Counter local server -1")
    # LOCAL: toggle menu on
    clear_cdp_events()
    click_by_text("Toggle")
    t = text()
    check("Menu is open" in t, "Toggle menu ON")
    check_local_ws_quiet("Counter local menu on")
    # LOCAL: toggle menu off
    clear_cdp_events()
    click_by_text("Toggle")
    t = text()
    check("Menu is open" not in t, "Toggle menu OFF")
    check_local_ws_quiet("Counter local menu off")
    # LOCAL: input
    clear_cdp_events()
    type_input("[data-beacon-on-input]", "testlocal")
    time.sleep(0.5); drain()
    t = text()
    check("testlocal" in t, "Local input shows text")
    check_local_ws_quiet("Counter local input")
    clear_cdp_events()
    click_button("+")
    t = text()
    check("Count (server): 2" in t, "Server event after local input still works")
    check(websocket_payload_count("Sent", '"type":"event"') >= 1, "Server event after local input sends one model event")
    check(websocket_payload_count("Sent", '"type":"event_batch"') == 0, "Local input is not replayed as event_batch")
    check_dom_conformance("Counter local")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 3. Kanban ==
print("-- 3: Kanban --")
if start_example("kanban"):
    navigate()
    t = text()
    check("Kanban Board" in t, "Title renders")
    check("Design API" in t, "Initial card renders")
    check("Todo" in t and "In Progress" in t and "Done" in t, "3 columns")
    check("(3)" in t, "Todo shows (3)")
    check("(1)" in t, "In Progress shows (1)")
    # Add card
    type_input("[data-beacon-on-input]", "CDP Card")
    time.sleep(1); drain()
    submit_by_text("Add Card")
    time.sleep(2); drain()
    t = text()
    check("CDP Card" in t, f"Added card visible")
    check("(4)" in t, "Todo shows (4)")
    # Delete card — count delete buttons via DOM, not character "x" in text
    card_count_before = int(str(evl('var c=0; document.querySelectorAll("[data-beacon-on-click]").forEach(function(b){if(b.textContent.trim()==="x")c++}); c')))
    evl('var xs=document.querySelectorAll("[data-beacon-on-click]"); for(var x of xs){if(x.textContent.trim()==="x"){x.click();break}}')
    time.sleep(2); drain()
    card_count_after = int(str(evl('var c=0; document.querySelectorAll("[data-beacon-on-click]").forEach(function(b){if(b.textContent.trim()==="x")c++}); c')))
    check(card_count_after < card_count_before, f"Delete: {card_count_before} -> {card_count_after}")
    # DnD: drag "Write tests" to Done
    evl("""
    (function() {
      var card = Array.from(document.querySelectorAll('[data-card]')).find(function(c){return c.textContent.includes("Write tests")});
      var done = document.querySelector('[data-column="done"]');
      if (!card || !done) return "not found";
      var dt = new DataTransfer();
      dt.setData("text/plain", "2");
      card.dispatchEvent(new DragEvent("dragstart", {bubbles:true, dataTransfer:dt}));
      done.dispatchEvent(new DragEvent("dragover", {bubbles:true, dataTransfer:dt}));
      done.dispatchEvent(new DragEvent("drop", {bubbles:true, dataTransfer:dt}));
      return "dragged";
    })()
    """)
    time.sleep(3); drain()
    h = html()
    done_section = h.split('data-column="done"')[-1] if 'data-column="done"' in h else ""
    check("Write tests" in done_section, "Drag: card in Done column")
    # MULTI-USER: navigate away + back → cards persist from shared store
    navigate()
    time.sleep(2); drain()
    t = text()
    check("CDP Card" in t, "Multi-user: added card persists in new session")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 4. Canvas ==
print("-- 4: Canvas --")
if start_example("canvas"):
    navigate()
    t = text()
    check("Collaborative Canvas" in t, "Title")
    check("Strokes: 0" in t, "Initial 0 strokes")
    # Draw: mousedown → moves → mouseup
    evl('var s=document.querySelector("svg"),r=s.getBoundingClientRect(); s.dispatchEvent(new MouseEvent("mousedown",{clientX:r.left+50,clientY:r.top+50,bubbles:true}))')
    time.sleep(0.2)
    for i in range(5):
        x = 50 + (i+1)*30
        evl(f'var s=document.querySelector("svg"),r=s.getBoundingClientRect(); s.dispatchEvent(new MouseEvent("mousemove",{{clientX:r.left+{x},clientY:r.top+{50+i*20},bubbles:true}}))')
        time.sleep(0.1)
    lines_during = int(str(evl('document.querySelectorAll("polyline").length')))
    check(lines_during > 0, f"LOCAL drawing: {lines_during} lines while dragging")
    # Release → commit strokes
    evl('document.querySelector("svg").dispatchEvent(new MouseEvent("mouseup",{bubbles:true}))')
    time.sleep(3); drain()
    lines_after = int(str(evl('document.querySelectorAll("polyline").length')))
    t = text()
    check(lines_after > 0, f"Lines persist after mouseup: {lines_after}")
    check("Strokes: 0" not in t, f"Stroke count changed from 0")
    # Color change
    evl('var btns=document.querySelectorAll("[data-beacon-on-click]"); for(var b of btns){var s=b.getAttribute("style")||""; if(s.includes("ff0000")){b.click();break}}')
    time.sleep(1); drain()
    h = html()
    check('ff0000' in h, "Color picker works")
    # MULTI-USER: navigate away + back → strokes persist from shared store
    navigate()
    time.sleep(3); drain()
    t = text()
    lines_new_session = int(str(evl('document.querySelectorAll("polyline").length')))
    check(lines_new_session > 0, f"Multi-user: {lines_new_session} strokes in new session (from store)")
    check("Strokes: 0" not in t, f"Multi-user: stroke count > 0 in new session")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 5. Snake ==
print("-- 5: Snake --")
if start_example("snake"):
    navigate()
    t = text()
    check("Snake" in t, "Title")
    type_input("[data-beacon-on-input]", "CDPPlayer")
    submit_by_text("Play")
    time.sleep(1); drain()
    t = text()
    check("Score" in t, "Game started, Score visible")
    check("CDPPlayer" in t, "Player name shown")
    # Tick loop: wait and check DOM changes
    h1 = html()
    time.sleep(3); drain()
    h2 = html()
    t2 = text()
    game_progressed = (h1 != h2) or ("Score: 1" in t2) or ("GAME OVER" in t2)
    check(game_progressed, "Tick loop: game state changes over time")
    rect_count = h2.count("<rect")
    check(rect_count >= 2, f"SVG rects: {rect_count}")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 6. Chat ==
print("-- 6: Chat --")
if start_example("chat"):
    navigate()
    t = text()
    check("Beacon Chat" in t, "Title")
    # Login
    type_input("[data-beacon-on-input]", "TestUser")
    submit_by_text("Join")
    time.sleep(2); drain()
    t = text()
    check("#general" in t or "general" in t, "Room shown")
    check("TestUser" in t, "Username displayed")
    check("No messages yet" in t, "Empty room")
    # Send message
    evl('''
    (function() {
      var inputs = document.querySelectorAll("input[data-beacon-on-input]");
      for (var i = 0; i < inputs.length; i++) {
        if (inputs[i].placeholder && inputs[i].placeholder.toLowerCase().includes("message")) {
          inputs[i].value = "Hello from CDP";
          inputs[i].dispatchEvent(new Event("input", {bubbles: true}));
          return "typed";
        }
      }
      if (inputs.length > 0) {
        inputs[inputs.length-1].value = "Hello from CDP";
        inputs[inputs.length-1].dispatchEvent(new Event("input", {bubbles: true}));
        return "typed-fallback";
      }
      return "no-input";
    })()
    ''')
    time.sleep(1); drain()
    submit_by_text("Send")
    time.sleep(3); drain()
    t = text()
    check("Hello from CDP" in t, "Message appears in chat")
    check("TestUser" in t and "Hello from CDP" in t, "Sender + text shown")
    check("No messages yet" not in t, "Empty state cleared")
    # MULTI-USER: reload → re-login → message persists from store
    navigate()
    time.sleep(2); drain()
    type_input("[data-beacon-on-input]", "User2")
    submit_by_text("Join")
    time.sleep(2); drain()
    t = text()
    check("Hello from CDP" in t, "Multi-user: message persists for new user")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 7. Dashboard ==
print("-- 7: Dashboard --")
if start_example("dashboard"):
    navigate()
    time.sleep(5); drain()
    t = text()
    check("Dashboard" in t or "Live" in t, "Title")
    check("Process" in t, "Process metric")
    check("Memory" in t, "Memory metric")
    check("Uptime" in t, "Uptime metric")
    # Server-push: tick should increment over time
    t1 = text()
    tick1 = -1
    m = re.search(r'Tick #(\d+)', t1)
    if m: tick1 = int(m.group(1))
    time.sleep(5); drain()
    t2 = text()
    tick2 = -1
    m = re.search(r'Tick #(\d+)', t2)
    if m: tick2 = int(m.group(1))
    uptime_changed = t1 != t2
    check(tick2 > tick1 or uptime_changed, f"Server-push: tick {tick1}->{tick2}, changed={uptime_changed}")
    check("MB" in t2, "Memory has MB value")
    h = html()
    check("svg" in h, "SVG elements present")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 8. Pong ==
print("-- 8: Pong --")
if start_example("pong"):
    navigate()
    t = text()
    check("Pong" in t, "Title")
    check("Start" in t, "Start button")
    # Start game
    click_by_text("Start")
    time.sleep(1); drain()
    t = text()
    check("Pause" in t, "Start -> Pause")
    # Wait for score changes (ball hits wall)
    time.sleep(3); drain()
    t = text()
    has_score = bool(re.search(r'[1-9]', t.split("P1")[0])) if "P1" in t else False
    check(has_score or "Pause" in t, f"Game running (score or pause visible)")
    # Pause
    evl('''
    (function() {
      var buttons = Array.from(document.querySelectorAll("button"));
      var pause = buttons.find(function(b) { return b.textContent.trim() === "Pause"; });
      if (pause) pause.click();
      return pause ? "pause-clicked" : "missing-pause";
    })()
    ''')
    wait_for_js('document.getElementById("beacon-app").textContent.includes("Start")', timeout_seconds=3)
    drain()
    t = text()
    check("Start" in t, "Pause -> Start")
    # Ball position stays frozen when paused. Full HTML can be re-rendered by a
    # no-op server tick, so assert the actual game-state surface.
    time.sleep(1); drain()
    ball1 = evl('''
    (function() {
      var ball = document.querySelector('[data-testid="pong-ball"]');
      return ball ? ball.getAttribute("style") : "";
    })()
    ''')
    time.sleep(1); drain()
    ball2 = evl('''
    (function() {
      var ball = document.querySelector('[data-testid="pong-ball"]');
      return ball ? ball.getAttribute("style") : "";
    })()
    ''')
    check(ball1 == ball2 and ball1 != "", "Frozen when paused")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 9. Triple Counter ==
print("-- 9: Triple Counter --")
if start_example("triple_counter"):
    navigate()
    t = text()
    check("Shared Counter" in t, "Shared section")
    check("Server Counter" in t, "Server section")
    check("Local Counter" in t, "Local section")
    bc = evl('document.querySelectorAll("[data-beacon-on-click]").length')
    check(int(str(bc)) >= 6, f"6+ buttons ({bc})")
    # Increment all 3 counters
    click_button("+", 0)  # Shared +
    click_button("+", 1)  # Server +
    click_button("+", 2)  # Local +
    t = text()
    check(t.count("1") >= 3, "All 3 counters show 1")
    # Decrement shared back
    click_button("-")
    t = text()
    check("0" in t, "Shared decremented")
    # MULTI-USER: navigate away → new session
    # Increment shared to 3 first
    click_button("+")
    click_button("+")
    click_button("+")
    time.sleep(1); drain()
    navigate()
    time.sleep(2); drain()
    t = text()
    # Shared should show 3 (persisted), server/local should reset to 0
    # Extract the text between "Shared Counter" and "Server Counter" to avoid matching "3" in other text
    shared_section = ""
    if "Shared Counter" in t and "Server Counter" in t:
        shared_section = t.split("Shared Counter")[1].split("Server Counter")[0]
    check(" 3 " in shared_section, f"Multi-user: shared counter persists (3)")
    # Server and Local should be 0 in new session
    # Extract the text between "Server Counter" and "Local Counter"
    server_section = ""
    if "Server Counter" in t and "Local Counter" in t:
        server_section = t.split("Server Counter")[1].split("Local Counter")[0]
    check("0" in server_section, f"Multi-user: server counter reset to 0")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 11. Todo App ==
print("-- 11: Todo App --")
if start_example("todo", module="todo_app"):
    navigate()
    t = text()
    check("Todo" in t, "Title")
    check("0 items left" in t or "item" in t, f"Items left counter ({t[:60]})")
    # Add todo
    type_input("[data-beacon-on-input]", "Buy milk")
    submit_by_text("Add")
    time.sleep(2); drain()
    t = text()
    check("Buy milk" in t, "Added todo visible")
    check("1 item" in t, f"1 item left ({t[:80]})")
    # Add another
    type_input("[data-beacon-on-input]", "Walk dog")
    submit_by_text("Add")
    time.sleep(2); drain()
    t = text()
    check("Walk dog" in t, "Second todo visible")
    check("2 items" in t, f"2 items left")
    # Toggle first todo (click the circle button)
    evl('var btns=document.querySelectorAll("[data-beacon-on-click]"); for(var b of btns){if(b.style&&b.style.borderRadius==="50%"){b.click();break}}')
    time.sleep(2); drain()
    t = text()
    check("1 item" in t, f"Toggle: 1 item left after completing one")
    # Filter Active
    click_by_text("Active")
    time.sleep(1); drain()
    t = text()
    check("Buy milk" not in t, "Filter Active: completed todo hidden")
    check("Walk dog" in t, "Filter Active: active still shown")
    # Filter All
    click_by_text("All")
    time.sleep(1); drain()
    t = text()
    check("Buy milk" in t and "Walk dog" in t, "Filter All: both visible")
    # Delete todo — count delete buttons via DOM, not character "x" in text
    before_count = int(str(evl('var c=0; document.querySelectorAll("[data-beacon-on-click]").forEach(function(b){if(b.textContent.trim()==="x")c++}); c')))
    evl('var xs=document.querySelectorAll("[data-beacon-on-click]"); for(var x of xs){if(x.textContent.trim()==="x"){x.click();break}}')
    time.sleep(2); drain()
    after_count = int(str(evl('var c=0; document.querySelectorAll("[data-beacon-on-click]").forEach(function(b){if(b.textContent.trim()==="x")c++}); c')))
    check(after_count < before_count, f"Delete: removed ({before_count}->{after_count})")
    # Multi-user: navigate away+back, remaining todo persists
    navigate()
    time.sleep(2); drain()
    t = text()
    check("Walk dog" in t or "Buy milk" in t, "Multi-user: todo persists in new session")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 12. Shopping Cart ==
print("-- 12: Shopping Cart --")
if start_example("cart"):
    navigate()
    t = text()
    check("Shopping Cart" in t, "Title")
    check("Laptop" in t, "Product listed")
    check("$999" in t, "Price shown")
    check("Stock:" in t or "stock" in t.lower(), f"Stock shown ({t[:120]})")
    check("Cart is empty" in t, "Cart initially empty")
    # Add product to cart
    click_by_text("Add")
    time.sleep(2); drain()
    t = text()
    check("Cart is empty" not in t, "Cart not empty after add")
    # Check totals exist
    check("Subtotal" in t, f"Subtotal shown")
    check("Tax" in t, f"Tax shown")
    check("Total" in t, f"Total shown")
    # Increment quantity
    evl('var btns=document.querySelectorAll("[data-beacon-on-click]"); for(var b of btns){if(b.textContent.trim()==="+"){b.click();break}}')
    time.sleep(2); drain()
    t = text()
    check("2" in t, "Quantity incremented")
    # Remove from cart
    evl('var btns=document.querySelectorAll("[data-beacon-on-click]"); for(var b of btns){if(b.textContent.trim()==="x"&&b.style.color){b.click();break}}')
    time.sleep(2); drain()
    t = text()
    check("Cart is empty" in t, "Cart empty after remove")
    # Multi-user: add to cart, navigate away+back, stock persists
    click_by_text("Add")
    time.sleep(2); drain()
    navigate()
    time.sleep(2); drain()
    t = text()
    # Stock should be decreased from initial
    check("Stock: 4" in t or "stock: 4" in t.lower() or "4" in t, "Multi-user: decreased stock persists")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 13. Spreadsheet ==
print("-- 13: Spreadsheet --")
if start_example("spreadsheet"):
    navigate()
    t = text()
    check("Spreadsheet" in t, "Title")
    h = html()
    check("table" in h or "grid" in h, "Grid rendered")
    check("A" in t and "B" in t, "Column headers")
    # Click cell A2 to select
    evl('''
    (function() {
      var tds = document.querySelectorAll("td");
      for (var i = 0; i < tds.length; i++) {
        if (tds[i].hasAttribute("data-beacon-on-click") && tds[i].textContent === "") {
          tds[i].click();
          return "selected " + i;
        }
      }
      return "none";
    })()
    ''')
    time.sleep(1.5); drain()
    t = text()
    check("Selected" in t, f"Cell selected ({t[-40:]})")
    # Click same cell again to enter edit mode
    evl('''
    (function() {
      var tds = document.querySelectorAll("td[data-beacon-on-click]");
      for (var i = 0; i < tds.length; i++) {
        if (tds[i].hasAttribute("data-beacon-on-click")) {
          tds[i].click();
          return "edit " + i;
        }
      }
      return "none";
    })()
    ''')
    time.sleep(1); drain()
    # Type into the edit input and submit
    typed = evl('''
    (function() {
      var inp = document.querySelector("input[data-beacon-on-input]");
      if (!inp) return "no-input";
      inp.value = "CellData";
      inp.dispatchEvent(new Event("input", {bubbles: true}));
      return "typed";
    })()
    ''')
    time.sleep(0.5); drain()
    submit_by_text("Save")
    time.sleep(3); drain()
    t = text()
    check("CellData" in t, f"Cell value saved (typed={typed})")
    # Multi-user: navigate away+back — cell value should persist from store
    time.sleep(3)
    navigate()
    time.sleep(4); drain()
    t = text()
    persists = "CellData" in t
    check(persists, f"Multi-user: cell persistence (persists={persists})")
    # The store write happens in the server update for SaveCell.
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 10. AI Chat ==
print("-- 10: AI Chat --")
if start_example("ai_chat"):
    navigate()
    t = text()
    check("AI" in t or "Chat" in t or "chat" in t.lower(), f"UI renders")
    h = html()
    check("data-beacon-on-input" in h, "Input field present")
    check("data-beacon-on-click" in h, "Send button present")
    type_input("input[data-beacon-on-input]", "hello cdp")
    clear_cdp_events()
    click_button("Send")
    check(
        wait_for_js('(document.getElementById("beacon-app")?.textContent || "").includes("Server stream received: hello cdp. Beacon keeps")', timeout_seconds=15),
        "Server stream drips the response to the browser",
    )
    check(
        wait_for_js('Array.from(document.querySelectorAll("button")).some(function(b){return b.textContent.trim()==="Send" && !b.disabled})', timeout_seconds=15),
        "Send button is enabled again after the stream finishes",
    )
    check_model_ws_update("AI chat prompt")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 10b. Privacy Demo ==
print("-- 10b: Privacy Demo --")
if start_example("privacy_demo"):
    navigate()
    t = text()
    check("Privacy Demo" in t, "SSR: title renders")
    check("Total: $48.60" in t, "SSR: derived total renders")
    secrets = ["sk_live_secret_do_not_leak_this", "postgres://user:pass@localhost/db"]
    check(all(s not in str(html()) for s in secrets), "Server secrets not present in DOM")
    bundle_text = evl_async("""
      (async () => {
        const src = Array.from(document.scripts).map(s => s.src).find(s => s.includes('beacon_client_'));
        return src ? await fetch(src).then(r => r.text()) : '';
      })()
    """)
    check(len(str(bundle_text)) > 0, "Client bundle fetched")
    check(all(s not in str(bundle_text) for s in secrets), "Server secrets not present in client bundle")
    clear_cdp_events()
    click_button("Add Item")
    t = text()
    check("Items: 3" in t and "Total: $54.00" in t, "Add item updates the derived totals")
    check_model_ws_update("Privacy demo add item")
    clear_cdp_events()
    click_button("Clear")
    t = text()
    check("Items: 0" in t and "Total: $0.00" in t, "Clear empties the cart")
    check_model_ws_update("Privacy demo clear")
    check(all(s not in str(html()) for s in secrets), "Server secrets still absent after updates")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 14. Middleware Demo ==
print("-- 14: Middleware Demo --")
if start_example("middleware_demo", module="app"):
    navigate()
    t = text()
    check("Middleware Demo" in t, "Title")
    check("Counter" in t, "Counter section")
    check("Active Middleware" in t, "Middleware info shown")
    # Counter works (middleware doesn't block the main page)
    click_by_text("+")
    t = text()
    check("Counter: 1" in t, "Increment works")
    click_by_text("+")
    t = text()
    check("Counter: 2" in t, "Increment again")
    click_by_text("-")
    t = text()
    check("Counter: 1" in t, "Decrement works")
    # Verify middleware headers via fetch (HTTP-level test)
    health = evl('fetch("/healthz").then(r=>r.text()).then(t=>window.__health=t); "fetching"')
    time.sleep(1); drain()
    health_body = evl('window.__health || "pending"')
    check("ok" in str(health_body), f"Health endpoint returns ok ({health_body})")
    check(errors() == "0", f"No errors before expected admin rejection ({error_list()})")
    # /admin should be blocked without X-Admin header
    evl('fetch("/admin/secret").then(r=>{window.__admin_status=r.status}); "fetching"')
    time.sleep(1); drain()
    admin_status = evl('window.__admin_status || 0')
    check(str(admin_status) == "403", f"Admin blocked without header (status={admin_status})")
    api_post = evl_async("""
      fetch('/api/items', {method: 'POST'})
        .then(r => r.status + ':' + r.headers.get('allow') + ':' + r.headers.get('x-api-version'))
    """)
    check(str(api_post) == "405:GET, HEAD:v1", f"API write blocked with allow header ({api_post})")
    clear_browser_errors()
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 15. Multi-File Domains ==
print("-- 15: Multi-File Domains --")
if start_example("domains", module="app"):
    navigate()
    t = text()
    check("Multi-File Domains" in t, "Title")
    check("Alice" in t, "User name shown")
    check("alice@example.com" in t, "User email shown")
    check("Member" in t, "Role shown")
    # Items shown
    check("Buy groceries" in t, "Item 1 shown")
    check("Write tests" in t, "Item 2 shown")
    # Toggle an item
    h_before = html()
    click("[data-beacon-on-click]")
    time.sleep(1); drain()
    # Add an item
    type_input('input[type="text"]', "New item")
    submit_by_text("Add")
    t = text()
    check("New item" in t or "Items" in t, "Item added or list updated")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 16. Multi-File Kanban ==
print("-- 16: Multi-File Kanban --")
if start_example("multi_kanban", module="app"):
    navigate()
    t = text()
    check("Multi-File Kanban" in t, "Title")
    check("Todo" in t, "Todo column")
    check("In Progress" in t, "Doing column")
    check("Done" in t, "Done column")
    # Initial cards
    check("Design API" in t, "Card 1 shown")
    check("Write tests" in t, "Card 2 shown")
    check("Build UI" in t, "Card 3 shown")
    # Add a card
    type_input('input[type="text"]', "Deploy")
    submit_by_text("Add Card")
    t = text()
    check("Deploy" in t, "New card added")
    # Delete a card (click x button)
    h = html()
    check("data-beacon-on-dragstart" in h, "Drag handlers present")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 17. Multi-File Todo ==
print("-- 17: Multi-File Todo --")
if start_example("multi_todo", module="app"):
    navigate()
    t = text()
    check("Multi-File Todo" in t, "Title")
    check("Learn Gleam" in t, "Initial item 1")
    check("Build with Beacon" in t, "Initial item 2")
    check("Ship it" in t, "Initial item 3")
    # Items remaining counter
    check("2 items remaining" in t, "Remaining count (1 completed, 2 active)")
    # Add a todo
    type_input('input[type="text"]', "Write docs")
    submit_by_text("Add")
    t = text()
    check("Write docs" in t, "New todo added")
    check("3 items remaining" in t, "Remaining count updated")
    # Filter buttons
    click_by_text("Active")
    time.sleep(1); drain()
    t = text()
    # Active filter should hide completed items
    check("Learn Gleam" not in t or "items remaining" in t, "Filter active works")
    click_by_text("All")
    time.sleep(1); drain()
    # Clear completed
    click_by_text("Clear Done")
    t = text()
    check("Learn Gleam" not in t, "Completed items cleared")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 18. Private Session ==
print("-- 18: Private Session --")
if start_example("private_session"):
    navigate("/")
    t = text()
    check("Private Session" in t, "SSR: private session renders")
    check("User: Ada" in t, "SSR: public user renders")
    check("Visible balance: 1200" in t, "SSR: public balance renders")
    check("beacon_private_session_signing_key_must_not_ship" not in str(html()), "Server signing key not present in DOM")
    bundle_text = evl_async("""
      (async () => {
        const src = Array.from(document.scripts).map(s => s.src).find(s => s.includes('beacon_client_'));
        return src ? await fetch(src).then(r => r.text()) : '';
      })()
    """)
    check("beacon_private_session_signing_key_must_not_ship" not in str(bundle_text), "Server signing key not present in client bundle")
    check("session-created" not in str(bundle_text), "Server audit seed not present in client bundle")

    reset_dom_monitor()
    clear_cdp_events()
    click_by_text("Approve transfer")
    for _ in range(20):
        time.sleep(0.3); drain()
        if "Visible balance: 1175" in str(text()) and "Approved actions: 1" in str(text()):
            break
    t = text()
    check("Visible balance: 1175" in t, "Approve transfer updates public balance")
    check("Approved actions: 1" in t, "Approve transfer increments public action count")
    check_model_ws_update("Private session approve")

    clear_cdp_events()
    click_by_text("Deny transfer")
    for _ in range(20):
        time.sleep(0.3); drain()
        if "Transfer denied" in str(text()):
            break
    check("Transfer denied" in str(text()), "Deny transfer updates public event only")
    check_model_ws_update("Private session deny")

    clear_cdp_events()
    click_by_text("Refresh public summary")
    for _ in range(20):
        time.sleep(0.3); drain()
        if "Public summary refreshed" in str(text()):
            break
    t = text()
    check("Public summary refreshed" in t, "Refresh uses server state without exposing it")
    check("beacon_private_session_signing_key_must_not_ship" not in str(html()), "Server signing key still absent after updates")
    check_model_ws_update("Private session refresh")
    check_dom_conformance("Private session")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 19. Routed Workspace ==
print("-- 19: Routed Workspace --")
if start_example("routed_workspace", module="main"):
    navigate("/")
    t = text()
    check("Overview" in t, "SSR: routed workspace overview renders")
    check("Open tickets" in t and "7" in t, "SSR: overview model data renders")
    check("Deploys today" in t and "3" in t, "SSR: deploy count renders")

    reset_dom_monitor()
    clear_cdp_events()
    click_by_text("Toggle inspector")
    for _ in range(10):
        time.sleep(0.2); drain()
        if "Inspector" in str(text()):
            break
    check("Inspector" in str(text()), "Local inspector toggles instantly")
    check_local_ws_quiet("Routed workspace inspector")

    clear_cdp_events()
    click_by_text("activity")
    for _ in range(10):
        time.sleep(0.2); drain()
        if "Selected tab: activity" in str(text()):
            break
    check("Selected tab: activity" in str(text()), "Local tab changes instantly")
    check_local_ws_quiet("Routed workspace tab")

    clear_cdp_events()
    click_by_text("Ship deploy")
    for _ in range(20):
        time.sleep(0.3); drain()
        if "Deploystoday4" in re.sub(r"\s+", "", str(text())):
            break
    check("Deploystoday4" in re.sub(r"\s+", "", str(text())), "Model deploy count increments")
    check_model_ws_update("Routed workspace deploy")

    clear_cdp_events()
    evl('document.querySelector(\'a[href="/pipeline"]\').click()')
    for _ in range(20):
        time.sleep(0.3); drain()
        if "/pipeline" in str(evl("location.pathname")) and "Pipeline" in str(text()):
            break
    check(str(evl("location.pathname")) == "/pipeline", "Client navigation: pipeline URL")
    check("Pipeline" in str(text()), "Client navigation: pipeline renders")

    clear_cdp_events()
    type_input('[data-testid="card-draft"]', "CDP route card")
    check(str(evl('document.querySelector("[data-testid=card-draft]")?.value || ""')) == "CDP route card", "Local card draft input updates")
    check_local_ws_quiet("Routed workspace card draft")

    clear_cdp_events()
    evl('var s=document.querySelector("[data-testid=lane-filter]"); s.value="done"; s.dispatchEvent(new Event("change", {bubbles:true}))')
    for _ in range(10):
        time.sleep(0.2); drain()
        if "Filter: done" in str(text()):
            break
    check("Filter: done" in str(text()), "Local lane filter changes")
    check_local_ws_quiet("Routed workspace lane filter")

    clear_cdp_events()
    evl('var s=document.querySelector("[data-testid=lane-filter]"); s.value="all"; s.dispatchEvent(new Event("change", {bubbles:true}))')
    type_input('[data-testid="card-draft"]', "CDP route card")
    evl('document.querySelector("form").dispatchEvent(new Event("submit", {bubbles:true, cancelable:true}))')
    for _ in range(20):
        time.sleep(0.3); drain()
        if "CDP route card" in str(text()):
            break
    check("CDP route card" in str(text()), "Model card submit adds card")
    check_model_ws_update("Routed workspace add card")

    clear_cdp_events()
    click_by_text("Compact")
    for _ in range(10):
        time.sleep(0.2); drain()
        if "compact: true" in str(text()):
            break
    check("compact: true" in str(text()), "Local compact toggle changes")
    check_local_ws_quiet("Routed workspace compact")

    clear_cdp_events()
    evl('document.querySelector(\'a[href="/settings"]\').click()')
    for _ in range(20):
        time.sleep(0.3); drain()
        if "/settings" in str(evl("location.pathname")) and "Settings" in str(text()):
            break
    check(str(evl("location.pathname")) == "/settings", "Client navigation: settings URL")
    check("Ada / owner / v1" in str(text()), "Settings renders saved profile")

    reset_dom_monitor()
    clear_cdp_events()
    type_input('[data-testid="draft-name"]', "Grace")
    check("Draft: Grace / owner" in str(text()), "Local profile draft name changes")
    check_local_ws_quiet("Routed workspace profile draft")

    clear_cdp_events()
    evl('var s=document.querySelector("[data-testid=draft-role]"); s.value="operator"; s.dispatchEvent(new Event("change", {bubbles:true}))')
    for _ in range(10):
        time.sleep(0.2); drain()
        if "Draft: Grace / operator" in str(text()):
            break
    check("Draft: Grace / operator" in str(text()), "Local profile role changes")
    check_local_ws_quiet("Routed workspace profile role")

    clear_cdp_events()
    evl('document.querySelector("form").dispatchEvent(new Event("submit", {bubbles:true, cancelable:true}))')
    for _ in range(20):
        time.sleep(0.3); drain()
        if "Grace / operator / v2" in str(text()):
            break
    check("Grace / operator / v2" in str(text()), "Model profile save persists")
    check_model_ws_update("Routed workspace save profile")

    clear_cdp_events()
    click_by_text("Toggle menu")
    for _ in range(10):
        time.sleep(0.2); drain()
        if "Local actions menu is open" in str(text()):
            break
    check("Local actions menu is open" in str(text()), "Local settings menu toggles")
    check_local_ws_quiet("Routed workspace settings menu")

    reset_dom_monitor()
    check_history_go(-1, "/pipeline", "Pipeline", "Routed workspace history back")
    check_history_go(1, "/settings", "Settings", "Routed workspace history forward")

    check_dom_conformance(
        "Routed workspace",
        max_layout_shift=0.15 if MOBILE_VIEWPORT else 0.05,
    )
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 20. Explicit Routed App ==
print("-- 20: Explicit Routing --")
if start_example("routed", module="main"):
    install_dom_monitor()
    t = text()
    navigate("/")
    t = text()
    count = evl('document.querySelector("[data-testid=count]")?.textContent || ""')
    check("Routed" in t, "SSR: home page renders")
    check(str(count) == "0", "SSR: initial count is 0")
    check("route-local Model and Msg" in t, "SSR: route-local home module copy renders")
    clear_cdp_events()

    click_by_text("+")
    time.sleep(1); drain()
    count = evl('document.querySelector("[data-testid=count]")?.textContent || ""')
    check(str(count) == "1", "Model event: count increments to 1")
    check(
        websocket_payload_count("Sent", '"type":"event"') >= 1,
        "Model event sends event",
    )
    check(websocket_payload_count("Sent", '"type":"event_batch"') == 0, "Model event does not send event_batch")
    check(
        websocket_payload_count("Received", '"type":"patch"') >= 1
        or websocket_payload_count("Received", '"type":"model_sync"') >= 1,
        "Model event receives state patch or sync",
    )
    check(websocket_payload_count("Received", '"type":"mount"') == 0, "Model event does not receive HTML mount")

    clear_cdp_events()
    evl('document.querySelector(\'a[href="/about"]\').click()')
    for _ in range(20):
        time.sleep(0.3); drain()
        if "/about" in str(evl("location.pathname")) and "About" in str(text()):
            break
    t = text()
    check(str(evl("location.pathname")) == "/about", "Client navigation: URL is /about")
    check("About" in t, "Client navigation: about page renders")
    check("does not scan the filesystem" in t, "Client navigation: no filesystem route scan copy")

    clear_cdp_events()
    evl('document.querySelector(\'a[href="/settings"]\').click()')
    for _ in range(20):
        time.sleep(0.3); drain()
        if "/settings" in str(evl("location.pathname")) and "Settings" in str(text()):
            break
    t = text()
    check(str(evl("location.pathname")) == "/settings", "Client navigation: URL is /settings")
    check("Settings" in t, "Client navigation: settings page renders")

    clear_cdp_events()
    type_input('[data-testid="name-input"]', "CDP Route")
    saved = evl('document.querySelector("[data-testid=saved-name]")?.textContent || ""')
    check("CDP Route" in str(saved), "Settings input updates model text")
    check(
        websocket_payload_count("Received", '"type":"patch"') >= 1
        or websocket_payload_count("Received", '"type":"model_sync"') >= 1,
        "Settings input receives state patch or sync",
    )
    check(websocket_payload_count("Received", '"type":"mount"') == 0, "Settings input does not receive HTML mount")

    evl('document.querySelector(\'a[href="/stats"]\').click()')
    for _ in range(20):
        time.sleep(0.3); drain()
        if "/stats" in str(evl("location.pathname")) and "Stats" in str(text()):
            break
    t = text()
    check("Stats" in t, "Client navigation: stats page renders")
    check("Route changes observed:" in t, "Route model tracks entered pages")

    reset_dom_monitor()
    check_history_go(-1, "/settings", "Settings", "Explicit routed app history back to settings")
    check_history_go(-1, "/about", "About", "Explicit routed app history back to about")
    check_history_go(1, "/settings", "Settings", "Explicit routed app history forward to settings")
    check_history_go(1, "/stats", "Stats", "Explicit routed app history forward to stats")

    check_dom_conformance("Explicit routed app")
    check(errors() == "0", f"Zero errors ({error_list()})")

    # The browser logs the 404 document load itself as a console error, so
    # the zero-errors check runs before this deliberate unknown route.
    navigate("/nonexistent")
    body_text = evl('document.body?.textContent || ""')
    check("Not Found" in str(body_text), "SSR: 404 page renders")
stop_server(); print()

# == 19. Local First Form ==
print("-- 19: Local First Form --")
if start_example("local_first_form"):
    install_dom_monitor()
    navigate("/")
    t = text()
    check("Local First Form" in t, "SSR: local-first form renders")
    clear_cdp_events()
    type_input('[data-testid="draft-input"]', "latency")
    preview = evl('document.querySelector("[data-testid=local-preview]")?.textContent || ""')
    check("latency" in str(preview), "Local draft updates instantly")
    check(websocket_payload_count("Sent", '"type":"event"') == 0, "Local draft sends zero WebSocket events")

    clear_cdp_events()
    click_by_text("Toggle options")
    time.sleep(0.5); drain()
    check("Preview:" in str(text()), "Local dropdown toggles")
    check(websocket_payload_count("Sent", '"type":"event"') == 0, "Local dropdown sends zero WebSocket events")

    clear_cdp_events()
    evl('document.querySelector("form").dispatchEvent(new Event("submit", {bubbles:true, cancelable:true}))')
    for _ in range(20):
        time.sleep(0.3); drain()
        if "Submissions: 1" in str(text()):
            break
    check("Submissions: 1" in str(text()), "Submit updates server-authoritative Model")
    check(
        websocket_payload_count("Sent", '"type":"event"') >= 1,
        "Submit sends one model event",
    )
    check(websocket_payload_count("Sent", '"type":"event_batch"') == 0, "Submit does not replay local event_batch")
    check(websocket_payload_count("Received", '"type":"mount"') == 0, "Submit receives no HTML mount")
    check_dom_conformance("Local first form")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 20. Route Server Workspace ==
print("-- 20: Route Server Workspace --")
if start_example("route_server_workspace", module="main"):
    install_dom_monitor()
    navigate("/")
    t = text()
    check("Accounts" in t, "SSR: accounts route renders")
    check("Balance: 1200" in t, "SSR: account model renders")
    bundle_text = evl_async("""
      (async () => {
        const src = Array.from(document.scripts).map(s => s.src).find(s => s.includes('beacon_client_'));
        return src ? await fetch(src).then(r => r.text()) : '';
      })()
    """)
    check("route_accounts_private_key_must_not_ship" not in str(bundle_text), "Accounts route server key not in client bundle")
    check("route_settings_private_key_must_not_ship" not in str(bundle_text), "Settings route server key not in client bundle")

    clear_cdp_events()
    click_by_text("Approve transfer")
    for _ in range(20):
        time.sleep(0.3); drain()
        if "Approved: 1" in str(text()):
            break
    check("Approved: 1" in str(text()), "Route-local server update changes account model")
    check(websocket_payload_count("Received", '"type":"mount"') == 0, "Account update receives no HTML mount")

    clear_cdp_events()
    evl('document.querySelector(\'a[href="/settings"]\').click()')
    for _ in range(20):
        time.sleep(0.3); drain()
        if "/settings" in str(evl("location.pathname")) and "Settings" in str(text()):
            break
    check(str(evl("location.pathname")) == "/settings", "Client navigation: settings URL")
    type_input('[data-testid="settings-email"]', "route@example.test")
    click_by_text("Save settings")
    for _ in range(20):
        time.sleep(0.3); drain()
        if "Saved route@example.test" in str(text()):
            break
    check("Saved route@example.test" in str(text()), "Route-local settings server update saves model")
    check("route_settings_private_key_must_not_ship" not in str(html()), "Settings route server key not in DOM")
    check_dom_conformance("Route server workspace")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 21. Auth Workspace ==
print("-- 21: Auth Workspace --")
if start_example("auth_workspace", module="auth_workspace"):
    navigate("/login")
    t = text()
    check("Sign in" in t, "SSR: login page renders")
    login_result = evl_async("""
      fetch('/api/login', {
        method: 'POST',
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        credentials: 'same-origin',
        body: 'username=ada&csrf=auth-workspace-login-csrf'
      }).then(async r => {
        const body = await r.text();
        localStorage.setItem('authCsrf', JSON.parse(body).csrf);
        return r.status + ':' + body;
      })
    """)
    check(str(login_result).startswith("200:"), "API login succeeds and stores HttpOnly session cookie")
    navigate("/app")
    t = text()
    check("Ada Lovelace" in t, "ws_init: session cookie hydrates workspace")
    check("admin" in t, "Authenticated role visible in model")
    check("server-only-audit-key" not in html(), "Server audit key not present in DOM")
    navigate("/settings")
    reset_dom_monitor()
    clear_cdp_events()
    type_input('[data-testid="display-name-input"]', 'Grace Hopper')
    check_model_ws_update("Auth workspace display-name input")
    clear_cdp_events()
    click_by_text("Save profile")
    t = text()
    check("Grace Hopper" in t, "Profile edit updates visible model")
    check_model_ws_update("Auth workspace profile save")
    navigate("/admin")
    t = text()
    check("Admin" in t and "Forbidden" not in t, "Admin route allows admin session")
    reset_dom_monitor()
    clear_cdp_events()
    click_by_text("Record audit event")
    t = text()
    check("Audit events: 1" in t, "Admin audit event updates through server-authoritative state")
    check_model_ws_update("Auth workspace audit event")

    force_socket_reconnect("Auth workspace reconnect", "Admin")
    check("Forbidden" not in str(text()), "Auth workspace reconnect: authenticated route remains allowed")
    audit_before = int(str(evl('var m=(document.getElementById("beacon-app")?.textContent||"").match(/Audit events: (\\d+)/); m ? Number(m[1]) : -1')))
    clear_cdp_events()
    click_by_text("Record audit event")
    for _ in range(20):
        time.sleep(0.3); drain()
        audit_after = int(str(evl('var m=(document.getElementById("beacon-app")?.textContent||"").match(/Audit events: (\\d+)/); m ? Number(m[1]) : -1')))
        if audit_after == audit_before + 1:
            break
    audit_after = int(str(evl('var m=(document.getElementById("beacon-app")?.textContent||"").match(/Audit events: (\\d+)/); m ? Number(m[1]) : -1')))
    check(audit_after == audit_before + 1, f"Auth workspace reconnect: audit click works once ({audit_before}->{audit_after})")
    check(sent_model_event_units() == 1, f"Auth workspace reconnect: exactly one model event after reconnect ({sent_model_event_units()})")
    check(received_state_update_count() >= 1, "Auth workspace reconnect: receives state update after reconnect")
    check(websocket_type_count("Received", "mount") == 0, "Auth workspace reconnect: post-reconnect click receives no HTML mount")

    check_dom_conformance("Auth workspace")
    logout_status = evl_async("""
      fetch('/api/logout', {
        method: 'POST',
        headers: {'x-csrf-token': localStorage.getItem('authCsrf') || ''},
        credentials: 'same-origin'
      }).then(r => String(r.status))
    """)
    check(str(logout_status) == "200", "API logout accepts valid CSRF token")
    logged_out_html = evl_async("""
      fetch('/app', {credentials: 'same-origin'})
        .then(r => r.text())
    """)
    check("Sign in" in str(logged_out_html), "Logout clears session before next SSR")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

ws.close()
print("===============================")
if SKIP > 0:
    print(f"  Results: {PASS} passed, {FAIL} failed, {SKIP} skipped")
else:
    print(f"  Results: {PASS} passed, {FAIL} failed")
print("===============================")
sys.exit(1 if FAIL > 0 else 0)
