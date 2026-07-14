# Reactor bench baseline

Target: **10k connections** — Istrolid1 peaked around 3k concurrent players;
Istrolid2 should handle that easily, with 10k as headroom.

```
nim r -d:release -d:nettyBench tests/bench_reactor.nim
# default scale is 10000
```

## Environment

- Host: macOS darwin 24.1.0 (arm64)
- Nim: 2.2.4
- Flags: `-d:release -d:nettyBench`
- Default scale: 10000

## Current baseline (post perf work, scale=10000)

| scenario | conns | ticks | msgs | bytes | msgs/s | mean tick us | p99 tick us | occupied MB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| many-idle | 10000 | 200 | 0 | 0 | 0 | 215.5 | 282 | 40.0 |
| many-active | 5000 | 200 | 819800 | 3279200 | 838653 | 4887.6 | 5631 | 39.4 |
| fan-in-large | 4 | 200 | 800 | 6400000 | 12748 | 313.8 | 462 | 0.1 |
| churn | 216 | 2000 | 1937 | 9685 | 91847 | 10.5 | 18 | 0.0 |

## Reference at scale=1000 (smoke)

| scenario | conns | mean tick us | msgs/s |
|---|---:|---:|---:|
| many-idle | 1000 | ~19 | 0 |
| many-active | 500 | ~439 | ~1.1M |

## Reading the 10k numbers for Istrolid2

- **3k players** is below this bench's idle=10k / active=5k load.
- **many-active ~4.9ms mean tick** at 5k sending every tick is a stress ceiling, not a typical frame (games traffic is far sparser per conn).
- **many-idle ~0.22ms** at 10k is the "connected but quiet" cost — still scans every connection each tick; next win if needed.
- Prefer improving **10k** numbers over chasing 100k (establish is too slow/flaky on localhost UDP).

## What already landed

- `Table[uint32, Connection]` for O(1) `getConn`
- Per-sequence receive window (no O(n) inserts)
- `Deque` send queue + part pool
- ACK bundling (`AckBundleMagic`)
- Reused `outBuf`, `MaxUdpRecv`, `MaxPartsPerTick`
- `DefaultMaxConnections = 10_000`
