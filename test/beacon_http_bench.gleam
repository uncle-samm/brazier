//// HTTP request-handling benchmark.
////
//// Run with: `gleam run -m beacon_http_bench`
////
//// Starts a listener whose API handler answers `/bench` with a short body,
//// then drives it with keep-alive clients over loopback. Each round runs
//// `clients` connections that send `requests` sequential requests each;
//// the median round is reported as requests per second and mean
//// microseconds per request per connection.
////
//// No telemetry handler is attached, so this measures the cost of
//// Beacon's instrumentation when nobody listens. Telemetry is started
//// first, as in a real application.
////
//// This module is not a test (no `_test` suffix) so gleeunit never runs it.

import beacon/telemetry
import beacon/transport
import beacon/transport/server.{type Connection, Bytes}
import gleam/bytes_tree
import gleam/float
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string

const clients = 8

const requests = 5000

const warmup_rounds = 2

const rounds = 7

@external(erlang, "beacon_http_bench_ffi", "run")
fn run_clients(port: Int, clients: Int, requests: Int) -> Int

fn handler(
  req: Request(Connection),
) -> option.Option(response.Response(server.ResponseBody)) {
  case req.path {
    "/bench" ->
      Some(
        response.new(200)
        |> response.set_header("content-type", "text/plain")
        |> response.set_body(Bytes(bytes_tree.from_string("ok"))),
      )
    _ -> None
  }
}

pub fn main() -> Nil {
  let assert Ok(Nil) = telemetry.start()
    as "telemetry must start for the benchmark"
  let config =
    transport.TransportConfig(
      port: 0,
      on_connect: fn(_id, _subject) { Nil },
      on_event: fn(_id, _msg) { Nil },
      on_disconnect: fn(_id) { Nil },
      page_html: None,
      middlewares: [],
      static_config: None,
      runtime_factory: None,
      ws_auth: None,
      ssr_factory: None,
      security_limits: transport.SecurityLimits(
        ..transport.default_security_limits(),
        max_keepalive_requests: requests + 1,
      ),
      api_handler: Some(handler),
    )
  let assert Ok(listener) = transport.start_listener(config)
    as "benchmark listener must bind an OS-assigned port"
  let port = server.get_port(listener)
  int.range(from: 0, to: warmup_rounds, with: Nil, run: fn(_, _) {
    let _elapsed = run_clients(port, clients, requests)
    Nil
  })
  let samples =
    int.range(from: 0, to: rounds, with: [], run: fn(acc, _) {
      [run_clients(port, clients, requests), ..acc]
    })
    |> list.sort(int.compare)
  let assert Ok(median_us) = list.drop(samples, rounds / 2) |> list.first
    as "rounds is positive"
  let total = clients * requests
  let per_second =
    int.to_float(total) /. { int.to_float(median_us) /. 1_000_000.0 }
  let per_request_us = int.to_float(median_us) /. int.to_float(requests)
  io.println(
    "[http bench] "
    <> int.to_string(clients)
    <> " keep-alive clients x "
    <> int.to_string(requests)
    <> " requests, median of "
    <> int.to_string(rounds)
    <> " rounds: "
    <> float.to_string(float.to_precision(per_second, 0))
    <> " req/s, "
    <> float.to_string(float.to_precision(per_request_us, 2))
    <> " us/request/connection; rounds (us): "
    <> string.join(list.map(samples, int.to_string), ", "),
  )
  server.stop(listener)
}
