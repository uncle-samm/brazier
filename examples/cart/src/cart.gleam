/// Shopping Cart, demonstrating:
/// - derived values in the view (subtotal, tax and total are not stored);
/// - stock shared by every session, kept in a `brazier/store` list as an
///   append-only log of takes and returns, so two shoppers can never take
///   the same last item;
/// - server-only state: each session's cart id never reaches the browser.
import brazier
import brazier/attribute
import brazier/config
import brazier/effect.{type Effect}
import brazier/element.{type Element}
import brazier/event
import brazier/html
import brazier/local
import brazier/log
import brazier/store.{type ListStore}
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// The tab icon, inline so the browser does not request `/favicon.ico`.
const favicon =
  "<link rel=\"icon\" href=\"data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><circle cx='8' cy='8' r='7' fill='%23f59e0b'/></svg>\">"

// --- Types ---

/// A catalog entry with the stock left after every cart's takes.
pub type Product {
  Product(id: Int, name: String, price: Int, stock: Int)
}

pub type CartItem {
  CartItem(product_id: Int, name: String, price: Int, quantity: Int)
}

/// Synced to the browser.
pub type Model {
  Model(products: List(Product), cart_items: List(CartItem))
}

/// Held by the server. `cart` names this session's entries in the shared
/// log; `sync` leaves it out, so it is never sent to the browser.
pub type State {
  State(cart: String, model: Model)
}

pub type Msg {
  AddToCart(product_id: Int)
  DecrementQty(product_id: Int)
  RemoveFromCart(product_id: Int)
  /// The stock log changed (from this session or another).
  StockChanged
}

/// One entry of the shared stock log.
pub type StockChange {
  /// Move one unit from the shelf into `cart`. Refused on replay when the
  /// shelf is empty, so a take that lost a race to the last unit has no
  /// effect for anyone.
  Take(cart: String, product_id: Int)
  /// Put up to `quantity` units held by `cart` back on the shelf.
  Return(cart: String, product_id: Int, quantity: Int)
}

const log_key = "stock"

fn catalog() -> List(Product) {
  [
    Product(id: 1, name: "Laptop", price: 999, stock: 5),
    Product(id: 2, name: "Mouse", price: 29, stock: 20),
    Product(id: 3, name: "Keyboard", price: 79, stock: 15),
    Product(id: 4, name: "Monitor", price: 449, stock: 8),
    Product(id: 5, name: "Headphones", price: 149, stock: 12),
  ]
}

// --- Shared stock log ---

/// Stock per product id and units held per #(cart, product id), after
/// applying every change in log order. Every session replays the same log
/// in the same order, so all of them agree on which takes succeeded.
fn replay(
  changes: List(StockChange),
) -> #(Dict(Int, Int), Dict(#(String, Int), Int)) {
  let shelf =
    catalog()
    |> list.map(fn(p) { #(p.id, p.stock) })
    |> dict.from_list
  list.fold(changes, #(shelf, dict.new()), fn(acc, change) {
    let #(shelf, held) = acc
    case change {
      Take(cart:, product_id:) ->
        case dict.get(shelf, product_id) {
          Ok(stock) if stock > 0 -> #(
            dict.insert(shelf, product_id, stock - 1),
            dict.upsert(held, #(cart, product_id), fn(units) {
              option_add(units, 1)
            }),
          )
          // Out of stock, or not in the catalog: the take is refused.
          _ -> acc
        }
      Return(cart:, product_id:, quantity:) ->
        case dict.get(held, #(cart, product_id)), dict.get(shelf, product_id) {
          Ok(units), Ok(stock) -> {
            let returned = int.min(units, int.max(0, quantity))
            #(
              dict.insert(shelf, product_id, stock + returned),
              dict.insert(held, #(cart, product_id), units - returned),
            )
          }
          // The cart never held this product: nothing to return.
          _, _ -> acc
        }
    }
  })
}

fn option_add(units: Option(Int), amount: Int) -> Int {
  case units {
    Some(units) -> units + amount
    None -> amount
  }
}

fn read_model(changes: ListStore(StockChange), cart: String) -> Model {
  let #(shelf, held) = replay(store.get_all(changes, log_key))
  let products =
    list.map(catalog(), fn(p) {
      // `replay` starts the shelf from the catalog and never removes an
      // id, so every catalog product has a stock entry.
      let assert Ok(stock) = dict.get(shelf, p.id)
      Product(..p, stock:)
    })
  let cart_items =
    list.filter_map(catalog(), fn(p) {
      case dict.get(held, #(cart, p.id)) {
        Ok(quantity) if quantity > 0 ->
          Ok(CartItem(product_id: p.id, name: p.name, price: p.price, quantity:))
        _ -> Error(Nil)
      }
    })
  Model(products:, cart_items:)
}

