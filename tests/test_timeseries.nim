import netty/timeSeries

block:
  var ts = newTimeSeries()
  assert ts.max() == 0.0
  assert ts.avg() == 0.0

block:
  var ts = newTimeSeries()
  ts.add(123.0)
  assert ts.max() == 123.0
  assert ts.avg() == 123.0

block:
  var ts = newTimeSeries()
  ts.add(1.0)
  ts.add(2.0)
  ts.add(3.0)
  assert ts.max() == 3.0
  assert ts.avg() == 2.0

block:
  var ts = newTimeSeries(10)
  for i in 0 ..< 100:
    ts.add(i.float64)
  assert ts.max() == 99.0
  assert ts.avg() == 94.5

block:
  var ts = newTimedSamples()
  assert ts.max() == 0.0
  assert ts.avg() == 0.0

block:
  var ts = newTimedSamples()
  ts.add(123.0, 123.0)
  assert ts.max() == 123.0
  assert ts.avg() == 123.0

block:
  var ts = newTimedSamples()
  ts.add(1.0, 10.0)
  ts.add(2.0, 20.0)
  ts.add(3.0, 30.0)
  assert ts.max() == 30.0
  assert ts.avg() == 30.0

block:
  var ts = newTimedSamples(10)
  for i in 0 ..< 100:
    ts.add(i.float64, 10)
  assert ts.max() == 10.0
  assert ts.avg() == 11.11111111111111

block:
  var ts = newTimedSamples(10)
  for i in 0 ..< 100:
    ts.add(i.float64, i.float64 * 10)
  assert ts.max() == 990
  assert ts.avg() == 1050
