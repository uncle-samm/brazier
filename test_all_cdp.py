#!/usr/bin/env python3
"""CDP test suite for Brazier examples.
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

Waiting (the Playwright auto-wait model)
---------------------------------------
Nothing sleeps for a fixed time and hopes the page has settled. After an
action, a test waits for the condition it asserts: `wait_until` re-checks a
predicate every RETRY_SECONDS, reading CDP events between checks, and gives
up at a deadline (BRAZIER_CDP_WAIT_SECONDS, default 10). A passing check
returns as soon as the condition holds, so the deadline can be generous for
a loaded CI machine. A check that misses its deadline fails, naming what it
waited for.

A check that the browser sent NO model event (local-only messages) waits,
after the local update is visible, for the client's outbound queue to be
empty with no paced send scheduled and no debounced message waiting
(`window.__brazierOutboundPendingForTest`, installed by the test hooks),
then takes a CDP barrier so every frame the
page wrote has been recorded. Pong's "frozen while paused" check is the one
deliberate time window: holding still for many ticks is the thing under
test.

Exit status: 0 when every check passed, 1 when any check failed (an example
that does not start counts as a failure).
"""
import argparse
import atexit
import collections
import json
import os
import re
import secrets
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request

import websocket

# The BRAZIER_* variables were named BEACON_* until the package was renamed
# to brazier (2026-11-04). An old name is refused, never read, so a stale
# setting cannot let the run go ahead with a default instead.
RENAMED_ENV_PREFIX = "BEACON_"
renamed_env = sorted(name for name in os.environ if name.startswith(RENAMED_ENV_PREFIX))
if renamed_env:
    for name in renamed_env:
        new_name = "BRAZIER_" + name[len(RENAMED_ENV_PREFIX):]
        print(f"{name} is set, but it is no longer read: set {new_name} instead", file=sys.stderr)
    sys.exit(1)

parser = argparse.ArgumentParser(description="Brazier CDP tests")
parser.add_argument("filter", nargs="?", default=None, help="Run only tests matching this name")
parser.add_argument("--canonical", action="store_true", help="Run the canonical conformance examples")
parser.add_argument("--shard", default=os.environ.get("BRAZIER_CDP_SHARD"), help="Run shard INDEX/TOTAL, 1-based")
parser.add_argument(
    "--viewport",
    choices=("desktop", "mobile"),
    default=os.environ.get("BRAZIER_CDP_VIEWPORT", "desktop"),
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
    "timeline",
    "rows",
]

CDP_PORT = int(os.environ.get("CDP_PORT", "9223"))
BRAZIER_PORT = int(os.environ.get("BRAZIER_PORT", "8080"))
SERVER_START_TIMEOUT_SECONDS = int(os.environ.get("BRAZIER_CDP_SERVER_TIMEOUT", "90"))
# Every example reads its required secret key from SECRET_KEY. The run
# makes one test key, the same for every example and restart in the run,
# so tokens signed before a restart still verify after it.
EXAMPLE_SECRET_KEY = secrets.token_urlsafe(48)
# The first brazier/build of an example compiles Brazier and its deps.
BUILD_TIMEOUT_SECONDS = int(os.environ.get("BRAZIER_CDP_BUILD_TIMEOUT", "300"))
# The deadline for a condition a test expects. A passing check returns as
# soon as the condition holds; only a failing one waits this long.
WAIT_SECONDS = float(os.environ.get("BRAZIER_CDP_WAIT_SECONDS", "10"))
# How long wait_until reads CDP events between two checks of a condition.
RETRY_SECONDS = 0.05
# Lines of server output kept for a failure report.
SERVER_LOG_LINES = 40
ROOT = os.path.dirname(os.path.abspath(__file__))
PASS = 0
FAIL = 0
SKIP = 0
server_proc = None
server_name = None
server_output = None
server_reader = None
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
    "timeline",
}
CONTRACT_REPORTS = {}
# Examples whose view has no event handlers: the browser sends no messages.
NO_HANDLER_EXAMPLES = {"dashboard"}
STARTED_LINE = re.compile(r"Brazier application started \((?:supervised|unsupervised)\) on port (\d+)")

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
        cdp_checked("Emulation.setDeviceMetricsOverride", {
            "width": 390,
            "height": 844,
            "deviceScaleFactor": 3,
            "mobile": True,
            "screenWidth": 390,
            "screenHeight": 844,
        })
        cdp_checked("Emulation.setTouchEmulationEnabled", {"enabled": True, "maxTouchPoints": 5})
        cdp_checked("Network.setUserAgentOverride", {
            "userAgent": (
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 "
                "Mobile/15E148 Safari/604.1"
            )
        })
    else:
        cdp_checked("Emulation.setDeviceMetricsOverride", {
            "width": 1280,
            "height": 900,
            "deviceScaleFactor": 1,
            "mobile": False,
            "screenWidth": 1280,
            "screenHeight": 900,
        })
        cdp_checked("Emulation.setTouchEmulationEnabled", {"enabled": False})

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
            # The examples' pages carry an inline icon, but pages Brazier
            # renders without the app's head (error pages) do not, and on
            # those Chrome requests /favicon.ico on its own (not the page or
            # Brazier), so that one 404 is not an app error. It is still
            # logged in verbose mode.
            if (entry.get("source") == "network"
                    and str(entry.get("url", "")).endswith("/favicon.ico")):
                vlog(f"Ignoring browser favicon request: {entry.get('text')}")
            elif entry.get("level") == "error":
                message = str(entry.get("text", "Browser log entry"))
                if entry.get("url"):
                    message += f" [{entry.get('url')}]"
                browser_errors.append(message)
    elif "id" in data:
        pending_responses[data["id"]] = data

def cdp(method, params=None, timeout=8, retry=True):
    """Send one CDP command and return its response, recording every event
    that arrives first. Returns None (and says so) if no response arrives
    within `timeout`; a closed CDP connection is reconnected once, then
    raises."""
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
    deadline = time.time() + timeout
    while my_id not in pending_responses:
        remaining = deadline - time.time()
        if remaining <= 0:
            print(f"  * CDP {method} got no response within {timeout} s")
            return None
        ws.settimeout(remaining)
        try:
            raw = ws.recv()
        except websocket.WebSocketTimeoutException:
            continue
        record_cdp_message(json.loads(raw))
    return pending_responses.pop(my_id)

def reconnect_cdp():
    global ws, pending_responses, DOM_MONITOR_INSTALLED
    if ws is not None:
        try:
            ws.close()
        except websocket.WebSocketException as exc:
            vlog(f"Closing the old CDP connection failed: {exc}")
    ws = websocket.create_connection(get_tab(), timeout=10, suppress_origin=True)
    pending_responses = {}
    DOM_MONITOR_INSTALLED = False
    # Without these domains the suite records no console errors, no
    # WebSocket frames and no page events, and every check that reads them
    # would pass on nothing. So a failed enable stops the run.
    cdp_checked("Runtime.enable", retry=False)
    cdp_checked("Log.enable", retry=False)
    cdp_checked("Network.enable", retry=False)
    cdp_checked("Page.enable", retry=False)
    configure_viewport()

class CdpError(Exception):
    """A CDP command got no response, a protocol error, or (for
    Runtime.evaluate) a JavaScript exception or a value that is not one."""

class CdpContextGone(CdpError):
    """Runtime.evaluate ran while the page's JavaScript context was being
    replaced by a navigation. Only a polling wait may retry this."""

# The protocol errors Chrome answers Runtime.evaluate with while a
# navigation replaces the page's execution context.
CONTEXT_GONE_MESSAGES = (
    "Execution context was destroyed",
    "Cannot find context with specified id",
)

def cdp_checked(method, params=None, timeout=8, retry=True):
    """cdp(), but raise CdpError if there is no response or the response is
    a protocol error."""
    r = cdp(method, params, timeout, retry)
    if r is None:
        raise CdpError(f"CDP {method}: no response within {timeout} s")
    if "error" in r:
        message = str(r["error"].get("message"))
        if any(gone in message for gone in CONTEXT_GONE_MESSAGES):
            raise CdpContextGone(f"CDP {method}: {message}")
        raise CdpError(f"CDP {method}: protocol error {r['error']}")
    return r

def evaluation_value(r, expr):
    """The value a Runtime.evaluate response `r` for `expr` carries. Raises
    CdpError if the script threw, or if the result is not a JSON value (an
    object or function, NaN, Infinity, a BigInt): a check comparing with it
    would compare against something the page never returned. `undefined`
    is None."""
    result = r.get("result", {})
    if "exceptionDetails" in result:
        details = result["exceptionDetails"]
        exception = details.get("exception", {})
        description = exception.get("description") or details.get("text")
        raise CdpError(f"evaluate {expr[:120]!r} threw: {description}")
    remote = result.get("result", {})
    if remote.get("type") == "undefined":
        return None
    if "value" not in remote:
        raise CdpError(f"evaluate {expr[:120]!r} returned no JSON value: {remote}")
    return remote["value"]

def evl(expr):
    return evaluation_value(cdp_checked("Runtime.evaluate", {"expression": expr}), expr)

def evl_async(expr):
    return evaluation_value(
        cdp_checked(
            "Runtime.evaluate", {"expression": expr, "awaitPromise": True}, timeout=12
        ),
        expr,
    )

def pump(seconds):
    """Record the CDP events that arrive within `seconds`. Bounded by time,
    not by quiet: a 60 Hz game loop (pong) emits a CDP network event every
    frame, so "read until quiet" would never return."""
    deadline = time.time() + seconds
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            return
        ws.settimeout(remaining)
        try:
            raw = ws.recv()
        except websocket.WebSocketTimeoutException:
            return
        record_cdp_message(json.loads(raw))

def barrier():
    """An evaluate round-trip: every event Chrome sent before answering it
    has been recorded."""
    evl("0")

OUTBOUND_PENDING_JS = (
    'JSON.stringify(typeof window.__brazierOutboundPendingForTest === "function"'
    ' ? window.__brazierOutboundPendingForTest() : "missing")'
)
OUTBOUND_DRAINED = json.dumps(
    {"queued": 0, "scheduled": False, "debounced": 0}, separators=(",", ":")
)

def wait_outbound_drained(msg):
    """Wait until the client owes the server nothing: its paced queue is
    empty, no paced send is scheduled and no debounced message waits for its
    timer. Then take a barrier, so the CDP
    events for every frame the page wrote before that are recorded. Only for
    checks that something did NOT happen (no model event for a local
    message), and only after the local update is visible: a model event the
    update caused is then written, queued or scheduled, never still to come."""
    ok = wait_until(lambda: evl(OUTBOUND_PENDING_JS) == OUTBOUND_DRAINED)
    check(
        ok,
        f"{msg}: client outbound queue drains"
        + ("" if ok else f" (pending: {evl(OUTBOUND_PENDING_JS)})"),
    )
    barrier()
    return ok

def wait_until(predicate, timeout=None):
    """Re-check `predicate` every RETRY_SECONDS (recording CDP events in
    between) until it holds or the deadline passes. Returns whether it held.
    A predicate that evaluates while a navigation replaces the page's
    context (CdpContextGone) has not held yet; every other CdpError
    propagates."""
    deadline = time.time() + (WAIT_SECONDS if timeout is None else timeout)
    while True:
        try:
            if predicate():
                return True
        except CdpContextGone as exc:
            vlog(f"Waiting through a navigation: {exc}")
        if time.time() >= deadline:
            return False
        pump(RETRY_SECONDS)

def js_true(value):
    return value is True or str(value).lower() == "true"

def wait_for_js(predicate_expr, timeout=None):
    return wait_until(lambda: js_true(evl(predicate_expr)), timeout)

def expect(predicate, msg, timeout=None):
    """check() that waits for `predicate` first."""
    ok = wait_until(predicate, timeout)
    check(ok, msg)
    return ok

def expect_js(predicate_expr, msg, timeout=None):
    return expect(lambda: js_true(evl(predicate_expr)), msg, timeout)

def expect_text(fragment, msg):
    ok = wait_until(lambda: fragment in str(text()))
    check(ok, msg if ok else f"{msg} (waited for {fragment!r}; text: {str(text())[:160]!r})")
    return ok

def expect_no_text(fragment, msg):
    ok = wait_until(lambda: fragment not in str(text()))
    check(ok, msg if ok else f"{msg} (waited for {fragment!r} to go; text: {str(text())[:160]!r})")
    return ok

def expect_value(expr, expected, msg):
    """Wait until the JS expression `expr` evaluates to the string `expected`."""
    ok = wait_until(lambda: str(evl(expr)) == expected)
    check(ok, msg if ok else f"{msg} (expected {expected!r}, got {str(evl(expr))!r})")
    return ok

def clear_cdp_events():
    global cdp_events
    barrier()
    cdp_events = []

def clear_browser_errors():
    global browser_errors
    browser_errors = []
    evl('window.__e=[]; "ok"')

def websocket_payloads():
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
    return sum(1 for event in cdp_events if event.get("method") == method_name)

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

def console_messages(level, fragment):
    """Console messages of `level` ("log", "warning", "error", ...) holding
    `fragment`, from the CDP events since clear_cdp_events. They outlive the
    document that logged them, so a check can read what a page said before
    the browser loaded another."""
    found = []
    for event in cdp_events:
        if event.get("method") != "Runtime.consoleAPICalled":
            continue
        params = event.get("params", {})
        if params.get("type") != level:
            continue
        message = " ".join(str(arg.get("value", arg.get("description", ""))) for arg in params.get("args", []))
        if fragment in message:
            found.append(message)
    return found

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

def check_model_ws_update(msg, events=None):
    """The action sent a model event and the server answered with state, not
    HTML. `events` pins the exact number of model events sent."""
    expect(lambda: sent_event_count() >= 1, f"{msg}: sends model event")
    expect(lambda: received_state_update_count() >= 1, f"{msg}: receives patch or model_sync")
    check(websocket_type_count("Received", "mount") == 0, f"{msg}: receives no HTML mount")
    if events is not None:
        sent = sent_model_event_units()
        check(sent == events, f"{msg}: sends exactly {events} model event(s) ({sent})")

def check_local_ws_quiet(msg):
    """Call after the local update is visible. See wait_outbound_drained."""
    wait_outbound_drained(msg)
    check(sent_event_count() == 0, f"{msg}: sends zero model events ({sent_model_event_units()})")
    check(websocket_type_count("Received", "mount") == 0, f"{msg}: receives no HTML mount")

