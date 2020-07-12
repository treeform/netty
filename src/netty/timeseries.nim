type
  TimeSeries* = ref object
    ## Helps you time stuff over multiple frames.
    at: Natural
    filled: Natural
    data: seq[float64]

func newTimeSeries*(max: Natural = 1000): TimeSeries =
  ## Create new time series.
  result = TimeSeries()
  result.data = newSeq[float64](max)

func add*(timeSeries: var TimeSeries, value: float64) =
  ## Add sample to time series.
  if timeSeries.at >= timeSeries.data.len:
    timeSeries.at = 0
  timeSeries.data[timeSeries.at] = value
  inc timeSeries.at
  timeSeries.filled = max(timeSeries.filled, timeSeries.at)

func avg*(timeSeries: TimeSeries): float64 =
  ## Get average value of the time series samples.
  var total: float64
  for sample in timeSeries.data[0 ..< timeSeries.filled]:
    total += sample
  if timeSeries.filled > 0:
    return total / timeSeries.filled.float64

func max*(timeSeries: TimeSeries): float64 =
  ## Get max value of the time series samples.
  timeSeries.data.max()

type
  TimedSamples* = ref object
    ## Helps you time values of stuff over multiple frames.
    at: Natural
    filled: Natural
    data: seq[(float64, float64)]

func newTimedSamples*(max: Natural = 1000): TimedSamples =
  ## Create new timed sample series.
  result = TimedSamples()
  result.data = newSeq[(float64, float64)](max)

func add*(timedSamples: var TimedSamples, time: float64, value: float64) =
  ## Add sample value to the series.
  if timedSamples.at >= timedSamples.data.len:
    timedSamples.at = 0
  timedSamples.data[timedSamples.at] = (time, value)
  inc timedSamples.at
  timedSamples.filled = max(timedSamples.filled, timedSamples.at)

func avg*(timedSamples: TimedSamples): float64 =
  ## Get average value of the values in the samples.
  var
    total: float64
    earliest = high(float64)
    latest = 0.float64
  for (time, value) in timedSamples.data[0 ..< timedSamples.filled]:
    total += value
    earliest = min(earliest, time)
    latest = max(latest, time)

  if timedSamples.filled > 0:
    let delta = latest - earliest
    if delta > 0:
      return total / delta
    else:
      return total

func max*(timedSamples: TimedSamples): float64 =
  ## Get max value of the values in the samples.
  if timedSamples.data.len > 0:
    result = timedSamples.data[0][1]
    for (time, value) in timedSamples.data[0 ..< timedSamples.filled]:
      result = max(result, value)
