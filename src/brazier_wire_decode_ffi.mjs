// The decoders of brazier/internal/wire_decode on JavaScript.
//
// The browser decodes the whole model after every patch, so these loops
// build no error and no path while a value decodes: a path segment is added
// only when a failure returns through them. The errors are the standard
// library's DecodeError values, with dynamic.classify as the found name, as
// gleam/dynamic/decode reports them.
//
// A value is read as JSON.parse produces it: an object is a plain object
// (its prototype Object.prototype or null) and its keys are its own keys, an
// array is a JavaScript array.

import {
  Result$Ok,
  Result$Error,
  Result$isOk,
  Result$Ok$0,
  Result$Error$0,
  List$Empty,
  List$NonEmpty,
} from "./gleam.mjs";
import {
  DecodeError$DecodeError,
  DecodeError$DecodeError$expected,
  DecodeError$DecodeError$found,
  DecodeError$DecodeError$path,
} from "../gleam_stdlib/gleam/dynamic/decode.mjs";
import { classify } from "../gleam_stdlib/gleam/dynamic.mjs";

const hasOwnProperty = Object.prototype.hasOwnProperty;

function isObject(data) {
  if (data === null || typeof data !== "object" || Array.isArray(data)) {
    return false;
  }
  const proto = Object.getPrototypeOf(data);
  return proto === Object.prototype || proto === null;
}

function mismatch(expected, data) {
  return Result$Error(DecodeError$DecodeError(expected, classify(data), List$Empty()));
}

// The error result `result` with `segment` in front of its path.
function pushed(result, segment) {
  const error = Result$Error$0(result);
  return Result$Error(
    DecodeError$DecodeError(
      DecodeError$DecodeError$expected(error),
      DecodeError$DecodeError$found(error),
      List$NonEmpty(segment, DecodeError$DecodeError$path(error)),
    ),
  );
}

export function int(data) {
  return Number.isInteger(data) ? Result$Ok(data) : mismatch("Int", data);
}

// Any number: JavaScript writes the float 1.0 as 1.
export function float(data) {
  return typeof data === "number" ? Result$Ok(data) : mismatch("Float", data);
}

export function bool(data) {
  return data === true || data === false ? Result$Ok(data) : mismatch("Bool", data);
}

export function string(data) {
  return typeof data === "string" ? Result$Ok(data) : mismatch("String", data);
}

export function is_null(data) {
  return data === null || data === undefined;
}

export function object(data, value) {
  return isObject(data) ? Result$Ok(value) : mismatch("Dict", data);
}

export function field(data, key, inner) {
  if (!isObject(data)) return mismatch("Dict", data);
  if (!hasOwnProperty.call(data, key)) {
    return Result$Error(
      DecodeError$DecodeError("Field", "Nothing", List$NonEmpty(key, List$Empty())),
    );
  }
  const result = inner(data[key]);
  return Result$isOk(result) ? result : pushed(result, key);
}

export function list(data, inner) {
  if (!Array.isArray(data)) return mismatch("List", data);
  const length = data.length;
  const values = new Array(length);
  for (let index = 0; index < length; index++) {
    const result = inner(data[index]);
    if (!Result$isOk(result)) return pushed(result, String(index));
    values[index] = Result$Ok$0(result);
  }
  let decoded = List$Empty();
  for (let index = length - 1; index >= 0; index--) {
    decoded = List$NonEmpty(values[index], decoded);
  }
  return Result$Ok(decoded);
}

export function element(data, index, size, inner) {
  if (!(Number.isInteger(index) && index >= 0 && index < size)) {
    throw new globalThis.Error(
      "brazier/internal/wire_decode: element index outside the tuple",
    );
  }
  if (!Array.isArray(data) || data.length !== size) {
    return mismatch("array of " + size + " elements", data);
  }
  const result = inner(data[index]);
  return Result$isOk(result) ? result : pushed(result, String(index));
}

// Object keys are strings already, so only the key decoder runs on them.
export function entries(data, key, value, empty, insert) {
  if (!isObject(data)) return mismatch("Dict", data);
  const keys = Object.keys(data);
  let decoded = empty;
  for (let index = 0; index < keys.length; index++) {
    const text = keys[index];
    const decodedKey = key(text);
    if (!Result$isOk(decodedKey)) return pushed(decodedKey, "keys");
    const decodedValue = value(data[text]);
    if (!Result$isOk(decodedValue)) return pushed(decodedValue, text);
    decoded = insert(decoded, Result$Ok$0(decodedKey), Result$Ok$0(decodedValue));
  }
  return Result$Ok(decoded);
}