APP_READY_JS = (
    '(document.getElementById("brazier-app")?.textContent || "").length > 5'
    ' && typeof window.__brazierWsState === "function" && window.__brazierWsState() === 1'
    ' && typeof window.__brazierConnectionReady === "function"'
    ' && window.__brazierConnectionReady() === true'
)

def navigate(path="/", expect_app=True):
    """Load `path` in a fresh document and wait until it is ready: for an
    app, its root has content and its WebSocket is open and joined; for
    another page (expect_app=False), the document has loaded. Fails loudly
    if it never gets there."""
    clear_browser_errors()
    install_dom_monitor()
    cdp_checked("Network.setCacheDisabled", {"cacheDisabled": True})
    # The old document keeps this marker; a fresh one has none, so the wait
    # below cannot be satisfied by the page being navigated away from.
    marker = json.dumps(f"nav-{time.time_ns()}")
    evl(f"window.__brazierCdpNav = {marker}; 0")
    r = cdp("Page.navigate", {"url": f"http://localhost:{BRAZIER_PORT}{path}"})
    if r is None or "errorText" in r.get("result", {}):
        reason = "no response" if r is None else r["result"]["errorText"]
        check(False, f"navigate {path}: browser starts the navigation ({reason})")
        return False
    fresh = f'window.__brazierCdpNav !== {marker} && document.readyState === "complete"'
    if expect_app:
        ready = wait_for_js(f"{fresh} && {APP_READY_JS}")
    else:
        ready = wait_for_js(f"{fresh} && location.pathname === {json.dumps(path)}")
    if not ready:
        state = evl(
            "JSON.stringify({path: location.pathname, ready: document.readyState, "
            "ws: window.__brazierWsState ? window.__brazierWsState() : -1, "
            "joined: window.__brazierConnectionReady ? window.__brazierConnectionReady() : null, "
            'text: (document.getElementById("brazier-app")?.textContent || "NO APP").slice(0, 80)})'
        )
        check(False, f"navigate {path}: page becomes ready within {WAIT_SECONDS} s ({state})")
        return False
    return True

def text():
    return evl('document.getElementById("brazier-app")?.textContent ?? "NO APP"')

def html():
    return evl('document.getElementById("brazier-app")?.innerHTML ?? "NO APP"')

def squashed_text():
    return re.sub(r"\s+", "", str(text()))

def js_click(find_expr, what):
    """Click the element `find_expr` evaluates to. Fails loudly if there is
    none. Only clicks: the caller waits for the outcome it asserts."""
    result = evl(
        f"(function(){{var el = {find_expr}; if (!el) return \"not found\"; el.click(); return \"clicked\";}})()"
    )
    if result != "clicked":
        check(False, f"{what} exists to click ({result})")
        return False
    return True

def click(sel):
    return js_click(f"document.querySelector({json.dumps(sel)})", f"element {sel!r}")

def click_label(label):
    """Click the element whose aria-label is exactly `label`."""
    return js_click(
        f"document.querySelector('[aria-label=' + JSON.stringify({json.dumps(label)}) + ']')",
        f"element labelled {label!r}",
    )

def click_by_text(button_text):
    """Click the first handled element whose text contains `button_text`."""
    text_js = json.dumps(button_text)
    return js_click(
        'Array.from(document.querySelectorAll("[data-brazier-on-click]"))'
        f".find(function(b){{return b.textContent.includes({text_js})}})",
        f"clickable containing {button_text!r}",
    )

def click_button(label, nth=0):
    """Click the nth handled button whose trimmed text is exactly `label`.

    Handler ids are positional and internal, so tests find buttons by text.
    """
    label_js = json.dumps(label)
    return js_click(
        'Array.from(document.querySelectorAll("button[data-brazier-on-click]"))'
        f".filter(function(b){{return b.textContent.trim()==={label_js}}})[{nth}]",
        f"button {label!r} #{nth}",
    )

def submit_by_text(button_text):
    """Click the submit button whose text contains `button_text`.

    The click submits its form natively, so the form's `on_submit` handler runs.
    """
    text_js = json.dumps(button_text)
    return js_click(
        'Array.from(document.querySelectorAll("form[data-brazier-on-submit] button[type=submit]"))'
        f".find(function(b){{return b.textContent.includes({text_js})}})",
        f"submit button {button_text!r}",
    )

def submit_form(sel="form"):
    """Dispatch a cancelable submit on the form `sel`."""
    return js_click(
        f"(function(){{var f = document.querySelector({json.dumps(sel)}); "
        "return f && {click: function(){ f.dispatchEvent(new Event(\"submit\", {bubbles:true, cancelable:true})); }}; })()",
        f"form {sel!r}",
    )

def type_input(sel, value):
    """Set the value of the input `sel` and dispatch `input`. Fails loudly if
    there is no such input; the caller waits for the outcome."""
    result = evl(
        f"(function(){{var el = document.querySelector({json.dumps(sel)}); "
        "if (!el) return \"not found\"; "
        f"el.value = {json.dumps(value)}; "
        'el.dispatchEvent(new Event("input", {bubbles:true})); return "typed";})()'
    )
    if result != "typed":
        check(False, f"input {sel!r} exists to type into ({result})")
        return False
    return True

def select_option(sel, value):
    """Set the value of the select `sel` and dispatch `change`."""
    result = evl(
        f"(function(){{var el = document.querySelector({json.dumps(sel)}); "
        "if (!el) return \"not found\"; "
        f"el.value = {json.dumps(value)}; "
        'el.dispatchEvent(new Event("change", {bubbles:true})); return "changed";})()'
    )
    if result != "changed":
        check(False, f"select {sel!r} exists to change ({result})")
        return False
    return True

def count_js(expr):
    """Evaluate a JS expression that yields an integer."""
    value = evl(expr)
    if not isinstance(value, int):
        check(False, f"integer from {expr[:60]!r} (got {value!r})")
        return -1
    return value

def errors():
    dom_errors = evl("window.__e ? window.__e.length : 0")
    if not isinstance(dom_errors, int):
        # Unreadable counts as an error: the zero-errors check must not pass.
        browser_errors.append(f"window.__e unreadable ({dom_errors})")
        dom_errors = 0
    return str(dom_errors + len(browser_errors))

def error_list():
    dom_list = evl("window.__e ? window.__e.join('; ') : ''")
    all_errors = [e for e in [str(dom_list)] if e and e != "none"] + browser_errors
    return "; ".join(all_errors) if all_errors else "none"

def page_at_js(path, heading):
    """True once the URL path is `path` and the app shows that page: its one
    h1 is exactly `heading`. A text fragment is not enough, since the nav of
    every page names every page; the h1 is the page's own."""
    return (
        f"(location.pathname === {json.dumps(path)} && (function(){{"
        'var h = document.querySelectorAll("#brazier-app h1");'
        f"return h.length === 1 && h[0].textContent === {json.dumps(heading)};}})())"
    )

PAGE_STATE_JS = (
    "JSON.stringify({path: location.pathname, "
    'h1: Array.from(document.querySelectorAll("#brazier-app h1")).map(function(h){ return h.textContent; }), '
    'text: (document.getElementById("brazier-app")?.textContent || "").slice(0, 120)})'
)

def expect_path_and_heading(path, heading, msg):
    """Wait, up to WAIT_SECONDS, until the URL path is `path` and the app
    renders the page whose one h1 is `heading` (page_at_js). On a timeout
    the failure names what was awaited and what the page showed."""
    ok = wait_for_js(page_at_js(path, heading))
    check(
        ok,
        msg if ok else (
            f"{msg} (waited {WAIT_SECONDS}s for path {path!r} with the one h1 {heading!r}; "
            f"saw {evl(PAGE_STATE_JS)})"
        ),
    )
    return ok

def check_history_go(delta, path, heading, label):
    clear_cdp_events()
    before = str(evl("location.pathname"))
    check(before != path, f"{label}: starts away from {path} (at {before})")
    went = evl(f'history.go({delta}); "ok"')
    check(went == "ok", f"{label}: history.go({delta}) evaluated ({went})")
    restored = wait_for_js(page_at_js(path, heading))
    check(
        restored,
        f"{label}: URL and view restore {path}"
        + ("" if restored else (
            f" (from {before}; waited {WAIT_SECONDS}s for the one h1 {heading!r}; "
            f"saw {evl(PAGE_STATE_JS)}, history.length {evl('history.length')})"
        )),
    )
    expect(lambda: websocket_type_count("Sent", "navigate") >= 1, f"{label}: popstate sends navigate")
    expect(
        lambda: websocket_type_count("Received", "mount") >= 1 or received_state_update_count() >= 1,
        f"{label}: popstate receives route state",
    )

def force_socket_reconnect(label, expected_text):
    clear_cdp_events()
    before_state = evl('window.__brazierCloseSocketForTest ? window.__brazierCloseSocketForTest() : "missing"')
    check(str(before_state) != "missing", f"{label}: test socket close hook is available")
    check(str(before_state) == "1", f"{label}: socket was open before forced close (state={before_state})")
    expect(lambda: cdp_method_count("Network.webSocketClosed") > 0, f"{label}: browser reports WebSocket close")
    # The client backs off before reconnecting, so this wait is longer.
    reconnected = wait_for_js(
        "window.__brazierWsState && window.__brazierWsState() === 1"
        " && window.__brazierConnectionReady && window.__brazierConnectionReady() === true"
        f' && (document.getElementById("brazier-app")?.textContent || "").includes({json.dumps(expected_text)})',
        timeout=2 * WAIT_SECONDS,
    )
    check(reconnected, f"{label}: socket reconnects and app is ready")
    expect(lambda: websocket_type_count("Sent", "join") >= 1, f"{label}: reconnect sends join")
    expect(
        lambda: websocket_type_count("Received", "mount") >= 1
        or websocket_type_count("Received", "model_sync") >= 1,
        f"{label}: reconnect receives fresh server state",
    )

def install_dom_monitor():
    global DOM_MONITOR_INSTALLED
    if DOM_MONITOR_INSTALLED:
        return
    script = r"""
(() => {
  window.__BRAZIER_ENABLE_TEST_HOOKS = true;
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

  window.__brazierMonitor = freshMonitor();

  function recordSample() {
    const app = document.getElementById("brazier-app");
    if (!app) return;
    const textLength = (app.textContent || "").trim().length;
    if (textLength > 0) window.__brazierMonitor.sawContent = true;
    if (window.__brazierMonitor.sawContent && textLength === 0) {
      window.__brazierMonitor.emptyAfterContent += 1;
    }
    window.__brazierMonitor.bodySamples.push({
      t: performance.now(),
      textLength,
      htmlLength: app.innerHTML.length
    });
  }

  function setupObserver() {
    const app = document.getElementById("brazier-app");
    if (!app || app.__brazierMonitorAttached) return;
    app.__brazierMonitorAttached = true;
    new MutationObserver((records) => {
      recordSample();
      window.__brazierMonitor.mutations.push({
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

  window.__brazierResetMonitor = function() {
    window.__brazierMonitor = freshMonitor();
    recordSample();
    setupObserver();
  };

  window.__brazierMonitorSummary = function(bucketMs) {
    const m = window.__brazierMonitor || freshMonitor();
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
            window.__brazierMonitor.layoutShifts.push(entry.value);
            for (const source of entry.sources || []) {
              window.__brazierMonitor.layoutShiftSources.push(describeShiftSource(source));
            }
          }
        }
      }).observe({type: "layout-shift", buffered: true});
    } catch (err) {
      window.__e.push("layout-shift observer unavailable: " + err);
    }
  }

  document.addEventListener("DOMContentLoaded", setupObserver);
  setTimeout(setupObserver, 0);
})();
"""
    cdp_checked("Page.addScriptToEvaluateOnNewDocument", {"source": script})
    DOM_MONITOR_INSTALLED = True

def reset_dom_monitor():
    evl('window.__brazierResetMonitor ? (window.__brazierResetMonitor(), "ok") : "missing"')

