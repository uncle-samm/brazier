/// Simulation metrics — ETS-backed atomic counters for cross-process
/// metric accumulation. Any spawned test process can increment counters
/// without locking. Latency samples are stored in an ETS bag table.
import gleam/erlang/process.{type Pid}
import gleam/float
import gleam/int
import gleam/list

/// Opaque handle to the metrics ETS tables (counters + latencies).
pub type MetricsTable

/// Collected simulation metrics.
pub type SimMetrics {
  SimMetrics(
    events_sent: Int,
    events_acked: Int,
    events_failed: Int,
    connections_opened: Int,
    connections_closed: Int,
    connections_failed: Int,
    latencies_us: List(Int),
    /// Wire efficiency tracking
    bytes_sent: Int,
    bytes_received: Int,
    patches_received: Int,
    model_syncs_received: Int,
    mounts_received: Int,
    last_payload: String,
  )
}

/// Create a new metrics table pair.
pub fn new() -> MetricsTable {
  new_metrics_ffi()
}

/// Atomically increment a counter by 1.
pub fn increment(table: MetricsTable, key: String) -> Nil {
  increment_ffi(table, key)
}

/// Atomically increment a counter by N.
pub fn increment_by(table: MetricsTable, key: String, amount: Int) -> Nil {
  increment_by_ffi(table, key, amount)
}

/// Store the latest received wire payload for state correctness assertions.
pub fn record_payload(table: MetricsTable, payload: String) -> Nil {
  record_payload_ffi(table, payload)
}

/// Record a latency sample in microseconds.
pub fn record_latency(table: MetricsTable, latency_us: Int) -> Nil {
  record_latency_ffi(table, latency_us)
}

/// Remember the start time for one in-flight event in the current worker.
pub fn mark_event_send_start(sent_at_us: Int) -> Nil {
  mark_event_send_start_ffi(sent_at_us)
}

/// Take and clear the current worker's in-flight event start time.
/// `Error(Nil)` when no event is in flight.
pub fn take_event_send_start() -> Result(Int, Nil) {
  take_event_send_start_ffi()
}

/// Get monotonic time in microseconds (for latency measurement).
pub fn now_us() -> Int {
  monotonic_us_ffi()
}

/// Get current memory usage in bytes.
pub fn snapshot_memory() -> Int {
  snapshot_memory_ffi()
}

/// Get current process count.
pub fn snapshot_processes() -> Int {
  snapshot_processes_ffi()
}

/// Every live pid, to pass to `describe_new_processes` later.
pub fn snapshot_pids() -> List(Pid) {
  snapshot_pids_ffi()
}

/// Describe each process alive now that is not in `before`: registered
/// name, initial call, current function, queue length.
pub fn describe_new_processes(before: List(Pid)) -> String {
  describe_new_processes_ffi(before)
}

/// Collect all metrics from the tables.
pub fn collect(table: MetricsTable) -> SimMetrics {
  let #(
    sent,
    acked,
    failed,
    opened,
    closed,
    conn_failed,
    latencies,
    bytes_s,
    bytes_r,
    patches,
    syncs,
    mounts,
    last_payload,
  ) = collect_ffi(table)
  SimMetrics(
    events_sent: sent,
    events_acked: acked,
    events_failed: failed,
    connections_opened: opened,
    connections_closed: closed,
    connections_failed: conn_failed,
    latencies_us: latencies,
    bytes_sent: bytes_s,
    bytes_received: bytes_r,
    patches_received: patches,
    model_syncs_received: syncs,
    mounts_received: mounts,
    last_payload: last_payload,
  )
}

/// Destroy the metrics tables.
pub fn destroy(table: MetricsTable) -> Nil {
  destroy_ffi(table)
}

/// Calculate percentile from a list of values.
/// p is 0.0-1.0 (e.g., 0.5 for p50, 0.99 for p99).
pub fn percentile(values: List(Int), p: Float) -> Int {
  case values {
    [] -> 0
    _ -> {
      let sorted = list.sort(values, int.compare)
      let len = list.length(sorted)
      let idx_float = int.to_float(len - 1) *. p
      let idx = float.truncate(idx_float)
      let idx = case idx >= len {
        True -> len - 1
        False -> idx
      }
      case list.drop(sorted, idx) {
        [val, ..] -> val
        [] -> 0
      }
    }
  }
}

// --- FFI ---

@external(erlang, "beacon_sim_ffi", "new_metrics")
fn new_metrics_ffi() -> MetricsTable

@external(erlang, "beacon_sim_ffi", "increment")
fn increment_ffi(table: MetricsTable, key: String) -> Nil

@external(erlang, "beacon_sim_ffi", "increment_by")
fn increment_by_ffi(table: MetricsTable, key: String, amount: Int) -> Nil

@external(erlang, "beacon_sim_ffi", "record_latency")
fn record_latency_ffi(table: MetricsTable, latency_us: Int) -> Nil

@external(erlang, "beacon_sim_ffi", "mark_event_send_start")
fn mark_event_send_start_ffi(sent_at_us: Int) -> Nil

@external(erlang, "beacon_sim_ffi", "take_event_send_start")
fn take_event_send_start_ffi() -> Result(Int, Nil)

@external(erlang, "beacon_sim_ffi", "record_payload")
fn record_payload_ffi(table: MetricsTable, payload: String) -> Nil

@external(erlang, "beacon_sim_ffi", "collect")
fn collect_ffi(
  table: MetricsTable,
) -> #(Int, Int, Int, Int, Int, Int, List(Int), Int, Int, Int, Int, Int, String)

@external(erlang, "beacon_sim_ffi", "destroy")
fn destroy_ffi(table: MetricsTable) -> Nil

@external(erlang, "beacon_sim_ffi", "monotonic_us")
fn monotonic_us_ffi() -> Int

@external(erlang, "beacon_sim_ffi", "snapshot_memory")
fn snapshot_memory_ffi() -> Int

@external(erlang, "beacon_sim_ffi", "snapshot_processes")
fn snapshot_processes_ffi() -> Int

@external(erlang, "beacon_sim_ffi", "snapshot_pids")
fn snapshot_pids_ffi() -> List(Pid)

@external(erlang, "beacon_sim_ffi", "describe_new_processes")
fn describe_new_processes_ffi(before: List(Pid)) -> String
