## Hardening tests for untrusted UDP and accounting bugs.
## Each block forces one issue from the security / correctness list.

import flatty/binny

include netty

var nextPortNumber = 4000
proc nextPort(): int =
  result = nextPortNumber
  inc nextPortNumber

proc partPacket(
  sequenceNum, connId: uint32,
  partNum, numParts: uint16,
  data: string
): string =
  result.addUint32(PartMagic)
  result.addUint32(sequenceNum)
  result.addUint32(connId)
  result.addUint16(partNum)
  result.addUint16(numParts)
  result.addStr(data)

block:
  # Short datagram must not crash (header read before length check).
  echo "Testing short packets do not crash tick"
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  let address = server.address

  for n in 0 .. 15:
    client.rawSend(address, newString(n))

  # Disconnect magic with truncated body (4..7 bytes).
  for n in 4 .. 7:
    var junk = ""
    junk.addUint32(DisconnectMagic)
    junk.setLen(n)
    client.rawSend(address, junk)

  client.tick()
  server.tick()
  doAssert server.connections.len == 0
  doAssert server.messages.len == 0

block:
  # Undersized junk must continue, not break the read loop.
  echo "Testing short packet does not starve later messages"
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  var c2s = client.connect(server.address)

  client.rawSend(server.address, "short")
  client.send(c2s, "hello")
  client.tick()
  server.tick()

  doAssert server.messages.len == 1, $server.messages.len
  doAssert server.messages[0].data == "hello"

block:
  # Connection flood must respect maxConnections.
  echo "Testing connection flood is capped"
  var server = newReactor("127.0.0.1", nextPort())
  server.maxConnections = 8
  var client = newReactor()

  for i in 1u32 .. 40u32:
    client.rawSend(
      server.address,
      partPacket(0, i, 0, 1, "x")
    )
  client.tick()
  server.tick()

  doAssert server.connections.len == 8, $server.connections.len
  doAssert server.newConnections.len == 8, $server.newConnections.len

block:
  # Receive buffer must not grow without bound from incomplete messages.
  echo "Testing recvParts receive window"
  var server = newReactor("127.0.0.1", nextPort())
  server.maxRecvParts = 16
  var client = newReactor()
  var c2s = client.connect(server.address)

  # Open the connection with a complete first message.
  client.send(c2s, "open")
  client.tick()
  server.tick()
  doAssert server.messages.len == 1
  doAssert server.connections.len == 1

  let connId = server.connections[0].id
  # Flood future sequence numbers, part 0 of unfinished multi-part messages.
  for seqNum in 1u32 .. 200u32:
    client.rawSend(
      server.address,
      partPacket(seqNum, connId, 0, 4, "frag")
    )
  client.tick()
  server.tick()

  doAssert server.connections[0].recvParts.len <= server.maxRecvParts,
    $server.connections[0].recvParts.len

block:
  # Duplicate part with different bytes must not AssertionDefect.
  echo "Testing spoofed duplicate does not assert"
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  var c2s = client.connect(server.address)

  # Open the connection.
  client.send(c2s, "open")
  client.tick()
  server.tick()
  doAssert server.messages.len == 1
  let connId = server.connections[0].id

  # Buffer part 0 of an unfinished 2-part message.
  client.rawSend(
    server.address,
    partPacket(1, connId, 0, 2, "real")
  )
  client.tick()
  server.tick()
  doAssert server.connections[0].recvParts.len == 1

  # Same seq/part, different payload — must not assert.
  client.rawSend(
    server.address,
    partPacket(1, connId, 0, 2, "FAKE")
  )
  client.tick()
  server.tick()
  doAssert server.connections[0].recvParts.len == 1
  doAssert server.connections[0].recvParts[0].data == "real"
  doAssert server.messages.len == 0

block:
  # Empty send must not assert; no-op is fine.
  echo "Testing empty send is safe"
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  var c2s = client.connect(server.address)
  client.send(c2s, "")
  client.tick()
  server.tick()
  doAssert server.messages.len == 0
  doAssert c2s.sendParts.len == 0

block:
  # Invalid partNum / numParts must be ignored.
  echo "Testing invalid part fields ignored"
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()

  client.rawSend(
    server.address,
    partPacket(0, 1, 0, 0, "bad")
  )
  client.rawSend(
    server.address,
    partPacket(0, 2, 5, 3, "bad")
  )
  client.tick()
  server.tick()
  doAssert server.connections.len == 0

