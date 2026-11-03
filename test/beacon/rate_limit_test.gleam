import beacon/await
import beacon/rate_limit
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string

fn start(prefix: String, max_requests: Int) -> rate_limit.RateLimiter {
  let assert Ok(limiter) =
    rate_limit.new(
      prefix <> unique_id(),
      rate_limit.RateLimitConfig(max_requests: max_requests, window_seconds: 60),
    )
  limiter
}

pub fn allowed_within_limit_test() {
  let limiter = start("test_allow_", 5)
  let assert rate_limit.Allowed(remaining: 4) =
    rate_limit.check(limiter, "127.0.0.1")
}

pub fn rate_limited_over_limit_test() {
  let limiter = start("test_limit_", 3)
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "10.0.0.1")
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "10.0.0.1")
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "10.0.0.1")
  let assert rate_limit.RateLimited = rate_limit.check(limiter, "10.0.0.1")
}

pub fn different_keys_independent_test() {
  let limiter = start("test_keys_", 2)
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "ip_a")
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "ip_a")
  let assert rate_limit.RateLimited = rate_limit.check(limiter, "ip_a")
  // Different key should still be allowed
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "ip_b")
}

pub fn remaining_decreases_test() {
  let limiter = start("test_rem_", 5)
  let assert rate_limit.Allowed(remaining: 4) =
    rate_limit.check(limiter, "test_ip")
  let assert rate_limit.Allowed(remaining: 3) =
    rate_limit.check(limiter, "test_ip")
  let assert rate_limit.Allowed(remaining: 2) =
    rate_limit.check(limiter, "test_ip")
}

// --- Configuration errors ---

pub fn invalid_settings_are_refused_test() {
  let assert Error(reason) =
    rate_limit.new(
      "bad_max_" <> unique_id(),
      rate_limit.RateLimitConfig(max_requests: 0, window_seconds: 60),
    )
  let assert True = string.contains(reason, "max_requests")
  let assert Error(reason) =
    rate_limit.new(
      "bad_window_" <> unique_id(),
      rate_limit.RateLimitConfig(max_requests: 1, window_seconds: 0),
    )
  let assert True = string.contains(reason, "window_seconds")
  let assert Error(reason) =
    rate_limit.new_with_max_keys(
      "bad_keys_" <> unique_id(),
      rate_limit.RateLimitConfig(max_requests: 1, window_seconds: 60),
      0,
    )
  let assert True = string.contains(reason, "max_keys")
}

pub fn invalid_name_is_refused_test() {
  let assert Error(_) =
    rate_limit.new(
      "spaces are not allowed",
      rate_limit.RateLimitConfig(max_requests: 1, window_seconds: 60),
    )
}

/// Regression: a second limiter with the same name used to crash the
/// caller with an ETS badarg.
pub fn duplicate_name_is_an_error_test() {
  let name = "dup_" <> unique_id()
  let config = rate_limit.RateLimitConfig(max_requests: 1, window_seconds: 60)
  let assert Ok(_first) = rate_limit.new(name, config)
  let assert Error(reason) = rate_limit.new(name, config)
  let assert True = string.contains(reason, "already exists")
}

// --- Reset ---

/// Regression: reset deleted `key` while counters are stored per window,
/// so it never reset anything.
pub fn reset_clears_the_key_test() {
  let limiter = start("test_reset_", 1)
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "k")
  let assert rate_limit.RateLimited = rate_limit.check(limiter, "k")
  let assert Ok(Nil) = rate_limit.reset(limiter, "k")
  let assert rate_limit.Allowed(remaining: 0) = rate_limit.check(limiter, "k")
}

// --- Bounded memory ---

pub fn key_cap_refuses_new_keys_but_keeps_counting_known_ones_test() {
  let assert Ok(limiter) =
    rate_limit.new_with_max_keys(
      "test_cap_" <> unique_id(),
      rate_limit.RateLimitConfig(max_requests: 10, window_seconds: 60),
      2,
    )
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "a")
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "b")
  // At the cap: a new client is refused (fail closed) ...
  let assert rate_limit.RateLimited = rate_limit.check(limiter, "c")
  let assert rate_limit.RateLimited = rate_limit.check(limiter, "d")
  // ... the table did not grow ...
  let assert Ok(2) = rate_limit.key_count(limiter)
  // ... and known clients are still served.
  let assert rate_limit.Allowed(remaining: 8) = rate_limit.check(limiter, "a")
}

