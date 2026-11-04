import brazier/attribute
import brazier/element
import brazier/html

pub fn div_matches_element_test() {
  let a = html.div([attribute.class("x")], [html.text("hi")])
  let b =
    element.element("div", [attribute.attribute("class", "x")], [
      element.text("hi"),
    ])
  let assert True = element.to_string(a) == element.to_string(b)
}

pub fn button_test() {
  let node = html.button([attribute.id("btn")], [html.text("Click")])
  let assert "<button id=\"btn\">Click</button>" = element.to_string(node)
}

pub fn input_void_test() {
  let node =
    html.input([attribute.type_("text"), attribute.placeholder("Name...")])
  let assert "<input type=\"text\" placeholder=\"Name...\">" =
    element.to_string(node)
}

pub fn br_test() {
  let assert "<br>" = element.to_string(html.br([]))
}

pub fn nested_test() {
  let node =
    html.div([], [
      html.h1([], [html.text("Title")]),
      html.p([], [html.text("Body")]),
    ])
  let assert "<div><h1>Title</h1><p>Body</p></div>" = element.to_string(node)
}

pub fn ul_li_test() {
  let node =
    html.ul([], [html.li([], [html.text("a")]), html.li([], [html.text("b")])])
  let assert "<ul><li>a</li><li>b</li></ul>" = element.to_string(node)
}

pub fn link_test() {
  let node =
    html.a([attribute.href("/about"), attribute.class("link")], [
      html.text("About"),
    ])
  let assert "<a href=\"/about\" class=\"link\">About</a>" =
    element.to_string(node)
}

pub fn img_void_test() {
  let node = html.img([attribute.src("/logo.png"), attribute.alt("Logo")])
  let assert "<img src=\"/logo.png\" alt=\"Logo\">" = element.to_string(node)
}

pub fn textarea_and_select_test() {
  let node =
    html.select([attribute.name("pick")], [
      html.option([attribute.value("a"), attribute.selected(True)], [
        html.text("A"),
      ]),
    ])
  let assert "<select name=\"pick\"><option value=\"a\" selected=\"\">A</option></select>" =
    element.to_string(node)
  let assert "<textarea rows=\"3\">hi</textarea>" =
    element.to_string(html.textarea([attribute.rows(3)], [html.text("hi")]))
}
