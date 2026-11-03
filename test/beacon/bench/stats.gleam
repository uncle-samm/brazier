//// Order statistics for benchmark samples.
////
//// Benchmarks report medians and 99th percentiles, never means: one
//// scheduler hiccup moves a mean but not a median, and the p99 is the
//// number a user waiting on a slow event actually feels.

import gleam/float
import gleam/int
import gleam/list

/// The order statistics of one set of samples.
pub type Summary {
  Summary(count: Int, min: Float, median: Float, p99: Float, max: Float)
}

/// Summarise samples. Error on an empty list: a benchmark that produced no
/// samples has measured nothing and must not report a number.
pub fn summarize(samples: List(Float)) -> Result(Summary, Nil) {
  let sorted = list.sort(samples, float.compare)
  case
    sorted,
    list.last(sorted),
    median_sorted(sorted),
    percentile_sorted(sorted, 99)
  {
    [min, ..], Ok(max), Ok(median), Ok(p99) ->
      Ok(Summary(
        count: list.length(sorted),
        min: min,
        median: median,
        p99: p99,
        max: max,
      ))
    _, _, _, _ -> Error(Nil)
  }
}

/// Integer samples (microseconds from the load generators) as floats.
pub fn summarize_ints(samples: List(Int)) -> Result(Summary, Nil) {
  summarize(list.map(samples, int.to_float))
}

/// The median: the middle sample, or the mean of the two middle samples
/// of an even count. Error on an empty list.
pub fn median(samples: List(Float)) -> Result(Float, Nil) {
  median_sorted(list.sort(samples, float.compare))
}

fn median_sorted(sorted: List(Float)) -> Result(Float, Nil) {
  let count = list.length(sorted)
  case count, list.drop(sorted, { count - 1 } / 2) {
    0, _ -> Error(Nil)
    _, [low, high, ..] if count % 2 == 0 -> Ok({ low +. high } /. 2.0)
    _, [middle, ..] -> Ok(middle)
    _, [] -> Error(Nil)
  }
}

/// The nearest-rank percentile: the smallest sample with at least
/// `percent`% of the samples at or below it. `percent` must be in 1..100;
/// Error on an empty list.
pub fn percentile(samples: List(Float), percent: Int) -> Result(Float, Nil) {
  percentile_sorted(list.sort(samples, float.compare), percent)
}

fn percentile_sorted(sorted: List(Float), percent: Int) -> Result(Float, Nil) {
  let assert True = percent >= 1 && percent <= 100
    as "percentile must be in 1..100"
  let count = list.length(sorted)
  // rank = ceil(percent * count / 100), 1-based.
  let rank = { percent * count + 99 } / 100
  case count {
    0 -> Error(Nil)
    _ -> list.drop(sorted, rank - 1) |> list.first
  }
}

/// The relative spread of samples: (max - min) / median. Error on an
/// empty list or a non-positive median (a spread relative to zero means
/// nothing).
pub fn spread(samples: List(Float)) -> Result(Float, Nil) {
  case summarize(samples) {
    Ok(Summary(min: min, median: median, max: max, ..)) if median >. 0.0 ->
      Ok({ max -. min } /. median)
    _ -> Error(Nil)
  }
}