pub fn key_flood_stays_bounded_test() {
  let assert Ok(limiter) =
    rate_limit.new_with_max_keys(
      "test_flood_" <> unique_id(),
      rate_limit.RateLimitConfig(max_requests: 10, window_seconds: 60),
      100,
    )
  list.each(seq(1, 5000), fn(n) {
    rate_limit.check(limiter, "spoofed-" <> int.to_string(n))
  })
  let assert Ok(count) = rate_limit.key_count(limiter)
  let assert True = count <= 100
}

pub fn sweep_deletes_expired_windows_test() {
  let assert Ok(limiter) =
    rate_limit.new(
      "test_sweep_" <> unique_id(),
      rate_limit.RateLimitConfig(max_requests: 1, window_seconds: 1),
    )
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "a")
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "b")
  // Let the 1s window roll over, then sweep. The periodic sweep may have
  // removed some counters first, so only an upper bound is exact. The sleep
  // is the thing under test: windows are wall-clock seconds, and sleeping
  // past one cannot race, since a slow scheduler only makes it older.
  process.sleep(1100)
  let assert Ok(deleted) = rate_limit.sweep(limiter)
  let assert True = deleted <= 2
  let assert Ok(0) = rate_limit.key_count(limiter)
  // A new window starts a fresh budget.
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "a")
}

pub fn periodic_sweep_runs_without_being_asked_test() {
  let assert Ok(limiter) =
    rate_limit.new(
      "test_periodic_" <> unique_id(),
      rate_limit.RateLimitConfig(max_requests: 5, window_seconds: 1),
    )
  let owner = rate_limit.owner(limiter)
  let sweeps = await.watch_info(owner, "sweep")
  let assert rate_limit.Allowed(..) = rate_limit.check(limiter, "a")
  let assert Ok(1) = rate_limit.key_count(limiter)
  // Sweeps are a second apart and the counter's window ends at most a
  // second after the check, so the second periodic sweep after the check
  // runs in a later window and deletes it.
  await.expect_info(sweeps, owner, "the first periodic sweep")
  await.expect_info(sweeps, owner, "the second periodic sweep")
  let assert Ok(0) = rate_limit.key_count(limiter)
}

// --- Ownership ---

pub fn owner_stops_when_creator_exits_and_checks_fail_closed_test() {
  let reply = process.new_subject()
  let creator =
    process.spawn(fn() {
      let assert Ok(limiter) =
        rate_limit.new(
          "test_owner_" <> unique_id(),
          rate_limit.RateLimitConfig(max_requests: 100, window_seconds: 60),
        )
      process.send(reply, limiter)
    })
  let assert Ok(limiter) = process.receive(reply, 2000)
  await.expect_down(creator, "the limiter's creator")
  await.expect_down(rate_limit.owner(limiter), "the limiter's owner")
  // The table is gone with its owner: requests are refused, not let through.
  let assert rate_limit.RateLimited = rate_limit.check(limiter, "x")
  let assert Error(Nil) = rate_limit.key_count(limiter)
  let assert Error(Nil) = rate_limit.reset(limiter, "x")
}

// --- Concurrency ---

/// The first request of a key from many processes at once must neither
/// lose counts nor reset the counter.
pub fn concurrent_checks_count_exactly_test() {
  let limiter = start("test_conc_", 500)
  let results = process.new_subject()
  list.each(seq(1, 50), fn(_) {
    process.spawn(fn() {
      let allowed =
        seq(1, 20)
        |> list.filter(fn(_) {
          case rate_limit.check(limiter, "shared") {
            rate_limit.Allowed(..) -> True
            rate_limit.RateLimited -> False
          }
        })
        |> list.length
      process.send(results, allowed)
    })
  })
  let total =
    seq(1, 50)
    |> list.map(fn(_) {
      let assert Ok(n) = process.receive(results, 5000)
      n
    })
    |> int.sum
  let assert 500 = total
}

fn unique_id() -> String {
  int.to_string(do_unique())
}

@external(erlang, "erlang", "unique_integer")
fn do_unique() -> Int

/// Inclusive integer sequence.
fn seq(from: Int, to: Int) -> List(Int) {
  int.range(from: to, to: from - 1, with: [], run: fn(acc, i) { [i, ..acc] })
}
