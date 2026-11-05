// ASCII case folding for brazier/internal/ascii on JavaScript: the one
// implementation of it on this target. The client render folds every
// attribute name with it, so a string with nothing to fold is returned
// without a copy.

const UPPER_TEST = /[A-Z]/;
const UPPER_ALL = /[A-Z]+/g;
const lowerRun = (upper) => upper.toLowerCase();

// `text` with `A-Z` lowercased, every other UTF-16 code unit unchanged. A
// run matched by `[A-Z]+` is ASCII, so `toLowerCase` on it is the ASCII
// mapping; a character outside ASCII is never in a run and is kept as it
// is. The test pattern has no `g` flag, so `test` keeps no `lastIndex`
// state between calls.
export function lowercase(text) {
  return UPPER_TEST.test(text) ? text.replace(UPPER_ALL, lowerRun) : text;
}
