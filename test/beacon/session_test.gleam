import beacon/session
import gleam/option.{None, Some}

pub fn create_session_test() {
  let store = session.new_store("test_create")
  let sess = session.create(store)
  // Session should have a non-empty ID
  let assert True = sess.id != ""
}

pub fn get_session_test() {
  let store = session.new_store("test_get")
  let sess = session.create(store)
  // Should be retrievable
  let assert Some(found) = session.get(store, sess.id)
  let assert True = found.id == sess.id
}

pub fn get_missing_session_test() {
  let store = session.new_store("test_missing")
  let assert None = session.get(store, "nonexistent")
}

pub fn set_and_get_value_test() {
  let store = session.new_store("test_setget")
  let sess = session.create(store)
  let assert Ok(sess) = session.set(store, sess, "name", "Alice")
  let assert Some("Alice") = session.get_value(sess, "name")
}

pub fn delete_session_test() {
  let store = session.new_store("test_delete")
  let sess = session.create(store)
  session.delete(store, sess.id)
  let assert None = session.get(store, sess.id)
}

pub fn session_persists_in_store_test() {
  let store = session.new_store("test_persist")
  let sess = session.create(store)
  let assert Ok(_sess) = session.set(store, sess, "key", "value")
  // Re-fetch from store
  let assert Some(found) = session.get(store, sess.id)
  let assert Some("value") = session.get_value(found, "key")
}