def mutation_bucket_summary(bucket_ms=100):
    return evl("""
(() => {
  if (window.__brazierMonitorSummary) return window.__brazierMonitorSummary(BUCKET_MS);
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

# --- Example server lifecycle ---

def port_accepts_connections(port):
    try:
        with socket.create_connection(("localhost", port), timeout=1):
            return True
    except ConnectionRefusedError:
        return False
    except OSError as exc:
        vlog(f"Port {port} probe: {exc}")
        return False

def read_server_output(proc, output, started, name):
    """Keep the server's stdout drained for its whole life (a full pipe
    would block the server's logger), remember the last lines, and signal
    `started` on the startup line or at EOF."""
    for raw in iter(proc.stdout.readline, b""):
        line = raw.decode("utf-8", errors="replace").rstrip()
        output.append(line)
        if VERBOSE and line.strip():
            print(f"    [server {name}] {line}")
        if not started.is_set() and STARTED_LINE.search(line):
            started.set()
    proc.stdout.close()
    started.set()

def kill_server_group(proc):
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        proc.wait(timeout=5)
    except ProcessLookupError:
        vlog(f"Server group {proc.pid} already gone")

def report_server_failure(name, why):
    print(f"  * {name}: {why}. Last {SERVER_LOG_LINES} lines of its output:")
    for line in list(server_output or [])[-SERVER_LOG_LINES:]:
        print(f"    | {line}")

def build_example(name, directory):
    """Run the Brazier build (`gleam run -m brazier/build`) for the example:
    the server codec, the client bundle and `build/brazier_contract.json`,
    which report_contract checks. The build is deterministic, so it
    rewrites the committed bundle unchanged unless the bundle is stale."""
    vlog(f"Building {name} with brazier/build")
    try:
        built = subprocess.run(
            ["gleam", "run", "-m", "brazier/build"],
            cwd=directory, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=BUILD_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        output = (exc.output or b"").decode("utf-8", errors="replace").splitlines()
        print(f"  * {name}: brazier/build did not finish within {BUILD_TIMEOUT_SECONDS} s. Last {SERVER_LOG_LINES} lines:")
        for line in output[-SERVER_LOG_LINES:]:
            print(f"    | {line}")
        check(False, f"{name}: brazier/build finishes")
        return False
    if built.returncode != 0:
        output = built.stdout.decode("utf-8", errors="replace").splitlines()
        print(f"  * {name}: brazier/build exited with status {built.returncode}. Last {SERVER_LOG_LINES} lines:")
        for line in output[-SERVER_LOG_LINES:]:
            print(f"    | {line}")
        check(False, f"{name}: brazier/build succeeds")
        return False
    return True

def reset_tab_history(name):
    """Give each example a tab with an empty session history. The tab is
    shared by every example, and once its history reaches Chrome's cap of 50
    entries, history.go(-1) across pushState entries can land on an evicted
    entry's about:blank instead of the previous route, so the history checks
    of an example late in the run would depend on how many pages the
    examples before it loaded."""
    if ws is None:
        return True
    r = cdp("Page.resetNavigationHistory")
    if r is None or "error" in r:
        reason = "no response" if r is None else r["error"].get("message")
        check(False, f"{name}: browser resets the tab history before start ({reason})")
        return False
    return True

def start_example(name, module=None):
    """Start `examples/<name>` with `gleam run -m <module>` and wait for its
    startup log line. Fails loudly, naming the example and printing its last
    output, if it exits or does not start within SERVER_START_TIMEOUT_SECONDS."""
    global server_proc, server_name, server_output, server_reader, SKIP
    if not should_run(name):
        SKIP += 1
        return False
    if not stop_server():
        return False
    if not reset_tab_history(name):
        return False
    if port_accepts_connections(BRAZIER_PORT):
        check(False, f"{name}: port {BRAZIER_PORT} is free before start (another server, or a concurrent CDP run, holds it)")
        return False
    d = os.path.join(ROOT, "examples", name)
    if not build_example(name, d):
        return False
    mod = module or name
    vlog(f"Starting {name} (module={mod}) in {d}")
    server_name = name
    server_output = collections.deque(maxlen=200)
    started = threading.Event()
    server_proc = subprocess.Popen(
        ["gleam", "run", "-m", mod],
        cwd=d, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        env={**os.environ, "SECRET_KEY": EXAMPLE_SECRET_KEY},
        start_new_session=True,
    )
    server_reader = threading.Thread(
        target=read_server_output,
        args=(server_proc, server_output, started, name),
        daemon=True,
    )
    server_reader.start()
    signalled = started.wait(SERVER_START_TIMEOUT_SECONDS)
    line = next((l for l in reversed(server_output) if STARTED_LINE.search(l)), None)
    if line is None:
        if not signalled:
            why = f"no startup line within {SERVER_START_TIMEOUT_SECONDS} s"
        else:
            why = f"exited with status {server_proc.wait(timeout=5)} before starting"
        report_server_failure(name, why)
        stop_server()
        check(False, f"{name}: server starts ({why})")
        return False
    port = int(STARTED_LINE.search(line).group(1))
    if port != BRAZIER_PORT:
        report_server_failure(name, f"started on port {port}, not {BRAZIER_PORT}")
        stop_server()
        check(False, f"{name}: server listens on port {BRAZIER_PORT} (got {port})")
        return False
    report_contract(name, d)
    vlog("Server ready")
    return True

def report_contract(name, directory):
    path = os.path.join(directory, "build", "brazier_contract.json")
    if not os.path.exists(path):
        check(False, f"{name}: generated contract report exists")
        return
    try:
        with open(path, "r", encoding="utf-8") as fh:
            report = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
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
        f"{name}: only brazier.simple compiles its update for the browser",
    )
    if name in NO_HANDLER_EXAMPLES:
        check(client_messages == [], f"{name}: generated contract lists no browser messages (view has no handlers)")
    else:
        check(isinstance(client_messages, list) and len(client_messages) >= 1, f"{name}: generated contract lists browser messages")

def stop_server():
    """Unload the page, stop the server's process group and wait until its
    port refuses connections, so the next example starts on a free port.

    Returns False, after recording each failure with `check`, when the page
    was not unloaded, the output reader outlived the server, or the port is
    still open. The server is stopped either way. `start_example` refuses
    to start the next example on False: a page still connected to the old
    server, or a port still held, would make its results meaningless."""
    global server_proc, server_reader
    ok = True
    label = server_name or "before the first example"
    if ws is not None:
        r = cdp("Page.navigate", {"url": "about:blank"}, timeout=2)
        if r is None or "error" in r:
            reason = "no response" if r is None else r["error"].get("message")
            check(False, f"{label}: browser unloads the page before the server stops ({reason})")
            ok = False
        elif not wait_for_js('location.href === "about:blank"', timeout=2):
            check(False, f"{label}: browser reaches about:blank before the server stops")
            ok = False
        clear_browser_errors()
    if server_proc:
        kill_server_group(server_proc)
        if server_reader is not None:
            server_reader.join(timeout=5)
            if server_reader.is_alive():
                check(False, f"{label}: server output reader stops after the server exited")
                ok = False
        server_proc = None
        server_reader = None
    if os.environ.get("BRAZIER_CDP_KILL_PORT") == "1":
        os.system(f"lsof -ti:{BRAZIER_PORT} 2>/dev/null | xargs kill -9 2>/dev/null")
    if not wait_until_port_free(BRAZIER_PORT):
        check(False, f"port {BRAZIER_PORT} refuses connections after the server stopped")
        ok = False
    return ok

def wait_until_port_free(port):
    deadline = time.time() + WAIT_SECONDS
    while port_accepts_connections(port):
        if time.time() >= deadline:
            return False
        time.sleep(RETRY_SECONDS)  # re-probe interval; the condition is the port, not the time
    return True

def kill_server_at_exit():
    if server_proc is not None and server_proc.poll() is None:
        kill_server_group(server_proc)

atexit.register(kill_server_at_exit)

def check(cond, msg):
    global PASS, FAIL
    if cond:
        print(f"  + {msg}")
        PASS += 1
    else:
        print(f"  FAIL {msg}")
        FAIL += 1
        if VERBOSE:
            t = evl('document.getElementById("brazier-app")?.textContent?.substring(0,200) || "NO APP"')
            print(f"    [v] DOM text: {t}")
            h = evl('document.getElementById("brazier-app")?.innerHTML?.substring(0,300) || "NO HTML"')
            print(f"    [v] HTML: {h}")

print("=== Brazier CDP Test Suite ===")
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
    expect_text("Count: 0", "Initial: Count: 0")
    reset_dom_monitor()
    clear_cdp_events()
    click_button("+")
    expect_text("Count: 1", "Increment: Count: 1")
    check_model_ws_update("Counter increment", events=1)
    clear_cdp_events()
    click_button("+")
    expect_text("Count: 2", "Increment: Count: 2")
    check_model_ws_update("Counter second increment", events=1)
    clear_cdp_events()
    click_button("-")
    expect_text("Count: 1", "Decrement: Count: 1")
    check_model_ws_update("Counter decrement", events=1)
    clear_cdp_events()
    click_button("-")
    expect_text("Count: 0", "Decrement: Count: 0")
    check_model_ws_update("Counter second decrement", events=1)
    check_dom_conformance("Counter")

    reset_dom_monitor()
    force_socket_reconnect("Counter reconnect", "Count: 0")
    clear_cdp_events()
    click_button("+")
    expect_text("Count: 1", "Counter reconnect: click works after reconnect")
    check_model_ws_update("Counter reconnect", events=1)
    check_dom_conformance("Counter reconnect")

    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 2. Counter Local ==
print("-- 2: Counter Local --")
if start_example("counter_local"):
    navigate()
    expect_text("Count (server): 0", "Initial server count: 0")
    reset_dom_monitor()
    clear_cdp_events()
    click_button("+")
    expect_text("Count (server): 1", "Server +1")
    check_model_ws_update("Counter local server +1", events=1)
    clear_cdp_events()
    click_button("+")
    expect_text("Count (server): 2", "Server +2")
    check_model_ws_update("Counter local server +2", events=1)
    clear_cdp_events()
    click_button("-")
    expect_text("Count (server): 1", "Server -1")
    check_model_ws_update("Counter local server -1", events=1)
    # LOCAL: toggle menu on
    clear_cdp_events()
    click_by_text("Toggle")
    expect_text("Menu is open", "Toggle menu ON")
    check_local_ws_quiet("Counter local menu on")
    # LOCAL: toggle menu off
    clear_cdp_events()
    click_by_text("Toggle")
    expect_no_text("Menu is open", "Toggle menu OFF")
    check_local_ws_quiet("Counter local menu off")
    # LOCAL: input
    clear_cdp_events()
    type_input("[data-brazier-on-input]", "testlocal")
    expect_text("testlocal", "Local input shows text")
    check_local_ws_quiet("Counter local input")
    clear_cdp_events()
    click_button("+")
    expect_text("Count (server): 2", "Server event after local input still works")
    check_model_ws_update("Server event after local input", events=1)
    check(websocket_payload_count("Sent", '"type":"event_batch"') == 0, "Local input is not replayed as event_batch")
    check_dom_conformance("Counter local")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 3. Kanban ==
KANBAN_COLUMN_JS = 'document.querySelector("[data-column=COLUMN]")?.textContent || ""'

def kanban_column(column):
    return str(evl(KANBAN_COLUMN_JS.replace("COLUMN", column)))

print("-- 3: Kanban --")
if start_example("kanban"):
    navigate()
    t = text()
    check("Kanban Board" in t, "Title renders")
    check("Design API" in t, "Initial card renders")
    check("Todo" in t and "In Progress" in t and "Done" in t, "3 columns")
    check("(3)" in kanban_column("todo"), "Todo shows (3)")
    check("(1)" in kanban_column("doing"), "In Progress shows (1)")
    # Add card
    type_input("[data-brazier-on-input]", "CDP Card")
    submit_by_text("Add Card")
    expect(lambda: "CDP Card" in kanban_column("todo"), "Added card visible in Todo")
    expect(lambda: "(4)" in kanban_column("todo"), "Todo shows (4)")
    # Delete a specific card by its label.
    click_label("Delete Design API")
    expect_no_text("Design API", "Delete: Design API removed")
    expect(lambda: "(3)" in kanban_column("todo"), "Todo shows (3) after delete")
    # DnD: drag "Write tests" to Done
    dragged = evl("""
    (function() {
      var card = Array.from(document.querySelectorAll('[data-card]')).find(function(c){return c.textContent.includes("Write tests")});
      var done = document.querySelector('[data-column="done"]');
      if (!card || !done) return "not found";
      var dt = new DataTransfer();
      dt.setData("text/plain", card.getAttribute("data-card"));
      card.dispatchEvent(new DragEvent("dragstart", {bubbles:true, dataTransfer:dt}));
      done.dispatchEvent(new DragEvent("dragover", {bubbles:true, dataTransfer:dt}));
      done.dispatchEvent(new DragEvent("drop", {bubbles:true, dataTransfer:dt}));
      return "dragged";
    })()
    """)
    check(dragged == "dragged", f"Drag: card and Done column exist ({dragged})")
    expect(lambda: "Write tests" in kanban_column("done"), "Drag: card in Done column")
    expect(lambda: "Write tests" not in kanban_column("todo"), "Drag: card left Todo")
    # MULTI-USER: a new session reads the cards from the shared store
    navigate()
    expect(lambda: "CDP Card" in kanban_column("todo"), "Multi-user: added card persists in new session")
    expect(lambda: "Write tests" in kanban_column("done"), "Multi-user: moved card persists in new session")
    expect_no_text("Design API", "Multi-user: deleted card stays deleted")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 4. Canvas ==
CANVAS_THROTTLE_MS = 16  # examples/canvas move_throttle_ms

def canvas_mouse(kind, x, y):
    return evl(
        'var s=document.querySelector("svg[data-canvas]"),r=s.getBoundingClientRect(); '
        f's.dispatchEvent(new MouseEvent("{kind}",{{clientX:r.left+{x},clientY:r.top+{y},bubbles:true,cancelable:true}})); "ok"'
    )

print("-- 4: Canvas --")
if start_example("canvas"):
    navigate()
    t = text()
    check("Collaborative Canvas" in t, "Title")
    check("Strokes: 0" in t, "Initial 0 strokes")
    check("Click and drag to draw" in t, "Idle hint before drawing")
    # Draw: mousedown -> moves -> mouseup. The pen trail is Local state.
    clear_cdp_events()
    canvas_mouse("mousedown", 50, 50)
    expect_text("Drawing, 1 points", "LOCAL pen down starts a 1-point stroke")
    for i in range(5):
        # The view throttles mousemove to one per CANVAS_THROTTLE_MS and
        # drops the rest, so each move is spaced past the window inside the
        # page (a timer never fires early). The spacing is the thing under
        # test; the count below then pins every accepted move.
        moved = evl_async(
            f"new Promise(function(done){{ setTimeout(function(){{"
            'var s=document.querySelector("svg[data-canvas]"),r=s.getBoundingClientRect(); '
            f's.dispatchEvent(new MouseEvent("mousemove",{{clientX:r.left+{80 + i * 30},clientY:r.top+{50 + i * 20},bubbles:true}})); '
            f'done("ok"); }}, {2 * CANVAS_THROTTLE_MS}); }})'
        )
        check(moved == "ok", f"Move {i + 1} dispatched ({moved})")
        expect_text(f"Drawing, {i + 2} points", f"LOCAL move {i + 1} adds a point")
    # Two moves in the same task, past the window since the last accepted
    # move: the first is accepted, the second lands inside its window and
    # is dropped.
    pair = evl_async(
        "new Promise(function(done){ setTimeout(function(){"
        'var s=document.querySelector("svg[data-canvas]"),r=s.getBoundingClientRect(); '
        'for (var k = 0; k < 2; k++) s.dispatchEvent(new MouseEvent("mousemove",{clientX:r.left+300+k,clientY:r.top+150,bubbles:true})); '
        f'done("ok"); }}, {2 * CANVAS_THROTTLE_MS}); }})'
    )
    check(pair == "ok", f"Back-to-back moves dispatched ({pair})")
    expect_text("Drawing, 7 points", "LOCAL throttle keeps one of two back-to-back moves")
    check(count_js('document.querySelectorAll("polyline").length') == 1, "LOCAL drawing: one in-progress polyline")
    check_local_ws_quiet("Canvas drawing")
    check("Drawing, 7 points" in str(text()), "Throttle dropped the second move for good")
    # Release -> one PenUp carries the whole stroke to the server.
    clear_cdp_events()
    evl('document.querySelector("svg[data-canvas]").dispatchEvent(new MouseEvent("mouseup",{bubbles:true})); "ok"')
    expect_text("Strokes: 1", "Stroke committed: Strokes: 1")
    expect_text("Click and drag to draw", "Pen up ends the local stroke")
    check_model_ws_update("Canvas pen up", events=1)
    check(count_js('document.querySelectorAll("polyline").length') == 1, "One committed polyline")
    # Colour change is Local: the picked swatch gets the thick border.
    clear_cdp_events()
    click_label("Colour #ff0000")
    expect_js(
        'document.querySelector(\'[aria-label="Colour #ff0000"]\').style.border.startsWith("3px")',
        "Colour picker marks red as selected",
    )
    expect_js(
        'document.querySelector(\'[aria-label="Colour #000000"]\').style.border.startsWith("1px")',
        "Colour picker unmarks black",
    )
    check_local_ws_quiet("Canvas colour pick")
    # MULTI-USER: a new session reads the strokes from the shared store
    navigate()
    expect_text("Strokes: 1", "Multi-user: Strokes: 1 in new session")
    check(count_js('document.querySelectorAll("polyline").length') == 1, "Multi-user: the stroke renders in the new session")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 5. Snake ==
print("-- 5: Snake --")
if start_example("snake"):
    navigate()
    t = text()
    check("Snake" in t, "Title")
    type_input("[data-brazier-on-input]", "CDPPlayer")
    submit_by_text("Play")
    expect_text("Snake: CDPPlayer", "Game started for the player")
    expect_text("Score", "Score visible")
    # The server tick loop moves the snake: the board changes on its own.
    h1 = str(html())
    expect(lambda: str(html()) != h1, "Tick loop: game state changes over time")
    rect_count = str(html()).count("<rect")
    check(rect_count >= 2, f"SVG rects: {rect_count}")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 6. Chat ==
print("-- 6: Chat --")
if start_example("chat"):
    navigate()
    t = text()
    check("Brazier Chat" in t, "Title")
    # Login
    type_input("[data-brazier-on-input]", "TestUser")
    submit_by_text("Join")
    expect_text("Online: TestUser", "Presence lists the joined user")
    t = text()
    check("general" in t, "Room shown")
    check("No messages yet" in t, "Empty room")
    # Send message
    type_input('input[placeholder="Type a message..."]', "Hello from CDP")
    submit_by_text("Send")
    expect_text("Hello from CDP", "Message appears in chat")
    expect_no_text("No messages yet", "Empty state cleared")
    check("TestUser" in str(text()), "Sender shown")
    # MULTI-USER: a new session joins and reads the message from the store
    navigate()
    type_input("[data-brazier-on-input]", "User2")
    submit_by_text("Join")
    expect_text("Online: User2", "Second user joins")
    expect_text("Hello from CDP", "Multi-user: message persists for new user")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 7. Dashboard ==
def dashboard_tick():
    m = re.search(r"Tick #(\d+)", str(text()))
    return int(m.group(1)) if m else -1

print("-- 7: Dashboard --")
if start_example("dashboard"):
    navigate()
    t = text()
    check("Live Dashboard" in t, "Title")
    check("Process" in t, "Process metric")
    check("Memory" in t, "Memory metric")
    check("Uptime" in t, "Uptime metric")
    # Server push: the tick count rises with no client interaction.
    tick1 = dashboard_tick()
    check(tick1 >= 0, f"Tick counter shown ({tick1})")
    expect(lambda: dashboard_tick() > tick1, f"Server-push: tick rises past {tick1}")
    expect(lambda: dashboard_tick() > tick1 + 1, f"Server-push: tick keeps rising past {tick1 + 1}")
    check("MB" in str(text()), "Memory has MB value")
    check("svg" in str(html()), "SVG elements present")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 8. Pong ==
PONG_BALL_JS = '(document.querySelector(\'[data-testid="pong-ball"]\')?.getAttribute("style")) || ""'
# How long the paused ball must hold still: about 30 of pong's 16 ms ticks.
PONG_FROZEN_SECONDS = 0.5

print("-- 8: Pong --")
if start_example("pong"):
    navigate()
    t = text()
    check("Pong" in t, "Title")
    check("Start" in t, "Start button")
    ball0 = str(evl(PONG_BALL_JS))
    check(ball0 != "", "Ball rendered")
    # Start game
    click_button("Start")
    expect_text("Pause", "Start -> Pause")
    expect(lambda: str(evl(PONG_BALL_JS)) not in ("", ball0), "Ball moves while running")
    ball_moving = str(evl(PONG_BALL_JS))
    expect(lambda: str(evl(PONG_BALL_JS)) not in ("", ball_moving), "Ball keeps moving")
    # Pause
    click_button("Pause")
    expect(lambda: "Start" in str(text()) and "Pause" not in str(text()), "Pause -> Start")
    # Patches arrive in order, so once the paused view shows, the ball has
    # its final position. Holding still across many ticks is the thing
    # under test, so this window is deliberate.
    ball1 = str(evl(PONG_BALL_JS))
    pump(PONG_FROZEN_SECONDS)
    ball2 = str(evl(PONG_BALL_JS))
    check(ball1 == ball2 and ball1 != "", f"Frozen when paused ({ball1!r} -> {ball2!r})")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 9. Triple Counter ==
TRIPLE_COUNTS_JS = 'Array.from(document.querySelectorAll("#brazier-app strong")).map(function(s){return s.textContent.trim()}).join(",")'

def expect_triple(expected, msg):
    """Counts as "shared,server,local"."""
    return expect_value(TRIPLE_COUNTS_JS, expected, msg)

print("-- 9: Triple Counter --")
if start_example("triple_counter"):
    navigate()
    t = text()
    check("Shared Counter" in t, "Shared section")
    check("Server Counter" in t, "Server section")
    check("Local Counter" in t, "Local section")
    bc = count_js('document.querySelectorAll("[data-brazier-on-click]").length')
    check(bc == 6, f"6 buttons ({bc})")
    expect_triple("0,0,0", "Initial counts 0,0,0")
    clear_cdp_events()
    click_button("+", 0)
    expect_triple("1,0,0", "Shared + -> 1,0,0")
    check_model_ws_update("Triple shared +", events=1)
    clear_cdp_events()
    click_button("+", 1)
    expect_triple("1,1,0", "Server + -> 1,1,0")
    check_model_ws_update("Triple server +", events=1)
    clear_cdp_events()
    click_button("+", 2)
    expect_triple("1,1,1", "Local + -> 1,1,1")
    check_local_ws_quiet("Triple local +")
    click_button("-", 0)
    expect_triple("0,1,1", "Shared - -> 0,1,1")
    for n in (1, 2, 3):
        click_button("+", 0)
        expect_triple(f"{n},1,1", f"Shared + -> {n},1,1")
    # MULTI-USER: a new session sees the shared count; its own counts start at 0
    navigate()
    expect_triple("3,0,0", "Multi-user: shared 3 persists, server and local reset")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 11. Todo App ==
print("-- 11: Todo App --")
if start_example("todo", module="todo_app"):
    navigate()
    t = text()
    check("Todo App" in t, "Title")
    check("0 items left" in t, f"Items left counter starts at 0 ({t[:60]})")
    # Add todo
    type_input("[data-brazier-on-input]", "Buy milk")
    submit_by_text("Add")
    expect_text("Buy milk", "Added todo visible")
    expect_text("1 item left", "1 item left")
    # Add another
    type_input("[data-brazier-on-input]", "Walk dog")
    submit_by_text("Add")
    expect_text("Walk dog", "Second todo visible")
    expect_text("2 items left", "2 items left")
    # Complete the first
    click_label("Toggle Buy milk")
    expect_text("1 item left", "Toggle: 1 item left after completing one")
    # Filter Active
    click_button("Active")
    expect_no_text("Buy milk", "Filter Active: completed todo hidden")
    check("Walk dog" in str(text()), "Filter Active: active still shown")
    # Filter All
    click_button("All")
    expect_text("Buy milk", "Filter All: completed todo back")
    check("Walk dog" in str(text()), "Filter All: both visible")
    # Delete
    click_label("Delete Buy milk")
    expect_no_text("Buy milk", "Delete: Buy milk removed")
    check("Walk dog" in str(text()), "Delete: Walk dog kept")
    # Multi-user: a new session reads the todos from the store
    navigate()
    expect_text("Walk dog", "Multi-user: remaining todo persists in new session")
    check("Buy milk" not in str(text()), "Multi-user: deleted todo stays deleted")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 12. Shopping Cart ==
CART_QTY_JS = 'document.querySelector(\'[aria-label="One less Laptop"]\')?.nextElementSibling?.textContent || "none"'
CART_TOTAL_JS = 'document.getElementById("cart-total")?.textContent || "none"'

print("-- 12: Shopping Cart --")
if start_example("cart"):
    navigate()
    t = text()
    check("Shopping Cart" in t, "Title")
    check("Laptop" in t, "Product listed")
    check("$999 | Stock: 5" in t, "Laptop price and stock shown")
    check("Cart is empty" in t, "Cart initially empty")
    # Add product to cart
    click_label("Add Laptop")
    expect_no_text("Cart is empty", "Cart not empty after add")
    expect_value(CART_QTY_JS, "1", "Quantity 1")
    expect_value(CART_TOTAL_JS, "$1098", "Total $999 + 10% tax")
    expect_text("$999 | Stock: 4", "Stock drops to 4")
    # Increment quantity
    click_label("One more Laptop")
    expect_value(CART_QTY_JS, "2", "Quantity incremented to 2")
    expect_value(CART_TOTAL_JS, "$2197", "Total $1998 + 10% tax")
    expect_text("$999 | Stock: 3", "Stock drops to 3")
    # Remove from cart
    click_label("Remove Laptop")
    expect_text("Cart is empty", "Cart empty after remove")
    expect_text("$999 | Stock: 5", "Remove returns the stock")
    # Multi-user: add one, then a new session sees the shared stock
    click_label("Add Laptop")
    expect_text("$999 | Stock: 4", "Stock 4 after adding again")
    navigate()
    expect_text("$999 | Stock: 4", "Multi-user: decreased stock persists")
    check("Cart is empty" in str(text()), "Multi-user: the new session's cart is its own")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 13. Spreadsheet ==
print("-- 13: Spreadsheet --")
if start_example("spreadsheet"):
    navigate()
    t = text()
    check("Spreadsheet" in t, "Title")
    check("<table" in str(html()), "Grid rendered")
    check("A" in t and "B" in t, "Column headers")
    cell = str(evl(
        'Array.from(document.querySelectorAll("td[data-cell]")).find(function(td){return td.textContent === ""})?.getAttribute("data-cell") || ""'
    ))
    check(cell != "", f"An empty cell exists ({cell})")
    cell_js = json.dumps(cell)
    cell_sel = f'td[data-cell="{cell}"]'
    # First click selects (Local)
    clear_cdp_events()
    click(cell_sel)
    expect_text(f"Selected: {cell}", f"Cell {cell} selected")
    check(f"Selected: {cell} (editing)" not in str(text()), "First click does not edit")
    # Second click edits (Local)
    click(cell_sel)
    expect_text(f"Selected: {cell} (editing)", f"Cell {cell} in edit mode")
    expect_js(f'!!document.querySelector(\'[aria-label="Edit {cell}"]\')', "Edit input shown")
    check_local_ws_quiet("Spreadsheet select and edit")
    type_input(f'[aria-label="Edit {cell}"]', "CellData")
    submit_by_text("Save")
    expect_value(f'document.querySelector({json.dumps(cell_sel)})?.textContent ?? "none"', "CellData", "Cell value saved")
    # Multi-user: a new session reads the cell from the store
    navigate()
    expect_value(f'document.querySelector({json.dumps(cell_sel)})?.textContent ?? "none"', "CellData", "Multi-user: cell persists")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 10. AI Chat ==
print("-- 10: AI Chat --")
if start_example("ai_chat"):
    navigate()
    t = text()
    check("AI" in t or "Chat" in t or "chat" in t.lower(), f"UI renders")
    h = html()
    check("data-brazier-on-input" in h, "Input field present")
    check("data-brazier-on-click" in h, "Send button present")
    type_input("input[data-brazier-on-input]", "hello cdp")
    clear_cdp_events()
    click_button("Send")
    check(
        wait_for_js('(document.getElementById("brazier-app")?.textContent || "").includes("Server stream received: hello cdp. Brazier keeps")', timeout=15),
        "Server stream drips the response to the browser",
    )
    check(
        wait_for_js('Array.from(document.querySelectorAll("button")).some(function(b){return b.textContent.trim()==="Send" && !b.disabled})', timeout=15),
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
        const src = Array.from(document.scripts).map(s => s.src).find(s => s.includes('brazier_client_'));
        return src ? await fetch(src).then(r => r.text()) : '';
      })()
    """)
    check(len(str(bundle_text)) > 1000, f"Client bundle fetched ({len(str(bundle_text))} bytes)")
    check(all(s not in str(bundle_text) for s in secrets), "Server secrets not present in client bundle")
    clear_cdp_events()
    click_button("Add Item")
    expect(lambda: "Items: 3" in str(text()) and "Total: $54.00" in str(text()), "Add item updates the derived totals")
    check_model_ws_update("Privacy demo add item", events=1)
    clear_cdp_events()
    click_button("Clear")
    expect(lambda: "Items: 0" in str(text()) and "Total: $0.00" in str(text()), "Clear empties the cart")
    check_model_ws_update("Privacy demo clear", events=1)
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
    expect_text("Counter: 1", "Increment works")
    click_by_text("+")
    expect_text("Counter: 2", "Increment again")
    click_by_text("-")
    expect_text("Counter: 1", "Decrement works")
    # Middleware at the HTTP level, through the page's own fetch
    health = evl_async('fetch("/healthz").then(r => r.text().then(t => r.status + ":" + t))')
    check(str(health).startswith("200:") and "ok" in str(health), f"Health endpoint returns 200 ok ({health})")
    check(errors() == "0", f"No errors before expected admin rejection ({error_list()})")
    admin_status = evl_async('fetch("/admin/secret").then(r => String(r.status))')
    check(str(admin_status) == "403", f"Admin blocked without header (status={admin_status})")
    api_post = evl_async("""
      fetch('/api/items', {method: 'POST'})
        .then(r => r.status + ':' + r.headers.get('allow') + ':' + r.headers.get('x-api-version'))
    """)
    check(str(api_post) == "405:GET, HEAD:v1", f"API write blocked with allow header ({api_post})")
    # Chrome logs each refused fetch as a console error. Wait for both, so
    # they are cleared here and not counted against a later check.
    expect(lambda: any("/admin/secret" in e for e in browser_errors), "Browser logs the expected 403")
    expect(lambda: any("/api/items" in e for e in browser_errors), "Browser logs the expected 405")
    unexpected = [e for e in browser_errors if "/admin/secret" not in e and "/api/items" not in e]
    check(unexpected == [], f"No other browser errors ({unexpected})")
    clear_browser_errors()
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 15. Multi-File Domains ==
FIRST_ITEM_JS = 'document.querySelector("#brazier-app .item")?.textContent || "none"'

