/// Session-bound CSRF tokens: random, compared in constant time, consumed
/// exactly once even under concurrent use, and not burnt by a wrong guess.
import beacon/form
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/set
import gleam/string

fn store(tag: String) -> form.CsrfStore {
  form.create_csrf_store("csrf_sec_" <> tag <> "_" <> unique_ref())
}

pub fn tokens_are_256_random_bits_test() {
  let s = store("random")
  let tokens =
    list.map(seq(100), fn(i) {
      form.generate_session_csrf(s, "session_" <> int.to_string(i), "same")
    })
  list.each(tokens, fn(token) {
    let assert 64 = string.length(token)
    let assert True =
      list.all(string.to_graphemes(token), fn(g) {
        string.contains("0123456789abcdef", g)
      })
  })
  let assert 100 = set.size(set.from_list(tokens))
  // Form tokens do not derive from the (shared, possibly weak) secret.
  let assert True = { form.new("").csrf_token } != { form.new("").csrf_token }
}

pub fn a_wrong_guess_does_not_consume_the_token_test() {
  let s = store("guess")
  let token = form.generate_session_csrf(s, "sess", "k")
  let assert False = form.verify_session_csrf(s, "sess", "wrong")
  let assert False =
    form.verify_session_csrf(s, "sess", string.drop_end(token, 1))
  let assert False = form.verify_session_csrf(s, "sess", token <> "0")
  let assert False = form.verify_session_csrf(s, "sess", "")
  let assert False =
    form.verify_session_csrf(s, "sess", string.uppercase(token))
  let assert True = form.verify_session_csrf(s, "sess", token)
  let assert False = form.verify_session_csrf(s, "sess", token)
}

pub fn a_new_token_replaces_the_old_one_test() {
  let s = store("replace")
  let old = form.generate_session_csrf(s, "sess", "k")
  let new = form.generate_session_csrf(s, "sess", "k")
  let assert False = form.verify_session_csrf(s, "sess", old)
  let assert True = form.verify_session_csrf(s, "sess", new)
}

pub fn concurrent_verifications_accept_a_token_once_test() {
  let s = store("race")
  let token = form.generate_session_csrf(s, "sess", "k")
  let results = process.new_subject()
  list.each(seq(64), fn(_) {
    process.spawn(fn() {
      process.send(results, form.verify_session_csrf(s, "sess", token))
    })
  })
  let outcomes =
    list.map(seq(64), fn(_) {
      let assert Ok(outcome) = process.receive(results, 2000)
        as "every verifier reports"
      outcome
    })
  let assert 1 = list.count(outcomes, fn(ok) { ok })
}

fn seq(n: Int) -> List(Int) {
  int.range(from: 0, to: n, with: [], run: fn(acc, i) { [i, ..acc] })
  |> list.reverse
}

@external(erlang, "beacon_test_ffi", "unique_ref")
fn unique_ref() -> String
