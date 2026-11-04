import brazier/await
import brazier/debug
import brazier/log_capture.{Captured}
import gleam/erlang/process
import gleam/string

pub fn stats_returns_valid_data_test() {
  let s = debug.stats()
  let assert True = s.process_count > 0
  let assert True = s.memory_bytes > 0
  let assert True = s.uptime_seconds >= 0
}

pub fn is_alive_test() {
  let pid = process.self()
  let assert True = debug.is_alive(pid)
}

pub fn is_alive_is_false_for_an_exited_process_test() {
  let pid = process.spawn_unlinked(fn() { Nil })
  await.expect_down(pid, "the spawned process")
  let assert False = debug.is_alive(pid)
}

pub fn log_stats_logs_one_info_line_test() {
  let #(Nil, logs) = log_capture.capture(debug.log_stats)
  let assert [Captured(level: "info", message:)] = logs
  let assert True =
    string.starts_with(message, "[brazier.debug] Processes: ")
    && string.contains(message, " | Memory: ")
    && string.contains(message, "MB | Uptime: ")
    && string.ends_with(message, "s")
    as message
}