block:
  # Payload must use byteLen, not buf.len - 1 clamping.
  echo "Testing payload length uses byteLen"
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  let payload = "abcdef"
  client.rawSend(
    server.address,
    partPacket(0, 42, 0, 1, payload)
  )
  client.tick()
  server.tick()
  doAssert server.messages.len == 1
  doAssert server.messages[0].data == payload

block:
  # readLatency must hold delivery until latency elapses.
  echo "Testing readLatency gates delivery"
  var server = newReactor("127.0.0.1", nextPort())
  server.debug.tickTime = 100.0
  server.debug.readLatency = 1.0
  server.tick()
  var client = newReactor()
  var c2s = client.connect(server.address)

  client.send(c2s, "late")
  client.tick()
  server.tick()
  doAssert server.messages.len == 0, "message arrived before latency"

  server.debug.tickTime = 101.1
  server.tick()
  doAssert server.messages.len == 1
  doAssert server.messages[0].data == "late"

block:
  # maxInFlight must count bytes awaiting ACK across ticks.
  echo "Testing maxInFlight across ticks without ack"
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())
  client.maxUdpPacket = 100
  client.maxInFlight = 1000
  client.debug.tickTime = 10.0
  client.tick()

  var buffer = newString(5000)
  for i in 0 ..< buffer.len:
    buffer[i] = 'x'

  var c2s = client.connect(server.address)
  client.send(c2s, buffer)

  client.tick()
  var sentCount = 0
  for part in c2s.sendParts:
    if part.sentTime != 0:
      inc sentCount
  doAssert c2s.stats.inFlight <= client.maxInFlight,
    $c2s.stats.inFlight
  doAssert c2s.stats.saturated == true
  doAssert sentCount > 0

  # Second tick before RTO and before any ACK must not send more.
  client.tick()
  var sentCount2 = 0
  for part in c2s.sendParts:
    if part.sentTime != 0:
      inc sentCount2
  doAssert sentCount2 == sentCount,
    &"sent more without ack: {sentCount2} vs {sentCount}"
  doAssert c2s.stats.inFlight <= client.maxInFlight,
    $c2s.stats.inFlight

block:
  # inQueue must not go negative on retry.
  echo "Testing inQueue on retry"
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())
  client.debug.tickTime = 20.0
  client.tick()
  var c2s = client.connect(server.address)
  client.send(c2s, "retry-me")
  client.tick()
  doAssert c2s.stats.inQueue == 0, $c2s.stats.inQueue

  client.debug.tickTime = 20.0 + AckTime
  client.tick()
  doAssert c2s.stats.inQueue == 0, $c2s.stats.inQueue
  doAssert c2s.sendParts.len == 1

block:
  # Disconnect packet must not take down later traffic.
  echo "Testing truncated disconnect then real message"
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  var c2s = client.connect(server.address)

  var trunc = ""
  trunc.addUint32(DisconnectMagic)
  client.rawSend(server.address, trunc)
  client.send(c2s, "after")
  client.tick()
  server.tick()
  doAssert server.messages.len == 1
  doAssert server.messages[0].data == "after"

block:
  # Sequence wrap: old-looking high seq must not be treated as future forever.
  echo "Testing sequence number wrap comparison"
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  var c2s = client.connect(server.address)

  client.send(c2s, "first")
  client.tick()
  server.tick()
  doAssert server.messages.len == 1

  let conn = server.connections[0]
  # Pretend we have already accepted messages up through high(uint32).
  conn.recvSequenceNum = 0
  conn.recvParts.setLen(0)

  # Inject a part that is "behind" after wrap using serial comparison.
  # After recvSequenceNum = 5, sequence 4 is old and must be ignored.
  conn.recvSequenceNum = 5
  client.rawSend(
    server.address,
    partPacket(4, conn.id, 0, 1, "old")
  )
  client.tick()
  server.tick()
  doAssert server.messages.len == 0
  doAssert conn.recvParts.len == 0

  client.rawSend(
    server.address,
    partPacket(5, conn.id, 0, 1, "next")
  )
  client.tick()
  server.tick()
  doAssert server.messages.len == 1
  doAssert server.messages[0].data == "next"

block:
  # close() tears down the socket and is idempotent.
  echo "Testing reactor close"
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  var c2s = client.connect(server.address)
  client.send(c2s, "bye")
  client.tick()
  server.tick()
  doAssert server.messages.len == 1

  client.close()
  doAssert client.socket == nil
  doAssert client.connections.len == 0
  client.tick()
  client.close()

  server.tick()
  doAssert server.deadConnections.len == 1
  doAssert server.connections.len == 0
  server.close()
  doAssert server.socket == nil

echo "All hardening tests passed"
