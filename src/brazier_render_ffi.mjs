// Name checks, HTML escaping and the item_ref identity for
// brazier/internal/render on JavaScript.
//
// These run once per element, attribute and text node of every render, so
// they scan UTF-16 code units instead of splitting the string into
// graphemes. Names are ASCII-only: any code unit outside the allowed set,
// including every code unit of a non-ASCII character, refuses the name.
//
// The escapers return their input unchanged when nothing needs escaping,
// and otherwise replace in one regex pass with a lookup table.

function isAlnum(code) {
  return (
    (code >= 0x61 && code <= 0x7a) ||
    (code >= 0x41 && code <= 0x5a) ||
    (code >= 0x30 && code <= 0x39)
  );
}

// A tag or attribute name: one or more of `a-z A-Z 0-9 - _ : .`.
export function is_markup_name(name) {
  if (name.length === 0) return false;
  for (let i = 0; i < name.length; i++) {
    const code = name.charCodeAt(i);
    if (
      !isAlnum(code) &&
      code !== 0x2d &&
      code !== 0x5f &&
      code !== 0x3a &&
      code !== 0x2e
    ) {
      return false;
    }
  }
  return true;
}

// An event name: one or more of `a-z A-Z 0-9 - _`.
export function is_event_name(name) {
  if (name.length === 0) return false;
  for (let i = 0; i < name.length; i++) {
    const code = name.charCodeAt(i);
    if (!isAlnum(code) && code !== 0x2d && code !== 0x5f) return false;
  }
  return true;
}

// `name` with `A-Z` lowercased, every other code unit unchanged. Callers
// pass names `is_markup_name` accepted, which are ASCII, so this is
// `toLowerCase` for them.
const UPPER_TEST = /[A-Z]/;
const UPPER_ALL = /[A-Z]+/g;
const lowerRun = (upper) => upper.toLowerCase();

export function ascii_lowercase(name) {
  return UPPER_TEST.test(name) ? name.replace(UPPER_ALL, lowerRun) : name;
}

const ENTITIES = { "&": "&amp;", '"': "&quot;", "<": "&lt;", ">": "&gt;" };
const replaceEntity = (character) => ENTITIES[character];

// The test patterns have no `g` flag, so `test` keeps no `lastIndex` state
// between calls.
const HTML_TEST = /[&<>]/;
const HTML_ALL = /[&<>]/g;
const ATTR_TEST = /[&"<>]/;
const ATTR_ALL = /[&"<>]/g;

// Escape `&`, `<` and `>`.
export function escape_html(text) {
  return HTML_TEST.test(text) ? text.replace(HTML_ALL, replaceEntity) : text;
}

// Escape `&`, `"`, `<` and `>`.
export function escape_attr(text) {
  return ATTR_TEST.test(text) ? text.replace(ATTR_ALL, replaceEntity) : text;
}

// `value` unchanged, typed as `Dynamic` on the Gleam side: a stream
// container's `item_ref`, compared with `===` and never called.
export function identity(value) {
  return value;
}
