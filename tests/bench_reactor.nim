## Server-side reactor benchmarks.
##
## Target scale: 10k connections (Istrolid1 peaked ~3k concurrent players;
## Istrolid2 should clear that with headroom).
##
## One server, one client socket, many logical connections. Measures server
## tick cost so later perf work has a comparable baseline.
##
## Run (release, no macOS recv sleep):
##   nim r -d:release -d:nettyBench tests/bench_reactor.nim
## Optional scale:
##   nim r -d:release -d:nettyBench tests/bench_reactor.nim 1000
##
## Checked-in baseline (compare after perf changes):
##   docs/bench-baseline.md

import std/[algorithm, monotimes, strformat, strutils, os]

include netty

type
  BenchRow = object
    name: string
    connections: int
    ticks: int
    messages: int
    bytes: int
    serverNs: int64
    p99TickUs: int
    maxRecvParts: int
    maxSendParts: int
    memBytes: int

proc percentile99(samples: seq[int64]): int64 =
  ## Nearest-rank p99 over ascending samples (nanoseconds).
  if samples.len == 0:
    return 0
  var sorted = samples
  sorted.sort()
  let i = min(sorted.len - 1, (sorted.len * 99) div 100)
  sorted[i]

proc drain(server, client: Reactor, rounds = 50) =
  for _ in 0 ..< rounds:
    client.tick()
    server.tick()

proc bumpTime(reactor: Reactor, dt = 0.001) =
  reactor.debug.tickTime += dt

proc maxParts(reactor: Reactor): (int, int) =
  var recvMax, sendMax: int
  for conn in reactor.connections:
    recvMax = max(recvMax, conn.recvPartCount)
    sendMax = max(sendMax, conn.sendParts.len)
  (recvMax, sendMax)

proc openPair(maxConns: int): (Reactor, Reactor) =
  var server = newReactor("127.0.0.1", 0)
  var client = newReactor()
  server.maxConnections = maxConns
  client.maxConnections = maxConns
  server.debug.tickTime = 1_000.0
  client.debug.tickTime = 1_000.0
  server.tick()
  client.tick()
  (server, client)

proc refreshActivity(server, client: Reactor) =
  let st = server.currentTime()
  let ct = client.currentTime()
  for conn in server.connections:
    conn.lastActiveTime = st
  for conn in client.connections:
    conn.lastActiveTime = ct

proc establish(
  server, client: Reactor,
  count: int,
  payload = "x"
): seq[Connection] =
  result = newSeqOfCap[Connection](count)
  client.maxInFlight = 1_000_000_000
  server.maxInFlight = 1_000_000_000
  let batch = 16
  for i in 0 ..< count:
    let conn = client.connect(server.address)
    client.send(conn, payload)
    result.add(conn)
    if i mod batch == batch - 1:
      client.bumpTime()
      server.bumpTime()
      drain(server, client, 16)
      refreshActivity(server, client)
      if count >= 1000 and (i < 64 or i mod 2000 == 1999):
        echo "  establish ", server.connections.len, "/", count,
          " (client ", client.connections.len, ")"

  # Flush a trailing partial batch.
  client.bumpTime()
  server.bumpTime()
  drain(server, client, 64)
  refreshActivity(server, client)

  var guard = 0
  let guardMax = max(10_000, count)
  while server.connections.len < count and guard < guardMax:
    if guard mod 32 == 31:
      client.bumpTime(AckTime)
      server.bumpTime(AckTime)
    else:
      client.bumpTime()
      server.bumpTime()
    client.tick()
    server.tick()
    refreshActivity(server, client)
    inc guard
    if guard mod 5000 == 0:
      echo "  establish ", server.connections.len, "/", count

  doAssert server.connections.len == count,
    &"wanted {count} conns, got {server.connections.len} after {guard} drains"

proc measureServerTicks(
  server, client: Reactor,
  ticks: int,
  beforeTick: proc() {.closure.}
): tuple[serverNs: int64, tickNs: seq[int64], messages: int, bytes: int] =
  var
    serverNs: int64
    tickNs = newSeqOfCap[int64](ticks)
    messages, bytes: int

  for _ in 0 ..< ticks:
    beforeTick()
    client.tick()
    let t0 = getMonoTime()
    server.tick()
    let dt = (getMonoTime() - t0).inNanoseconds
    serverNs += dt
    tickNs.add(dt)
    for msg in server.messages:
      inc messages
      bytes += msg.data.len

  (serverNs, tickNs, messages, bytes)

proc row(
  name: string,
  connections, ticks, messages, bytes: int,
  serverNs: int64,
  tickNs: seq[int64],
  server: Reactor
): BenchRow =
  let (recvMax, sendMax) = server.maxParts()
  result = BenchRow(
    name: name,
    connections: connections,
    ticks: ticks,
    messages: messages,
    bytes: bytes,
    serverNs: serverNs,
    p99TickUs: int(percentile99(tickNs) div 1000),
    maxRecvParts: recvMax,
    maxSendParts: sendMax,
    memBytes: getOccupiedMem()
  )

