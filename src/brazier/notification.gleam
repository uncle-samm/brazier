import gleam/dynamic.{type Dynamic}

pub type Notification {
  Notification(topic: String, payload: Dynamic)
}