print("-- 15: Multi-File Domains --")
if start_example("domains", module="app"):
    navigate()
    t = text()
    check("Multi-File Domains" in t, "Title")
    check("Alice" in t, "User name shown")
    check("alice@example.com" in t, "User email shown")
    check("Member" in t, "Role shown")
    check("Buy groceries" in t, "Item 1 shown")
    check("Write tests" in t, "Item 2 shown")
    check("Items (2)" in t, "Two items")
    # Toggle the first item
    check(str(evl(FIRST_ITEM_JS)) == "[ ] Buy groceries", f"First item starts open ({evl(FIRST_ITEM_JS)})")
    click("#brazier-app .item")
    expect_value(FIRST_ITEM_JS, "[x] Buy groceries", "Toggle marks the first item done")
    # Add an item
    type_input('input[aria-label="New item"]', "New item")
    submit_by_text("Add")
    expect_text("[ ] New item", "Item added, open")
    expect_text("Items (3)", "Three items")
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
    check("Design API" in t, "Card 1 shown")
    check("Write tests" in t, "Card 2 shown")
    check("Build UI" in t, "Card 3 shown")
    check("Deploy" not in t, "No Deploy card yet")
    # Add a card
    type_input('input[type="text"]', "Deploy")
    submit_by_text("Add Card")
    expect_text("Deploy", "New card added")
    check("data-brazier-on-dragstart" in str(html()), "Drag handlers present")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 17. Multi-File Todo ==