proc printRows(rows: seq[BenchRow]) =
  echo ""
  echo "| scenario | conns | ticks | msgs | bytes | msgs/s | mean tick us | p99 tick us | max recvParts | max sendParts | occupied MB |"
  echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
  for r in rows:
    let
      secs = r.serverNs.float64 / 1e9
      msgsPerSec =
        if secs > 0:
          r.messages.float64 / secs
        else:
          0.0
      meanTickUs =
        if r.ticks > 0:
          r.serverNs.float64 / r.ticks.float64 / 1e3
        else:
          0.0
      memMb = r.memBytes.float64 / (1024.0 * 1024.0)
    echo &"| {r.name} | {r.connections} | {r.ticks} | {r.messages} | {r.bytes} | {msgsPerSec.int} | {meanTickUs:.1f} | {r.p99TickUs} | {r.maxRecvParts} | {r.maxSendParts} | {memMb:.1f} |"

proc benchIdle(connCount, measureTicks: int): BenchRow =
  ## Many connections, almost no traffic after establish.
  let (server, client) = openPair(connCount + 16)
  discard establish(server, client, connCount)
  # Drain establish traffic and ACK noise.
  drain(server, client, 100)

  let measured = measureServerTicks(server, client, measureTicks) do ():
    client.bumpTime()
    server.bumpTime()

  result = row(
    "many-idle",
    connCount,
    measureTicks,
    measured.messages,
    measured.bytes,
    measured.serverNs,
    measured.tickNs,
    server
  )
  client.close()
  server.close()

proc benchActive(connCount, measureTicks: int): BenchRow =
  ## Every connection sends one small message per tick.
  let (server, client) = openPair(connCount + 16)
  let conns = establish(server, client, connCount)
  drain(server, client, 100)

  let measured = measureServerTicks(server, client, measureTicks) do ():
    for conn in conns:
      client.send(conn, "ping")
    client.bumpTime()
    server.bumpTime()

  result = row(
    "many-active",
    connCount,
    measureTicks,
    measured.messages,
    measured.bytes,
    measured.serverNs,
    measured.tickNs,
    server
  )
  client.close()
  server.close()

proc benchFanIn(connCount, measureTicks: int): BenchRow =
  ## Few connections push large fragmented payloads each tick.
  let (server, client) = openPair(connCount + 16)
  client.maxUdpPacket = 200
  server.maxUdpPacket = 200
  let conns = establish(server, client, connCount, "open")
  drain(server, client, 50)

  var big = newString(8_000)
  for i in 0 ..< big.len:
    big[i] = char(ord('A') + (i mod 26))

  let measured = measureServerTicks(server, client, measureTicks) do ():
    for conn in conns:
      client.send(conn, big)
    client.bumpTime(AckTime)
    server.bumpTime(AckTime)

  result = row(
    "fan-in-large",
    connCount,
    measureTicks,
    measured.messages,
    measured.bytes,
    measured.serverNs,
    measured.tickNs,
    server
  )
  client.close()
  server.close()

proc benchChurn(cycles: int): BenchRow =
  ## Connect, send, disconnect repeatedly against one server.
  let maxConns = max(64, cycles div 10 + 16)
  let (server, client) = openPair(maxConns)
  var
    serverNs: int64
    tickNs: seq[int64]
    messages, bytes, ticks: int

  for i in 0 ..< cycles:
    let conn = client.connect(server.address)
    client.send(conn, "churn")
    client.bumpTime()
    server.bumpTime()
    client.tick()

    let t0 = getMonoTime()
    server.tick()
    let dt = (getMonoTime() - t0).inNanoseconds
    serverNs += dt
    tickNs.add(dt)
    inc ticks
    for msg in server.messages:
      inc messages
      bytes += msg.data.len

    if server.connections.len > 0:
      # Prefer disconnecting the matching server-side conn if present.
      var target = server.connections[0]
      for c in server.connections:
        if c.id == conn.id:
          target = c
          break
      server.disconnect(target)
    client.disconnect(conn)

    if i mod 32 == 31:
      drain(server, client, 2)

  result = row(
    "churn",
    maxConns,
    ticks,
    messages,
    bytes,
    serverNs,
    tickNs,
    server
  )
  client.close()
  server.close()

proc main() =
  let scale =
    if paramCount() >= 1:
      parseInt(paramStr(1))
    else:
      10_000

  let
    idleConns = scale
    activeConns = max(1, scale div 2)
    fanConns = 4
    measureTicks = 200
    # Churn cost grows linearly; keep it bounded at large scale.
    churnCycles = max(100, min(2000, scale div 2))

  echo "netty reactor bench"
  echo &"  scale={scale} idleConns={idleConns} activeConns={activeConns}"
  echo &"  fanConns={fanConns} measureTicks={measureTicks} churnCycles={churnCycles}"
  echo "  compile with: nim r -d:release -d:nettyBench tests/bench_reactor.nim"

  var rows: seq[BenchRow]
  rows.add benchIdle(idleConns, measureTicks)
  rows.add benchActive(activeConns, measureTicks)
  rows.add benchFanIn(fanConns, measureTicks)
  rows.add benchChurn(churnCycles)
  printRows(rows)

main()
