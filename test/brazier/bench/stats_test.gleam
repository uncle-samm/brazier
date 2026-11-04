import brazier/bench/stats
import gleam/int
import gleam/list

pub fn median_of_odd_count_is_middle_sample_test() {
  assert stats.median([5.0, 1.0, 3.0]) == Ok(3.0)
}

pub fn median_of_even_count_is_mean_of_middle_pair_test() {
  assert stats.median([4.0, 1.0, 3.0, 2.0]) == Ok(2.5)
}

pub fn median_of_one_sample_is_that_sample_test() {
  assert stats.median([7.0]) == Ok(7.0)
}

pub fn median_of_nothing_is_an_error_test() {
  assert stats.median([]) == Error(Nil)
}

pub fn p99_of_100_samples_is_the_99th_test() {
  let samples = int_range(1, 100)
  assert stats.percentile(samples, 99) == Ok(99.0)
  assert stats.percentile(samples, 100) == Ok(100.0)
  assert stats.percentile(samples, 1) == Ok(1.0)
}

pub fn p99_of_few_samples_is_the_maximum_test() {
  // Nearest rank: ceil(0.99 * 10) = 10, so the slowest of ten samples.
  assert stats.percentile(int_range(1, 10), 99) == Ok(10.0)
}

pub fn p99_picks_the_outlier_not_an_average_test() {
  // 1000 samples of 10 with 20 outliers of 500: the p99 sees them.
  let samples = list.append(list.repeat(10.0, 980), list.repeat(500.0, 20))
  assert stats.percentile(samples, 99) == Ok(500.0)
  assert stats.median(samples) == Ok(10.0)
}

pub fn percentile_of_nothing_is_an_error_test() {
  assert stats.percentile([], 99) == Error(Nil)
}

pub fn summarize_reports_every_order_statistic_test() {
  let assert Ok(summary) = stats.summarize([3.0, 9.0, 1.0, 5.0, 7.0])
    as "five samples summarize"
  assert summary
    == stats.Summary(count: 5, min: 1.0, median: 5.0, p99: 9.0, max: 9.0)
}

pub fn summarize_of_nothing_is_an_error_test() {
  assert stats.summarize([]) == Error(Nil)
  assert stats.summarize_ints([]) == Error(Nil)
}

pub fn spread_is_range_over_median_test() {
  assert stats.spread([90.0, 100.0, 110.0]) == Ok(0.2)
}

pub fn spread_of_identical_samples_is_zero_test() {
  assert stats.spread([4.0, 4.0, 4.0]) == Ok(0.0)
}

pub fn spread_relative_to_a_zero_median_is_an_error_test() {
  assert stats.spread([0.0, 0.0, 1.0]) == Error(Nil)
  assert stats.spread([]) == Error(Nil)
}

/// from..to inclusive, as floats.
fn int_range(from: Int, to: Int) -> List(Float) {
  int.range(from: to, to: from - 1, with: [], run: fn(acc, i) {
    [int.to_float(i), ..acc]
  })
}