print("-- 17: Multi-File Todo --")
if start_example("multi_todo", module="app"):
    navigate()
    t = text()
    check("Multi-File Todo" in t, "Title")
    check("Learn Gleam" in t, "Initial item 1")
    check("Build with Brazier" in t, "Initial item 2")
    check("Ship it" in t, "Initial item 3")
    check("2 items remaining" in t, "Remaining count (1 completed, 2 active)")
    # Add a todo
    type_input('input[type="text"]', "Write docs")
    submit_by_text("Add")
    expect_text("Write docs", "New todo added")
    expect_text("3 items remaining", "Remaining count updated")
    # Active hides the completed item (Learn Gleam)
    click_button("Active")
    expect_no_text("Learn Gleam", "Filter Active hides the completed item")
    check("Write docs" in str(text()), "Filter Active keeps active items")
    click_button("All")
    expect_text("Learn Gleam", "Filter All shows the completed item again")
    # Clear completed
    click_button("Clear Done")
    expect_no_text("Learn Gleam", "Completed items cleared")
    check("3 items remaining" in str(text()), "Active items kept")
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
    check("brazier_private_session_signing_key_must_not_ship" not in str(html()), "Server signing key not present in DOM")
    bundle_text = evl_async("""
      (async () => {
        const src = Array.from(document.scripts).map(s => s.src).find(s => s.includes('brazier_client_'));
        return src ? await fetch(src).then(r => r.text()) : '';
      })()
    """)
    check(len(str(bundle_text)) > 1000, f"Client bundle fetched ({len(str(bundle_text))} bytes)")
    check("brazier_private_session_signing_key_must_not_ship" not in str(bundle_text), "Server signing key not present in client bundle")
    check("session-created" not in str(bundle_text), "Server audit seed not present in client bundle")

    reset_dom_monitor()
    clear_cdp_events()
    click_by_text("Approve transfer")
    expect_text("Visible balance: 1175", "Approve transfer updates public balance")
    expect_text("Approved actions: 1", "Approve transfer increments public action count")
    check_model_ws_update("Private session approve", events=1)

    clear_cdp_events()
    click_by_text("Deny transfer")
    expect_text("Transfer denied", "Deny transfer updates public event only")
    check("Visible balance: 1175" in str(text()), "Deny leaves the balance")
    check_model_ws_update("Private session deny", events=1)

    clear_cdp_events()
    click_by_text("Refresh public summary")
    expect_text("Public summary refreshed", "Refresh uses server state without exposing it")
    check("brazier_private_session_signing_key_must_not_ship" not in str(html()), "Server signing key still absent after updates")
    check_model_ws_update("Private session refresh", events=1)
    check_dom_conformance("Private session")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 19. Routed Workspace ==
# Page identity across renders (L83). Every element under #brazier-app gets
# a JS property no markup can set, the root and the window get a marker, and
# the elements are kept in a list, so a later check can tell a reused node
# from a new one and a live navigation from a page load.
def mark_page_nodes(label):
    marker = json.dumps(f"page-{time.time_ns()}")
    marked = evl(
        "(function(){"
        'var root = document.getElementById("brazier-app");'
        'var nodes = Array.from(root.querySelectorAll("*"));'
        "nodes.forEach(function(n){ n.__cdpOldPage = true; });"
        f"window.__cdpMarkedNodes = nodes; root.__cdpRootMarker = {marker}; window.__cdpPageMarker = {marker};"
        "return nodes.length;})()"
    )
    check(isinstance(marked, int) and marked > 0, f"{label}: page nodes marked ({marked})")
    return json.loads(marker)

OLD_PAGE_NODES_JS = (
    'Array.from(document.getElementById("brazier-app").querySelectorAll("*"))'
    ".filter(function(n){ return n.__cdpOldPage === true; }).length"
)
DETACHED_MARKED_NODES_JS = "window.__cdpMarkedNodes.filter(function(n){ return !n.isConnected; }).length"

def check_same_root_and_document(label, marker):
    check(
        str(evl('document.getElementById("brazier-app").__cdpRootMarker || ""')) == marker,
        f"{label}: the app root element is the same",
    )
    check(str(evl("window.__cdpPageMarker || ''")) == marker, f"{label}: no page load")

def check_page_morphs_in_place(label, act, rendered_js):
    """A model change on the same page morphs it: every element of the page
    is still in the document afterwards."""
    marker = mark_page_nodes(label)
    clear_cdp_events()
    act()
    expect_js(rendered_js, f"{label}: the change renders")
    check(count_js(DETACHED_MARKED_NODES_JS) == 0, f"{label}: no element of the page is replaced ({evl(DETACHED_MARKED_NODES_JS)} detached)")
    check_same_root_and_document(label, marker)

def check_page_replaced_on_live_navigation(label, link_sel, path, page_js):
    """The first render of a live navigation's page replaces the root's
    children: no element of the old page is reused, the focused element of
    the old page does not keep focus, and the root element stays. The link
    is focused before the click, as a keyboard user's would be. `page_js`
    is true only once the new page is rendered."""
    marker = mark_page_nodes(label)
    focused = evl(f"(function(){{var a = document.querySelector({json.dumps(link_sel)}); if (!a) return 'none'; a.focus(); return document.activeElement === a ? 'focused' : 'not focused';}})()")
    check(focused == "focused", f"{label}: the link on the old page has focus ({focused})")
    clear_cdp_events()
    click(link_sel)
    rendered = wait_for_js(f"location.pathname === {json.dumps(path)} && ({page_js})")
    check(rendered, f"{label}: the new page renders at {path} ({evl('location.pathname')})")
    old = count_js(OLD_PAGE_NODES_JS)
    check(old == 0, f"{label}: no element of the old page is reused ({old} kept)")
    check(
        evl("!(document.activeElement && document.activeElement.__cdpOldPage)") is True,
        f"{label}: focus does not stay on an element of the old page",
    )
    check_same_root_and_document(label, marker)
    sent = [p.get("path") for p in websocket_json_payloads("Sent") if p.get("type") == "navigate"]
    check(sent == [path], f"{label}: one navigate for {path} ({sent})")

print("-- 19: Routed Workspace --")
if start_example("routed_workspace", module="main"):
    navigate("/")
    t = text()
    check("Overview" in t, "SSR: routed workspace overview renders")
    check("Opentickets7" in squashed_text(), "SSR: overview model data renders")
    check("Deploystoday3" in squashed_text(), "SSR: deploy count renders")

    reset_dom_monitor()
    clear_cdp_events()
    click_by_text("Toggle inspector")
    expect_text("Inspector", "Local inspector toggles instantly")
    check_local_ws_quiet("Routed workspace inspector")

    clear_cdp_events()
    click_by_text("activity")
    expect_text("Selected tab: activity", "Local tab changes instantly")
    check_local_ws_quiet("Routed workspace tab")

    clear_cdp_events()
    click_by_text("Ship deploy")
    expect(lambda: "Deploystoday4" in squashed_text(), "Model deploy count increments")
    check_model_ws_update("Routed workspace deploy", events=1)

    clear_cdp_events()
    click('a[href="/pipeline"]')
    expect_path_and_heading("/pipeline", "Pipeline", "Client navigation: pipeline URL and view")

    clear_cdp_events()
    type_input('[data-testid="card-draft"]', "CDP route card")
    expect_value('document.querySelector("[data-testid=card-draft]")?.value || ""', "CDP route card", "Local card draft input updates")
    check_local_ws_quiet("Routed workspace card draft")

    clear_cdp_events()
    select_option("[data-testid=lane-filter]", "done")
    expect_text("Filter: done", "Local lane filter changes")
    check_local_ws_quiet("Routed workspace lane filter")

    clear_cdp_events()
    select_option("[data-testid=lane-filter]", "all")
    expect_text("Filter: all", "Local lane filter back to all")
    type_input('[data-testid="card-draft"]', "CDP route card")
    submit_form("form")
    expect_text("CDP route card", "Model card submit adds card")
    check_model_ws_update("Routed workspace add card", events=1)

    clear_cdp_events()
    click_by_text("Compact")
    expect_text("compact: true", "Local compact toggle changes")
    check_local_ws_quiet("Routed workspace compact")

    # The pipeline page's form, typed into above, is not morphed into the
    # settings page's: the page is replaced.
    check_page_replaced_on_live_navigation(
        "Routed workspace navigation to settings",
        'a[href="/settings"]',
        "/settings",
        '!!document.querySelector("[data-testid=draft-name]")',
    )
    expect_path_and_heading("/settings", "Settings", "Client navigation: settings URL and view")
    expect_text("Ada / owner / v1", "Settings renders saved profile")

    reset_dom_monitor()
    clear_cdp_events()
    type_input('[data-testid="draft-name"]', "Grace")
    expect_text("Draft: Grace / owner", "Local profile draft name changes")
    check_local_ws_quiet("Routed workspace profile draft")

    clear_cdp_events()
    select_option("[data-testid=draft-role]", "operator")
    expect_text("Draft: Grace / operator", "Local profile role changes")
    check_local_ws_quiet("Routed workspace profile role")

    clear_cdp_events()
    submit_form("form")
    expect_text("Grace / operator / v2", "Model profile save persists")
    check_model_ws_update("Routed workspace save profile", events=1)

    clear_cdp_events()
    click_by_text("Toggle menu")
    expect_text("Local actions menu is open", "Local settings menu toggles")
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
ROUTED_COUNT_JS = 'document.querySelector("[data-testid=count]")?.textContent || ""'

FRAGMENT_SCROLL_STATE_JS = (
    "JSON.stringify({path: location.pathname, hash: location.hash, "
    "scrollY: Math.round(window.scrollY), "
    'rootTop: Math.round(document.getElementById("brazier-app").getBoundingClientRect().top), '
    "marker: window.__brazierCdpFragmentNav || null})"
)

def check_fragment_scroll_after_live_navigation(path, fragment_text, other_path, other_text):
    """A live navigation to another page's #fragment scrolls to it once that
    page is rendered, and one to a fragment the page lacks scrolls to the
    top. history.pushState never scrolls, so without the client's fragment
    scroll the page would stay where it was. The examples have no fragment
    links, so the check adds one outside #brazier-app (the morph never
    touches it) and pads the body so the app root sits below the fold; the
    target is #brazier-app, which every page has. A window marker proves
    neither click loaded a new document."""
    marker = json.dumps(f"fragment-{time.time_ns()}")
    setup = evl(
        "(function(){"
        'var style = document.createElement("style"); style.id = "cdp-fragment-pad";'
        'style.textContent = "body{padding-top:3000px;padding-bottom:3000px}";'
        "document.head.appendChild(style);"
        'var a = document.createElement("a"); a.id = "cdp-fragment-link"; a.textContent = "fragment";'
        'a.style.position = "fixed"; a.style.top = "0"; a.style.left = "0";'
        "document.body.appendChild(a);"
        f"window.__brazierCdpFragmentNav = {marker}; window.scrollTo(0, 0);"
        'return "ready";})()'
    )
    check(setup == "ready", f"Fragment scroll: test link and padding installed ({setup})")
    check(count_js("Math.round(window.scrollY)") == 0, "Fragment scroll: starts at the top")

    clear_cdp_events()
    evl(f'document.getElementById("cdp-fragment-link").setAttribute("href", {json.dumps(path + "#brazier-app")}); 0')
    click("#cdp-fragment-link")
    landed = wait_for_js(
        f"location.pathname === {json.dumps(path)} && location.hash === \"#brazier-app\" && "
        f'(document.getElementById("brazier-app")?.textContent || "").includes({json.dumps(fragment_text)}) && '
        "window.scrollY > 2000 && "
        'Math.abs(document.getElementById("brazier-app").getBoundingClientRect().top) <= 1'
    )
    check(landed, f"Fragment scroll: live navigation to {path}#brazier-app scrolls to the fragment ({evl(FRAGMENT_SCROLL_STATE_JS)})")
    check(str(evl("window.__brazierCdpFragmentNav")) == json.loads(marker), "Fragment scroll: no page load")
    sent = [p.get("path") for p in websocket_json_payloads("Sent") if p.get("type") == "navigate"]
    check(sent == [path], f"Fragment scroll: the server is told the path without the fragment ({sent})")

    clear_cdp_events()
    evl(f'document.getElementById("cdp-fragment-link").setAttribute("href", {json.dumps(other_path + "#cdp-no-such-id")}); 0')
    click("#cdp-fragment-link")
    topped = wait_for_js(
        f"location.pathname === {json.dumps(other_path)} && location.hash === \"#cdp-no-such-id\" && "
        f'(document.getElementById("brazier-app")?.textContent || "").includes({json.dumps(other_text)}) && '
        "window.scrollY === 0"
    )
    check(topped, f"Fragment scroll: a fragment the page lacks scrolls to the top ({evl(FRAGMENT_SCROLL_STATE_JS)})")
    check(str(evl("window.__brazierCdpFragmentNav")) == json.loads(marker), "Fragment scroll: still no page load")

    removed = evl(
        '(function(){document.getElementById("cdp-fragment-pad").remove();'
        'document.getElementById("cdp-fragment-link").remove(); return "removed";})()'
    )
    check(removed == "removed", f"Fragment scroll: test link and padding removed ({removed})")