/// Append a change; the store broadcasts on its topic, which every session
/// (this one included) turns into `StockChanged`.
fn record(changes: ListStore(StockChange), change: StockChange) -> Effect(Msg) {
  effect.from(fn(_dispatch) { store.append(changes, log_key, change) })
}

// --- Init and update (server) ---

fn init(
  changes: ListStore(StockChange),
) -> Result(#(State, Effect(Msg)), brazier.InitError) {
  let cart = new_cart_id()
  log.info("cart", "New cart " <> cart)
  Ok(#(State(cart:, model: read_model(changes, cart)), effect.none()))
}

/// 128 random bits: no two sessions share a cart.
fn new_cart_id() -> String {
  crypto.strong_random_bytes(16) |> bit_array.base16_encode
}

fn update(
  changes: ListStore(StockChange),
  state: State,
  msg: Msg,
) -> #(State, Effect(Msg)) {
  case msg {
    AddToCart(id) ->
      case list.find(state.model.products, fn(p) { p.id == id }) {
        Ok(product) if product.stock > 0 -> #(
          state,
          record(changes, Take(cart: state.cart, product_id: id)),
        )
        Ok(_) -> {
          log.warning(
            "cart",
            "Ignored add of out-of-stock product " <> int.to_string(id),
          )
          #(state, effect.none())
        }
        Error(Nil) -> {
          log.warning(
            "cart",
            "Ignored add of unknown product " <> int.to_string(id),
          )
          #(state, effect.none())
        }
      }
    DecrementQty(id) -> return_units(changes, state, id, fn(_quantity) { 1 })
    RemoveFromCart(id) ->
      return_units(changes, state, id, fn(quantity) { quantity })
    StockChanged -> #(
      State(..state, model: read_model(changes, state.cart)),
      effect.none(),
    )
  }
}

fn return_units(
  changes: ListStore(StockChange),
  state: State,
  id: Int,
  how_many: fn(Int) -> Int,
) -> #(State, Effect(Msg)) {
  case list.find(state.model.cart_items, fn(item) { item.product_id == id }) {
    Ok(item) -> #(
      state,
      record(
        changes,
        Return(
          cart: state.cart,
          product_id: id,
          quantity: how_many(item.quantity),
        ),
      ),
    )
    Error(Nil) -> {
      log.warning(
        "cart",
        "Ignored return of product "
          <> int.to_string(id)
          <> ", which is not in the cart",
      )
      #(state, effect.none())
    }
  }
}

fn sync(state: State) -> Model {
  state.model
}

// --- View ---

/// The second argument is the Local state, `Nil` here (`local.none()`).
pub fn view(model: Model, _local: Nil) -> Element(Msg) {
  // Derived in the view, not stored in the model.
  let subtotal =
    list.fold(model.cart_items, 0, fn(sum, item) {
      sum + item.price * item.quantity
    })
  let tax = subtotal / 10
  let total = subtotal + tax

  html.div(
    [
      attribute.styles([
        #("font-family", "system-ui"),
        #("max-width", "800px"),
        #("margin", "2rem auto"),
        #("padding", "0 1rem"),
      ]),
    ],
    [
      html.h1([], [html.text("Shopping Cart")]),
      html.div(
        [
          attribute.styles([
            #("display", "grid"),
            #("grid-template-columns", "1fr 1fr"),
            #("gap", "2rem"),
          ]),
        ],
        [
          html.div([], [
            html.h2([], [html.text("Products")]),
            html.div(
              [],
              list.map(model.products, fn(product) {
                element.keyed(
                  int.to_string(product.id),
                  render_product(product),
                )
              }),
            ),
          ]),
          html.div([], [
            html.h2([], [html.text("Cart")]),
            case model.cart_items {
              [] ->
                html.p([attribute.style("color", "#999")], [
                  html.text("Cart is empty"),
                ])
              items ->
                html.div([], [
                  html.div(
                    [],
                    list.map(items, fn(item) {
                      element.keyed(
                        int.to_string(item.product_id),
                        render_cart_item(item),
                      )
                    }),
                  ),
                  html.div(
                    [
                      attribute.styles([
                        #("border-top", "2px solid #333"),
                        #("margin-top", "1rem"),
                        #("padding-top", "1rem"),
                      ]),
                    ],
                    [
                      total_row("Subtotal", subtotal),
                      total_row("Tax (10%)", tax),
                      html.div(
                        [
                          attribute.styles([
                            #("display", "flex"),
                            #("justify-content", "space-between"),
                            #("font-weight", "bold"),
                            #("font-size", "18px"),
                            #("margin-top", "8px"),
                          ]),
                        ],
                        [
                          html.span([], [html.text("Total")]),
                          html.span([attribute.id("cart-total")], [
                            html.text("$" <> int.to_string(total)),
                          ]),
                        ],
                      ),
                    ],
                  ),
                ])
            },
          ]),
        ],
      ),
    ],
  )
}

