# Reactor bench baseline

Captured before connection-table / queue / pooling work.
Re-run the same command after perf changes and compare this table.

```
nim r -d:release -d:nettyBench tests/bench_reactor.nim 1000
```

## Environment

- Date: 2026-07-14
- Host: macOS darwin 24.1.0 (arm64)
- Nim: 2.2.4
- Flags: `-d:release -d:nettyBench`
- Scale: 1000

## Baseline

| scenario | conns | ticks | msgs | bytes | msgs/s | mean tick us | p99 tick us | max recvParts | max sendParts | occupied MB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| many-idle | 1000 | 200 | 0 | 0 | 0 | 12.2 | 34 | 0 | 0 | 47.4 |
| many-active | 500 | 200 | 100000 | 400000 | 270931 | 1845.5 | 2079 | 0 | 0 | 23.8 |
| fan-in-large | 4 | 200 | 800 | 6400000 | 3490 | 1145.9 | 1363 | 0 | 0 | 0.3 |
| churn | 66 | 500 | 484 | 2420 | 74602 | 13.0 | 24 | 0 | 0 | 0.1 |

## What should move

| Change | Expect |
|--------|--------|
| `Table` for connections | lower many-idle / many-active mean and p99 tick |
| Ring/deque for parts | lower fan-in-large mean and p99 tick |
| Part pool / less copy | lower fan-in-large occupied MB and mean tick |