ROUTED_ABOUT_JS = '(document.getElementById("brazier-app")?.textContent || "").includes("does not scan the filesystem")'

SCROLL_STATE_JS = (
    "JSON.stringify({path: location.pathname, hash: location.hash, "
    "scrollY: Math.round(window.scrollY), height: document.documentElement.scrollHeight, "
    "saved: (history.state && history.state.brazierScroll) || null, "
    "atPopstate: window.__cdpScrollAtPopstate === undefined ? null : window.__cdpScrollAtPopstate, "
    "marker: window.__brazierCdpScrollNav || null})"
)

def saved_scroll_js(y):
    """True once the current history entry saved the scroll position y (the
    client's history.state.brazierScroll)."""
    return f"!!(history.state && history.state.brazierScroll && history.state.brazierScroll.y === {y})"

def check_history_scroll_restore(go, path, page_js, expected_y, left_y, label):
    """history.go(go) lands on `path`, whose entry saved expected_y: the
    browser does not scroll (history.scrollRestoration is "manual"), so at
    popstate the page left is still at left_y; the client scrolls to
    expected_y once the entry's page is rendered, as LiveView restores
    history.state.scroll after the patch."""
    clear_cdp_events()
    hooked = evl(
        "(function(){ delete window.__cdpScrollAtPopstate;"
        'window.addEventListener("popstate", function(){ window.__cdpScrollAtPopstate = Math.round(window.scrollY); }, {once: true});'
        'return "hooked";})()'
    )
    check(hooked == "hooked", f"{label}: popstate scroll recorder installed ({hooked})")
    went = evl(f'history.go({go}); "ok"')
    check(went == "ok", f"{label}: history.go({go}) evaluated ({went})")
    restored = wait_for_js(
        f"location.pathname === {json.dumps(path)} && ({page_js}) && Math.round(window.scrollY) === {expected_y}"
    )
    check(restored, f"{label}: the client scrolls {path} to its saved {expected_y} once the page renders ({evl(SCROLL_STATE_JS)})")
    at_popstate = evl("window.__cdpScrollAtPopstate === undefined ? null : window.__cdpScrollAtPopstate")
    check(
        at_popstate == left_y,
        f"{label}: the browser does not restore the scroll before the page renders (scrollY {at_popstate} at popstate, the page left was at {left_y})",
    )
    expect(lambda: websocket_type_count("Sent", "navigate") == 1, f"{label}: one navigate")

def check_navigation_scroll(link_sel, path, page_js, back_path, back_page_js):
    """A live navigation to a URL without a fragment scrolls to the top once
    the new page is rendered (L606), as a page load does and as LiveView's
    pushState does; history.pushState alone keeps the scroll, and the body
    is padded so every page is tall enough to keep it. The client owns the
    scroll of Back and Forward (history.scrollRestoration "manual"): the
    entry being left saves its position (on the link click, and after the
    page stops scrolling), and the client scrolls back to it once that
    entry's page is rendered (check_history_scroll_restore). The current URL
    is back_path, the page the link is on; the check ends on `path`."""
    marker = json.dumps(f"scroll-{time.time_ns()}")
    setup = evl(
        "(function(){"
        'var style = document.createElement("style"); style.id = "cdp-scroll-pad";'
        'style.textContent = "body{padding-bottom:4000px}";'
        "document.head.appendChild(style);"
        f"window.__brazierCdpScrollNav = {marker}; window.scrollTo(0, 1500);"
        'return "ready";})()'
    )
    check(setup == "ready", f"Navigation scroll: padding installed ({setup})")
    check(
        str(evl("history.scrollRestoration")) == "manual",
        f"Navigation scroll: the client owns history scroll restoration ({evl('history.scrollRestoration')})",
    )
    check(str(evl("location.pathname")) == back_path, f"Navigation scroll: starts at {back_path} ({evl('location.pathname')})")
    check(wait_for_js("Math.round(window.scrollY) === 1500"), f"Navigation scroll: scrolled down first ({evl(SCROLL_STATE_JS)})")

    clear_cdp_events()
    click(link_sel)
    topped = wait_for_js(
        f"location.pathname === {json.dumps(path)} && location.hash === \"\" && ({page_js}) && window.scrollY === 0"
    )
    check(topped, f"Navigation scroll: live navigation to {path} scrolls to the top once the page renders ({evl(SCROLL_STATE_JS)})")
    check(str(evl("window.__brazierCdpScrollNav")) == json.loads(marker), "Navigation scroll: no page load")

    # The page stops scrolling at 800: the client saves that into this entry
    # after its debounce, which the check waits for.
    evl("window.scrollTo(0, 800); 0")
    saved = wait_for_js(f"Math.round(window.scrollY) === 800 && {saved_scroll_js(800)}")
    check(saved, f"Navigation scroll: {path} saves its scroll position after the page stops scrolling ({evl(SCROLL_STATE_JS)})")

    check_history_scroll_restore(-1, back_path, back_page_js, 1500, 800, f"Navigation scroll: back to {back_path}")
    check(str(evl("window.__brazierCdpScrollNav")) == json.loads(marker), "Navigation scroll: still no page load after back")
    check_history_scroll_restore(1, path, page_js, 800, 1500, f"Navigation scroll: forward to {path}")
    check(str(evl("window.__brazierCdpScrollNav")) == json.loads(marker), "Navigation scroll: still no page load after forward")

    removed = evl('(function(){document.getElementById("cdp-scroll-pad").remove(); window.scrollTo(0, 0); return "removed";})()')
    check(removed == "removed", f"Navigation scroll: padding removed ({removed})")

def check_double_slash_link_loads():
    """A same-origin link whose URL normalises to a "//" pathname (href
    "/.//about" is pathname "//about") is not routed live: the server
    refuses such a path (local_path), and "//about" read as a URL is the
    host "about". The client leaves the click to the browser and warns; the
    browser loads the document. The link sits outside #brazier-app, so the
    morph never touches it. A window marker tells the page load from a live
    navigation."""
    marker = json.dumps(f"double-slash-{time.time_ns()}")
    setup = evl(
        "(function(){"
        'var a = document.createElement("a"); a.id = "cdp-double-slash-link"; a.textContent = "double slash";'
        'a.setAttribute("href", "/.//about"); document.body.appendChild(a);'
        f"window.__brazierCdpDoubleSlash = {marker};"
        'return new URL(a.getAttribute("href"), location.href).pathname;})()'
    )
    check(setup == "//about", f"Double-slash link: installed, its URL's pathname is //about ({setup})")
    clear_cdp_events()
    click("#cdp-double-slash-link")
    loaded = wait_for_js(
        f'window.__brazierCdpDoubleSlash !== {marker} && document.readyState === "complete" && location.pathname === "//about"'
    )
    check(
        loaded,
        "Double-slash link: the browser loads //about as a document"
        + ("" if loaded else f" ({evl('JSON.stringify({path: location.pathname, ready: document.readyState})')})"),
    )
    warned = console_messages("warning", "Link not intercepted: its path is not a local path")
    check(
        len(warned) == 1 and "//about" in warned[0],
        f"Double-slash link: the client warns that it does not intercept it ({warned})",
    )
    sent = [p.get("path") for p in websocket_json_payloads("Sent") if p.get("type") == "navigate"]
    check(sent == [], f"Double-slash link: no navigate is sent ({sent})")

print("-- 20: Explicit Routing --")
if start_example("routed", module="main"):
    install_dom_monitor()
    navigate("/")
    t = text()
    check("Routed" in t, "SSR: home page renders")
    check(str(evl(ROUTED_COUNT_JS)) == "0", "SSR: initial count is 0")
    check("route-local Model and Msg" in t, "SSR: route-local home module copy renders")

    clear_cdp_events()
    click_by_text("+")
    expect_value(ROUTED_COUNT_JS, "1", "Model event: count increments to 1")
    check_model_ws_update("Routed model event", events=1)
    check(websocket_payload_count("Sent", '"type":"event_batch"') == 0, "Model event does not send event_batch")

    check_page_morphs_in_place(
        "Routed model event on the same page",
        lambda: click_by_text("+"),
        f"({ROUTED_COUNT_JS}) === \"2\"",
    )
    check_page_replaced_on_live_navigation(
        "Routed navigation to about",
        'a[href="/about"]',
        "/about",
        ROUTED_ABOUT_JS,
    )
    expect_path_and_heading("/about", "About", "Client navigation: about URL and view")
    check("does not scan the filesystem" in str(text()), "Client navigation: no filesystem route scan copy")

    clear_cdp_events()
    click('a[href="/settings"]')
    expect_path_and_heading("/settings", "Settings", "Client navigation: settings URL and view")

    clear_cdp_events()
    type_input('[data-testid="name-input"]', "CDP Route")
    expect(
        lambda: "CDP Route" in str(evl('document.querySelector("[data-testid=saved-name]")?.textContent || ""')),
        "Settings input updates model text",
    )
    check_model_ws_update("Routed settings input")

    click('a[href="/stats"]')
    expect_path_and_heading("/stats", "Stats", "Client navigation: stats URL and view")
    check("Route changes observed:" in str(text()), "Route model tracks entered pages")

    reset_dom_monitor()
    check_history_go(-1, "/settings", "Settings", "Explicit routed app history back to settings")
    check_history_go(-1, "/about", "About", "Explicit routed app history back to about")
    check_history_go(1, "/settings", "Settings", "Explicit routed app history forward to settings")
    check_history_go(1, "/stats", "Stats", "Explicit routed app history forward to stats")

    check_dom_conformance("Explicit routed app")
    # After the conformance check: the padding it installs is not the app's
    # layout.
    check_fragment_scroll_after_live_navigation("/about", "About", "/settings", "Settings")
    check_navigation_scroll(
        'a[href="/about"]', "/about", ROUTED_ABOUT_JS,
        "/settings", '!!document.querySelector("[data-testid=name-input]")',
    )
    check(errors() == "0", f"Zero errors ({error_list()})")

    # After the zero-errors check: the browser loads the "//" link's
    # document, which the server may answer with a 404, logged by the
    # browser as an error.
    check_double_slash_link_loads()

    # The browser logs the 404 document load itself as a console error, so
    # the zero-errors check runs before this deliberate unknown route.
    navigate("/nonexistent", expect_app=False)
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
    expect(
        lambda: "latency" in str(evl('document.querySelector("[data-testid=local-preview]")?.textContent || ""')),
        "Local draft updates instantly",
    )
    check_local_ws_quiet("Local draft")

    clear_cdp_events()
    click_by_text("Toggle options")
    expect_text("Preview:", "Local dropdown toggles")
    check_local_ws_quiet("Local dropdown")

    clear_cdp_events()
    submit_form("form")
    expect_text("Submissions: 1", "Submit updates server-authoritative Model")
    check_model_ws_update("Local first submit", events=1)
    check(websocket_payload_count("Sent", '"type":"event_batch"') == 0, "Submit does not replay local event_batch")
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
        const src = Array.from(document.scripts).map(s => s.src).find(s => s.includes('brazier_client_'));
        return src ? await fetch(src).then(r => r.text()) : '';
      })()
    """)
    check(len(str(bundle_text)) > 1000, f"Client bundle fetched ({len(str(bundle_text))} bytes)")
    check("route_accounts_private_key_must_not_ship" not in str(bundle_text), "Accounts route server key not in client bundle")
    check("route_settings_private_key_must_not_ship" not in str(bundle_text), "Settings route server key not in client bundle")

    clear_cdp_events()
    click_by_text("Approve transfer")
    expect_text("Approved: 1", "Route-local server update changes account model")
    check_model_ws_update("Route server approve", events=1)

    clear_cdp_events()
    click('a[href="/settings"]')
    expect_path_and_heading("/settings", "Settings", "Client navigation: settings URL and view")
    type_input('[data-testid="settings-email"]', "route@example.test")
    click_by_text("Save settings")
    expect_text("Saved route@example.test", "Route-local settings server update saves model")
    check("route_settings_private_key_must_not_ship" not in str(html()), "Settings route server key not in DOM")
    check_dom_conformance("Route server workspace")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 21. Auth Workspace ==
AUDIT_COUNT_JS = 'var m=(document.getElementById("brazier-app")?.textContent||"").match(/Audit events: (\\d+)/); m ? Number(m[1]) : -1'

print("-- 21: Auth Workspace --")
if start_example("auth_workspace", module="auth_workspace"):
    navigate("/login")
    check("Sign in" in str(text()), "SSR: login page renders")
    login_csrf = evl('document.querySelector(\'[data-testid="login-csrf"]\')?.value || ""')
    check(len(str(login_csrf)) >= 32, f"Login form carries a random per-browser CSRF token ({len(str(login_csrf))} chars)")
    LOGIN_STATUS_JS = """
      fetch('/api/login', {
        method: 'POST',
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        credentials: 'same-origin',
        body: %s
      }).then(r => String(r.status))
    """
    check(str(evl_async(LOGIN_STATUS_JS % "'username=ada&csrf=auth-workspace-login-csrf'")) == "403",
          "Login refuses the old constant CSRF token (403)")
    check(str(evl_async(LOGIN_STATUS_JS % "'username=ada'")) == "403",
          "Login refuses a form without the CSRF field (403)")
    wrong_csrf_body = "'username=ada&csrf=' + 'x'.repeat(%d)" % len(str(login_csrf))
    check(str(evl_async(LOGIN_STATUS_JS % wrong_csrf_body)) == "403",
          "Login refuses a CSRF field that does not match the cookie (403)")
    login_result = evl_async("""
      fetch('/api/login', {
        method: 'POST',
        headers: {'content-type': 'application/x-www-form-urlencoded'},
        credentials: 'same-origin',
        body: 'username=ada&csrf=' + encodeURIComponent(document.querySelector('[data-testid="login-csrf"]').value)
      }).then(async r => {
        const body = await r.text();
        localStorage.setItem('authCsrf', JSON.parse(body).csrf);
        return r.status + ':' + body;
      })
    """)
    check(str(login_result).startswith("200:"), f"API login succeeds and stores HttpOnly session cookie ({str(login_result)[:40]})")
    navigate("/app")
    t = text()
    check("Ada Lovelace" in t, "ws_init: session cookie hydrates workspace")
    check("admin" in t, "Authenticated role visible in model")
    check("server-only-audit-key" not in str(html()), "Server audit key not present in DOM")
    navigate("/settings")
    reset_dom_monitor()
    clear_cdp_events()
    type_input('[data-testid="display-name-input"]', 'Grace Hopper')
    check_model_ws_update("Auth workspace display-name input")
    clear_cdp_events()
    click_by_text("Save profile")
    expect_text("Grace Hopper", "Profile edit updates visible model")
    check_model_ws_update("Auth workspace profile save")
    navigate("/admin")
    t = text()
    check("Admin" in t and "Forbidden" not in t, "Admin route allows admin session")
    reset_dom_monitor()
    clear_cdp_events()
    click_by_text("Record audit event")
    expect_text("Audit events: 1", "Admin audit event updates through server-authoritative state")
    check_model_ws_update("Auth workspace audit event", events=1)

    force_socket_reconnect("Auth workspace reconnect", "Admin")
    check("Forbidden" not in str(text()), "Auth workspace reconnect: authenticated route remains allowed")
    audit_before = count_js(AUDIT_COUNT_JS)
    clear_cdp_events()
    click_by_text("Record audit event")
    expect(
        lambda: evl(AUDIT_COUNT_JS) == audit_before + 1,
        f"Auth workspace reconnect: audit click works once ({audit_before}->{audit_before + 1})",
    )
    check_model_ws_update("Auth workspace reconnect audit", events=1)

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
    check('data-testid="login-csrf"' in str(logged_out_html) and str(login_csrf) not in str(logged_out_html),
          "Login renewed the login CSRF token: the next guest page has a new one")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 22. Timeline ==
# A brazier/stream (docs/STREAMS.md): the agent's steps live in the
# browser, not in the model. Every check below watches the DOM nodes of the
# stream's items, not only their text.
TIMELINE_KEYS_JS = (
    'JSON.stringify(Array.from(document.querySelectorAll("#timeline > li"))'
    '.map(function(li){ return li.getAttribute("data-brazier-key"); }))'
)
TIMELINE_STATUS_JS = 'document.querySelector("[data-testid=status]")?.textContent || ""'
TIMELINE_SEED = ["planner:1", "coder:2", "planner:3"]

def timeline_key(seq):
    return ("coder:" if seq % 2 == 0 else "planner:") + str(seq)

def timeline_keys():
    return json.loads(str(evl(TIMELINE_KEYS_JS)))

def timeline_item_js(key):
    return (
        'Array.from(document.querySelectorAll("#timeline > li"))'
        f".find(function(li){{ return li.getAttribute(\"data-brazier-key\") === {json.dumps(key)}; }})"
    )

def timeline_button_js(key, cls):
    return f"({timeline_item_js(key)})?.querySelector({json.dumps('button.' + cls)})"

def timeline_status():
    return str(evl(TIMELINE_STATUS_JS))

def timeline_hook_counts():
    return json.loads(str(evl('JSON.stringify(window.timelineHooks ? window.timelineHooks.counts : null)')))

def timeline_mounted_meters():
    """Mounts minus unmounts: the hooks alive on the page."""
    counts = timeline_hook_counts()
    return counts["mount"] - counts["unmount"]

def timeline_mark_items(label):
    """Keep every item's node, by key, to compare against later."""
    marked = evl(
        "(function(){ window.__tlNodes = {};"
        'Array.from(document.querySelectorAll("#timeline > li")).forEach(function(li){'
        ' window.__tlNodes[li.getAttribute("data-brazier-key")] = li; });'
        "return Object.keys(window.__tlNodes).length; })()"
    )
    check(isinstance(marked, int) and marked > 0, f"{label}: items marked ({marked})")