fn render_product(product: Product) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("display", "flex"),
        #("justify-content", "space-between"),
        #("align-items", "center"),
        #("padding", "12px"),
        #("border", "1px solid #eee"),
        #("border-radius", "8px"),
        #("margin-bottom", "8px"),
      ]),
    ],
    [
      html.div([], [
        html.div([attribute.style("font-weight", "500")], [
          html.text(product.name),
        ]),
        html.div(
          [attribute.styles([#("color", "#666"), #("font-size", "14px")])],
          [
            html.text(
              "$"
              <> int.to_string(product.price)
              <> " | Stock: "
              <> int.to_string(product.stock),
            ),
          ],
        ),
      ]),
      case product.stock > 0 {
        True ->
          html.button(
            [
              event.on_click(AddToCart(product.id)),
              attribute.aria("label", "Add " <> product.name),
              attribute.styles([
                #("padding", "8px 16px"),
                #("background", "#4CAF50"),
                #("color", "white"),
                #("border", "none"),
                #("border-radius", "6px"),
                #("cursor", "pointer"),
              ]),
            ],
            [html.text("Add")],
          )
        False ->
          html.span(
            [attribute.styles([#("color", "#999"), #("font-size", "14px")])],
            [html.text("Out of stock")],
          )
      },
    ],
  )
}

fn render_cart_item(item: CartItem) -> Element(Msg) {
  let line_total = item.price * item.quantity
  let small_button = [
    #("width", "28px"),
    #("height", "28px"),
    #("border", "1px solid #ddd"),
    #("border-radius", "4px"),
    #("cursor", "pointer"),
    #("background", "white"),
  ]
  html.div(
    [
      attribute.styles([
        #("display", "flex"),
        #("justify-content", "space-between"),
        #("align-items", "center"),
        #("padding", "8px 0"),
        #("border-bottom", "1px solid #f0f0f0"),
      ]),
    ],
    [
      html.div([], [
        html.span([attribute.style("font-weight", "500")], [
          html.text(item.name),
        ]),
        html.span(
          [
            attribute.styles([
              #("color", "#666"),
              #("margin-left", "8px"),
              #("font-size", "14px"),
            ]),
          ],
          [html.text("$" <> int.to_string(item.price) <> " each")],
        ),
      ]),
      html.div(
        [
          attribute.styles([
            #("display", "flex"),
            #("align-items", "center"),
            #("gap", "8px"),
          ]),
        ],
        [
          html.button(
            [
              event.on_click(DecrementQty(item.product_id)),
              attribute.aria("label", "One less " <> item.name),
              attribute.styles(small_button),
            ],
            [html.text("-")],
          ),
          html.span(
            [
              attribute.styles([
                #("min-width", "20px"),
                #("text-align", "center"),
              ]),
            ],
            [html.text(int.to_string(item.quantity))],
          ),
          html.button(
            [
              event.on_click(AddToCart(item.product_id)),
              attribute.aria("label", "One more " <> item.name),
              attribute.styles(small_button),
            ],
            [html.text("+")],
          ),
          html.span(
            [
              attribute.styles([
                #("min-width", "60px"),
                #("text-align", "right"),
                #("font-weight", "500"),
              ]),
            ],
            [html.text("$" <> int.to_string(line_total))],
          ),
          html.button(
            [
              event.on_click(RemoveFromCart(item.product_id)),
              attribute.aria("label", "Remove " <> item.name),
              attribute.styles([
                #("background", "none"),
                #("border", "none"),
                #("color", "#e57373"),
                #("cursor", "pointer"),
                #("font-size", "16px"),
              ]),
            ],
            [html.text("x")],
          ),
        ],
      ),
    ],
  )
}

fn total_row(label: String, amount: Int) -> Element(Msg) {
  html.div(
    [
      attribute.styles([
        #("display", "flex"),
        #("justify-content", "space-between"),
        #("color", "#666"),
        #("font-size", "14px"),
        #("margin-bottom", "4px"),
      ]),
    ],
    [
      html.span([], [html.text(label)]),
      html.span([], [html.text("$" <> int.to_string(amount))]),
    ],
  )
}

// --- Start ---

pub fn main() {
  let assert Ok(secret_key) = config.secret_key()
    as "SECRET_KEY must be set to a private key of at least 32 bytes (config.secret_key logs why it was refused)"
  let changes = store.new_list("cart_stock")
  let assert Ok(Nil) =
    brazier.full_application(
      init: fn(_ctx) { init(changes) },
      update: fn(state, msg) { update(changes, state, msg) },
      sync:,
      local: local.none(),
      view:,
    )
    |> brazier.title(fn(_model) { "Shopping Cart" })
    |> brazier.subscriptions(fn(_state) { [store.list_topic(changes)] })
    |> brazier.on_notify(fn(_topic) { StockChanged })
    |> brazier.head_html(favicon)
    |> brazier.secret_key(secret_key)
    |> brazier.start(8080)
    as "brazier.start failed (it logs the error)"
}
