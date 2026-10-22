///|
test "idle timeout sweeps connections for every origin" {
  let pool = @ref.Ref(ConnectionPoolState::new())
  pool.val.idle_timeout_ms = 1000
  let first = regression_mock_stream("", 0, 0)
  let second = regression_mock_stream("", 0, 0)
  pool.val.cache_idle("http://first.example:80", first, 1000)
  pool.val.cache_idle("http://second.example:80", second, 1000)

  pool.val.sweep_expired(1500)
  assert_true(first.is_open)
  assert_true(second.is_open)
  assert_true(pool.val.idle.get("http://first.example:80") is Some(_))
  assert_true(pool.val.idle.get("http://second.example:80") is Some(_))

  pool.val.sweep_expired(2500)
  assert_false(first.is_open)
  assert_false(second.is_open)
  assert_true(pool.val.idle.get("http://first.example:80") is None)
  assert_true(pool.val.idle.get("http://second.example:80") is None)
}