def timeline_same_node(key):
    return js_true(evl(
        f"(function(){{ var old = window.__tlNodes[{json.dumps(key)}]; var now = {timeline_item_js(key)};"
        " return !!old && old === now && old.isConnected; })()"
    ))

def timeline_click(key, cls, label):
    return js_click(timeline_button_js(key, cls), f"{label}: the {cls} button of {key}")

def timeline_wait_status(fragment, label):
    expect_js(f"({TIMELINE_STATUS_JS}).includes({json.dumps(fragment)})", f"{label}: status shows {fragment!r} ({timeline_status()})")

print("-- 22: Timeline --")
if start_example("timeline", module="main"):
    install_dom_monitor()
    navigate("/")
    reset_dom_monitor()
    check("Agent timeline" in str(text()), "SSR: the timeline page renders")
    check(timeline_keys() == TIMELINE_SEED, f"Join: the seed steps, in order ({timeline_keys()})")
    timeline_wait_status("Next: step 4.", "Join")
    expect_js(
        "window.timelineHooks && window.timelineHooks.counts.mount === 3",
        f"Hook: ChunkMeter mounts once per seed step ({timeline_hook_counts()})",
    )
    check(
        timeline_hook_counts() == {"mount": 3, "update": 0, "unmount": 0},
        f"Hook: nothing updates or unmounts on the join ({timeline_hook_counts()})",
    )
    check_dom_conformance("Timeline hydration")

    # Prepend and append keep every node, and the focus inside an item.
    label = "Prepend and append"
    timeline_mark_items(label)
    focused = evl(f"(function(){{ var b = {timeline_button_js('coder:2', 'pick')}; b.focus(); window.__tlFocus = b; return document.activeElement === b; }})()")
    check(js_true(focused), f"{label}: the Pick button of coder:2 has focus")
    clear_cdp_events()
    click("#prepend")
    expect(lambda: timeline_keys()[:1] == ["coder:4"], f"{label}: the prepended step is first ({timeline_keys()})")
    click("#append")
    expect(lambda: timeline_keys()[-1:] == ["planner:5"], f"{label}: the appended step is last ({timeline_keys()})")
    check(timeline_keys() == ["coder:4", *TIMELINE_SEED, "planner:5"], f"{label}: order ({timeline_keys()})")
    check(all(timeline_same_node(key) for key in TIMELINE_SEED), f"{label}: the seed steps keep their nodes")
    check(js_true(evl("document.activeElement === window.__tlFocus && window.__tlFocus.isConnected")), f"{label}: focus stays on the Pick button of coder:2")
    expect_js("window.timelineHooks.counts.mount === 5", f"{label}: the new steps' meters mount ({timeline_hook_counts()})")
    check(websocket_type_count("Received", "patch") >= 2, f"{label}: the steps arrive as patches")
    timeline_wait_status("Streaming: step 5.", label)

    # A move (a delete and an insert of one key in one update) keeps the
    # node, its hook and the focus inside it.
    label = "Move to top"
    timeline_mark_items(label)
    focused = evl(f"(function(){{ var b = {timeline_button_js('planner:5', 'pick')}; b.focus(); window.__tlFocus = b; return document.activeElement === b; }})()")
    check(js_true(focused), f"{label}: the Pick button of planner:5 has focus")
    timeline_click("planner:5", "top", label)
    expect(lambda: timeline_keys()[:1] == ["planner:5"], f"{label}: planner:5 is first ({timeline_keys()})")
    check(timeline_keys() == ["planner:5", "coder:4", *TIMELINE_SEED], f"{label}: order ({timeline_keys()})")
    check(all(timeline_same_node(key) for key in timeline_keys()), f"{label}: every step keeps its node")
    check(js_true(evl("document.activeElement === window.__tlFocus")), f"{label}: focus stays on the moved step's Pick button")
    check(timeline_hook_counts() == {"mount": 5, "update": 0, "unmount": 0}, f"{label}: the moved meter neither unmounts nor mounts ({timeline_hook_counts()})")

    # An update in place: the key is in the stream, so the step stays first
    # (not appended), keeps its node, and its hook updates.
    label = "Update in place"
    for chunks, words in [(1, "reading"), (2, "reading the"), (3, "reading the file")]:
        click("#chunk")
        expect_js(
            f"({timeline_item_js('planner:5')})?.querySelector('.meter').getAttribute('data-chunks') === {json.dumps(str(chunks))}",
            f"{label}: chunk {chunks} arrives",
        )
        check(f"Step 5 {words}" in str(evl(f"({timeline_item_js('planner:5')}).querySelector('.text').textContent")), f"{label}: the text grows to {words!r}")
    check(timeline_keys()[:1] == ["planner:5"], f"{label}: the step stays where it is ({timeline_keys()})")
    check(timeline_same_node("planner:5"), f"{label}: the step keeps its node")
    check(str(evl(f"({timeline_item_js('planner:5')}).querySelector('.meter').textContent")) == "###", f"{label}: the hook drew the meter, and the morph left it")
    check(timeline_hook_counts() == {"mount": 5, "update": 3, "unmount": 0}, f"{label}: one hook update per chunk ({timeline_hook_counts()})")
    check(js_true(evl('window.timelineHooks.events.slice(-3).every(function(e){ return e[0] === "update" && e[1] === "planner:5"; })')), f"{label}: the updates are planner:5's")

    # Handler ids inside an item are relative to it, so a click after
    # prepends shifted every item runs the clicked item's message.
    label = "Click after prepends"
    click("#prepend")
    expect(lambda: timeline_keys()[:1] == ["coder:6"], f"{label}: coder:6 prepended ({timeline_keys()})")
    click("#prepend")
    expect(lambda: timeline_keys()[:1] == ["planner:7"], f"{label}: planner:7 prepended ({timeline_keys()})")
    clear_cdp_events()
    timeline_click("coder:2", "pick", label)
    timeline_wait_status("Picked: step 2.", label)
    timeline_click("planner:7", "pick", label)
    timeline_wait_status("Picked: step 7.", label)
    check(sent_event_count() == 2, f"{label}: one event per click ({sent_event_count()})")

    # A delete removes the node and unmounts its hook.
    label = "Delete"
    timeline_mark_items(label)
    timeline_click("coder:4", "delete", label)
    expect(lambda: "coder:4" not in timeline_keys(), f"{label}: coder:4 is gone ({timeline_keys()})")
    check(js_true(evl("!window.__tlNodes['coder:4'].isConnected")), f"{label}: its node left the document")
    check(timeline_hook_counts()["unmount"] == 1, f"{label}: its meter unmounted ({timeline_hook_counts()})")
    check(js_true(evl('JSON.stringify(window.timelineHooks.events.slice(-1)) === JSON.stringify([["unmount", "coder:4"]])')), f"{label}: the unmount is coder:4's")
    check(all(timeline_same_node(key) for key in timeline_keys()), f"{label}: the other steps keep their nodes")

    # KeepLast(20): a fill of 25 keeps its last 20 and trims the front; a
    # prepend into the full stream drops the new step; an append trims one.
    label = "Limit"
    click("#fill")
    fill_keys = [timeline_key(seq) for seq in range(13, 33)]
    expect(lambda: timeline_keys() == fill_keys, f"{label}: the last 20 of the fill remain ({timeline_keys()})")
    timeline_wait_status("Next: step 33.", label)
    expect(lambda: timeline_mounted_meters() == 20, f"{label}: 20 meters are mounted ({timeline_hook_counts()})")
    click("#prepend")
    timeline_wait_status("Next: step 34.", label)
    check(timeline_keys() == fill_keys, f"{label}: a prepend into the full stream is dropped ({timeline_keys()[:2]})")
    click("#append")
    expect(lambda: timeline_keys()[-1:] == ["coder:34"], f"{label}: the append is last ({timeline_keys()[-2:]})")
    check(timeline_keys() == fill_keys[1:] + ["coder:34"], f"{label}: the append trimmed the first step ({timeline_keys()[:2]})")
    check(timeline_mounted_meters() == 20, f"{label}: still 20 meters mounted ({timeline_hook_counts()})")

    label = "Reset"
    click("#reset")
    expect(lambda: timeline_keys() == TIMELINE_SEED, f"{label}: the seed again ({timeline_keys()})")
    timeline_wait_status("Picked: none. Streaming: none.", label)
    expect(lambda: timeline_mounted_meters() == 3, f"{label}: 3 meters are mounted ({timeline_hook_counts()})")

    # A reconnect is a new session: init refills the stream, and the join
    # reconciles the page, keeping the node of every step it still holds.
    label = "Reconnect"
    click("#append")
    expect(lambda: timeline_keys() == [*TIMELINE_SEED, "planner:35"], f"{label}: planner:35 appended ({timeline_keys()})")
    timeline_mark_items(label)
    hooks_before = timeline_hook_counts()
    force_socket_reconnect(label, "Agent timeline")
    timeline_wait_status("Next: step 4.", label)
    expect(lambda: timeline_keys() == TIMELINE_SEED, f"{label}: the join holds init's steps only ({timeline_keys()})")
    check(all(timeline_same_node(key) for key in TIMELINE_SEED), f"{label}: the seed steps keep their nodes")
    check(js_true(evl("!window.__tlNodes['planner:35'].isConnected")), f"{label}: planner:35, not in init, left the document")
    hooks_after = timeline_hook_counts()
    check(
        hooks_after == {**hooks_before, "unmount": hooks_before["unmount"] + 1},
        f"{label}: only planner:35's meter unmounts ({hooks_before} -> {hooks_after})",
    )
    check(errors() == "0", f"Zero errors ({error_list()})")

    # A frame the server never sends: an insert whose item the decoder
    # refuses. One console.error, a 4000 close, a reconnect and a refill.
    label = "Forged frame"
    clear_cdp_events()
    clear_browser_errors()
    forged = json.dumps({
        "type": "patch", "ops": [], "version": 1_000_000, "ack_clock": 0,
        "streams": [{
            "name": "timeline", "keep": "last", "limit": 20, "reset": False, "deletes": [],
            "inserts": [{"key": "coder:900", "at": 0, "item": {"bogus": True}}],
        }],
    })
    delivered = evl(f"window.__brazierDeliverFrameForTest ? window.__brazierDeliverFrameForTest({json.dumps(forged)}) : 'missing'")
    check(str(delivered) != "missing", f"{label}: the frame test hook is available")
    expect(lambda: cdp_method_count("Network.webSocketClosed") > 0, f"{label}: the socket closes")
    expect(lambda: len(console_messages("warning", "WebSocket closed (code 4000")) == 1, f"{label}: the socket closes with 4000 ({console_messages('warning', 'WebSocket closed')})")
    reconnected = wait_for_js(f"{APP_READY_JS} && ({TIMELINE_STATUS_JS}).includes('Next: step 4.')", timeout=2 * WAIT_SECONDS)
    check(reconnected, f"{label}: the client reconnects")
    expect(lambda: websocket_type_count("Sent", "join") == 1, f"{label}: one new join")
    check(timeline_keys() == TIMELINE_SEED, f"{label}: the forged step never rendered ({timeline_keys()})")
    error_count = count_js("window.__e.length")
    error_text = str(evl("window.__e.join(' | ')"))
    check(error_count == 1 and "Stream fault" in error_text and "item_render_failed" in error_text, f"{label}: exactly one console.error, the stream fault ({error_count}: {error_text[:200]})")
    check(not browser_errors, f"{label}: no other browser error ({browser_errors})")
    clear_browser_errors()

    # A click on a server-rendered step before the join answers is queued
    # and replayed once the join's model_sync renders. The test holds the
    # first connect instead of timing a slow network.
    label = "Click before hydration"
    clear_cdp_events()
    hold = cdp_checked("Page.addScriptToEvaluateOnNewDocument", {"source": "window.__BRAZIER_HOLD_CONNECT_FOR_TEST = true;"})
    hold_id = hold["result"]["identifier"] if hold else None
    marker = json.dumps(f"nav-{time.time_ns()}")
    evl(f"window.__brazierCdpNav = {marker}; 0")
    cdp("Page.navigate", {"url": f"http://localhost:{BRAZIER_PORT}/"})
    held = wait_for_js(
        f'window.__brazierCdpNav !== {marker} && document.readyState === "complete"'
        ' && typeof window.__brazierReleaseConnectForTest === "function"'
        ' && window.timelineHooks !== undefined'
    )
    if hold_id is not None:
        cdp_checked("Page.removeScriptToEvaluateOnNewDocument", {"identifier": hold_id})
    check(held, f"{label}: the page loads with the connect held")
    check(str(evl("window.__brazierWsState()")) == "-1", f"{label}: no socket yet")
    check(timeline_keys() == TIMELINE_SEED, f"{label}: SSR renders the seed steps ({timeline_keys()})")
    timeline_mark_items(label)
    timeline_click("coder:2", "pick", label)
    check("Picked: none." in timeline_status(), f"{label}: nothing ran before hydration ({timeline_status()})")
    released = evl("window.__brazierReleaseConnectForTest()")
    check(str(released) == "0", f"{label}: the connect starts ({released})")
    expect_js(APP_READY_JS, f"{label}: the client joins")
    timeline_wait_status("Picked: step 2.", label)
    expect(lambda: len(console_messages("log", "Replayed 1 event(s) from before hydration")) == 1, f"{label}: the client replayed the click")
    check(all(timeline_same_node(key) for key in TIMELINE_SEED), f"{label}: the join kept the server-rendered steps' nodes")
    sent_events = [p for p in websocket_json_payloads("Sent") if p.get("type") in ("event", "event_batch")]
    check(len(sent_events) == 1, f"{label}: one event sent ({sent_events})")
    expect_js("window.timelineHooks.counts.mount === 3", f"{label}: the meters mount on the join ({timeline_hook_counts()})")
    check(errors() == "0", f"Zero errors ({error_list()})")
stop_server(); print()

# == 23. Rows (browser bench of the DOM morph) ==
# The client's DOM work for a 1000-row list, in Chrome: the half of the
# client's patch path the node bench (client_bench.gleam) cannot time. Each
# Relabel changes every tenth label and moves the selection, the node
# bench's patch. A PerformanceObserver in the page collects the client's
# User Timing measures:
#   brazier:morph  the morph of the page, the event listeners and the
#                  stream containers of one render, without the view
#   brazier:patch  handlePatch, from the patch to the rendered page, without
#                  the frame's JSON.parse
# They are reported as the bench suite reports them (measure.gleam's
# percentiles_by_round: the timed samples cut into 5 rounds, the median over
# rounds of each round's median and nearest-rank p99), in µs, and written
# in the bench report format to build/bench/cdp_morph_<viewport>.json. They
# are not gated: there is no baseline for them yet. performance.now() in a
# page that is not cross-origin isolated is coarsened to 100 µs, which is
# small next to these timings.
ROWS_COUNT = 1000
ROWS_WARMUP = 10
ROWS_TIMED = 100
ROWS_BENCH_ROUNDS = 5
ROWS_STATUS_JS = 'document.querySelector("[data-testid=status]")?.textContent || ""'
ROWS_MEASURES_JS = "JSON.stringify(window.__cdpRowsMeasures ? {morph: window.__cdpRowsMeasures.morph.length, patch: window.__cdpRowsMeasures.patch.length, render: window.__cdpRowsMeasures.render.length} : null)"

def rows_label(row_id):
    return evl(f'document.querySelector("#rows > li[data-row=\\"{row_id}\\"] > .label")?.textContent || ""')

def rows_selected_ids():
    return evl('JSON.stringify(Array.from(document.querySelectorAll("#rows > li.selected")).map(function(li){ return li.getAttribute("data-row"); }))')

def rows_relabel_round(expected_round, label):
    """Click Relabel and wait for round `expected_round` to render and for
    its measures to reach the observer (an observer is called in a later
    task than the render)."""
    selected = expected_round * 7 % ROWS_COUNT + 1
    before = json.loads(evl(ROWS_MEASURES_JS))
    if not click("#relabel"):
        return False
    rendered = wait_for_js(
        f"({ROWS_STATUS_JS}) === {json.dumps(f'Round {expected_round}, selected {selected}')}"
        f" && window.__cdpRowsMeasures.patch.length === {before['patch'] + 1}"
        f" && window.__cdpRowsMeasures.morph.length >= {before['morph'] + 1}"
    )
    after = json.loads(evl(ROWS_MEASURES_JS))
    check(rendered, f"{label}: round {expected_round} renders and is measured ({evl(ROWS_STATUS_JS)}, {before} -> {after})")
    if not rendered:
        return False
    # One render per patch: no other render may share the morph samples.
    one_each = all(after[k] == before[k] + 1 for k in ("morph", "patch", "render"))
    check(one_each, f"{label}: round {expected_round} is one patch, one render and one morph ({before} -> {after})")
    return one_each

def bench_percentiles(name, samples):
    """measure.gleam's percentiles_by_round, so the numbers mean what the
    suite's do."""
    count = len(samples)
    check(count >= ROWS_BENCH_ROUNDS and count % ROWS_BENCH_ROUNDS == 0, f"{name}: {count} samples split into {ROWS_BENCH_ROUNDS} equal rounds")
    size = count // ROWS_BENCH_ROUNDS
    medians, p99s = [], []
    for start in range(0, count, size):
        sorted_round = sorted(samples[start:start + size])
        n = len(sorted_round)
        medians.append(sorted_round[(n - 1) // 2] if n % 2 == 1 else (sorted_round[n // 2 - 1] + sorted_round[n // 2]) / 2)
        p99s.append(sorted_round[(99 * n + 99) // 100 - 1])
    def median(values):
        ordered = sorted(values)
        n = len(ordered)
        return ordered[(n - 1) // 2] if n % 2 == 1 else (ordered[n // 2 - 1] + ordered[n // 2]) / 2
    return median(medians), median(p99s)

def bench_cpu_model():
    """The CPU model, as brazier_bench_ffi:machine/0 reads it."""
    if sys.platform == "darwin":
        out = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], stdout=subprocess.PIPE, text=True, check=False)
        return out.stdout.strip() if out.returncode == 0 and out.stdout.strip() else "unknown"
    if sys.platform.startswith("linux"):
        try:
            with open("/proc/cpuinfo", "r", encoding="utf-8") as fh:
                for line in fh:
                    key, _, value = line.partition(":")
                    if key.strip() == "model name":
                        return value.strip()
        except OSError:
            return "unknown"
    return "unknown"

def write_rows_bench_report(metrics):
    version = cdp_checked("Browser.getVersion")
    browser = version["result"]["product"] if version else "unknown"
    machine = {
        "browser": browser,
        "cpu": bench_cpu_model(),
        "logical_processors": str(os.cpu_count()),
        "os": f"{sys.platform}/{os.uname().release}",
        "viewport": VIEWPORT,
    }
    report = {
        "machine": dict(sorted(machine.items())),
        "metrics": [{"name": name, "unit": "us", "better": "lower", "value": value} for name, value in metrics],
    }
    path = os.path.join(ROOT, "build", "bench", f"cdp_morph_{VIEWPORT}.json")
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(report, fh)
            fh.write("\n")
    except OSError as exc:
        check(False, f"Rows bench: report written to {path} ({exc})")
        return
    check(True, f"Rows bench: report written to {os.path.relpath(path, ROOT)}")

print("-- 23: Rows --")
if start_example("rows"):
    install_dom_monitor()
    navigate("/")
    reset_dom_monitor()
    check(count_js('document.querySelectorAll("#rows > li").length') == ROWS_COUNT, f"SSR: {ROWS_COUNT} rows render")
    check(str(evl(ROWS_STATUS_JS)) == "Round 0, selected 0", f"SSR: round 0, nothing selected ({evl(ROWS_STATUS_JS)})")
    check(rows_label(10) == "row label number 10", "SSR: row 10 has its first label")
    installed = evl(
        "(function(){"
        "window.__cdpRowsMeasures = {morph: [], patch: [], render: []};"
        "new PerformanceObserver(function(list){"
        " list.getEntries().forEach(function(e){"
        '  var kind = e.name.slice("brazier:".length);'
        "  if (e.name.indexOf(\"brazier:\") === 0 && Object.prototype.hasOwnProperty.call(window.__cdpRowsMeasures, kind)) window.__cdpRowsMeasures[kind].push(e.duration * 1000);"
        " });"
        '}).observe({type: "measure"});'
        'return "observing";})()'
    )
    check(installed == "observing", f"Rows: the measure observer is installed ({installed})")

    # Correctness first: the morph keeps every row's node, changes every
    # tenth label and moves the selection.
    label = "Rows relabel"
    marked = evl('(function(){ var rows = Array.from(document.querySelectorAll("#rows > li")); rows.forEach(function(li){ li.__cdpRow = true; }); window.__cdpRows = rows; return rows.length; })()')
    check(marked == ROWS_COUNT, f"{label}: rows marked ({marked})")
    clear_cdp_events()
    rows_relabel_round(1, label)
    check(rows_label(10) == "label 10 round 1", f"{label}: row 10 is relabelled ({rows_label(10)})")
    check(rows_label(1000) == "label 1000 round 1", f"{label}: row 1000 is relabelled ({rows_label(1000)})")
    check(rows_label(11) == "row label number 11", f"{label}: row 11 keeps its label ({rows_label(11)})")
    check(rows_selected_ids() == '["8"]', f"{label}: row 8 alone is selected ({rows_selected_ids()})")
    check(count_js('window.__cdpRows.filter(function(li){ return !li.isConnected; }).length') == 0, f"{label}: every row keeps its node")
    check(count_js('document.querySelectorAll("#rows > li").length') == ROWS_COUNT, f"{label}: still {ROWS_COUNT} rows")
    check_model_ws_update(label, events=1)
    # Hydration and one relabel only: the bench below changes the page as
    # fast as the client renders, which is not a page's layout.
    check_dom_conformance("Rows", max_bucket=200)

    label = "Rows select"
    clear_cdp_events()
    click('#rows > li[data-row="500"]')
    expect(lambda: str(evl(ROWS_STATUS_JS)) == "Round 1, selected 500", f"{label}: row 500 is selected ({evl(ROWS_STATUS_JS)})")
    check(rows_selected_ids() == '["500"]', f"{label}: row 500 alone has the class ({rows_selected_ids()})")
    check_model_ws_update(label, events=1)

    # The bench: warm-up rounds, then the timed ones. Round 1 above is the
    # first; the select took one more patch, so the measures are counted
    # from here.
    label = "Rows bench"
    ok = True
    for n in range(2, 2 + ROWS_WARMUP):
        ok = ok and rows_relabel_round(n, label)
    start = json.loads(evl(ROWS_MEASURES_JS))
    for n in range(2 + ROWS_WARMUP, 2 + ROWS_WARMUP + ROWS_TIMED):
        ok = ok and rows_relabel_round(n, label)
        if not ok:
            break
    if ok:
        samples = json.loads(evl("JSON.stringify(window.__cdpRowsMeasures)"))
        morph = samples["morph"][start["morph"]:]
        patch = samples["patch"][start["patch"]:]
        check(len(morph) == ROWS_TIMED and len(patch) == ROWS_TIMED, f"{label}: {ROWS_TIMED} timed samples of each ({len(morph)} morph, {len(patch)} patch)")
        check(all(m > 0 and p >= m for m, p in zip(morph, patch)), f"{label}: every patch takes longer than its morph")
        metrics = []
        for name, values in (("browser.morph.rows_1000", morph), ("browser.patch.rows_1000", patch)):
            median, p99 = bench_percentiles(name, values)
            metrics.append((name + ".median", median))
            metrics.append((name + ".p99", p99))
            print(f"  {name}: median {median:.0f} us, p99 {p99:.0f} us ({VIEWPORT}, {ROWS_TIMED} updates after {ROWS_WARMUP} warm-up)")
        write_rows_bench_report(metrics)
    check(rows_label(10) == f"label 10 round {1 + ROWS_WARMUP + ROWS_TIMED}", f"{label}: the last round's labels are on the page ({rows_label(10)})")
    check(count_js('window.__cdpRows.filter(function(li){ return !li.isConnected; }).length') == 0, f"{label}: every row kept its node through every round")
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
