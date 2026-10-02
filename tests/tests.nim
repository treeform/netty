import flatty/binny, os, strformat

include netty

var nextPortNumber = 3000
proc nextPort(): int =
  ## Use next port, so that we don't reuse ports during test.
  result = nextPortNumber
  inc nextPortNumber

template waitFor(condition, body: untyped) =
  ## Runs ticks until a condition holds or a five-second deadline expires.
  block:
    let deadline = getMonoTime() + initDuration(seconds = 5)
    while not condition:
      doAssert getMonoTime() < deadline,
        "Timed out waiting for " & astToStr(condition)
      body
      if not condition:
        sleep(1)

block:
  # Text simple send.
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  var c2s = client.connect(server.address)
  client.send(c2s, "hi")
  client.tick()
  waitFor server.messages.len > 0:
    server.tick()
  doAssert server.messages.len == 1
  doAssert server.messages[0].data == "hi"

block:
  # Tewxt sends and acks.

  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())

  # connect
  var c2s = client.connect(server.address)

  # client --------- 'hey you' ----------> server

  client.send(c2s, "hey you")
  client.tick()
  waitFor server.messages.len > 0:
    server.tick()

  # server should have message
  doAssert server.messages.len == 1

  # client should have part ACK:false
  doAssert client.connections[0].sendParts.len == 1
  doAssert client.connections[0].recvPartCount == 0

  waitFor client.connections[0].sendParts.len == 0:
    client.tick()

  # client should not have any parts now, acked parts deleted
  doAssert client.connections[0].sendParts.len == 0
  doAssert client.connections[0].recvPartCount == 0

  # id should match
  doAssert server.connections[0].id == client.connections[0].id

block:
  # Test single client disconnect.
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  client.debug.tickTime = 1.0
  client.tick()
  var c2s = client.connect(server.address)
  client.send(c2s, "hi")
  client.tick()
  waitFor server.messages.len > 0:
    server.tick()
  doAssert len(server.messages) == 1, $server.messages.len
  doAssert len(server.connections) == 1, $server.connections.len
  # Drain ACKs so a late packet does not refresh lastActiveTime.
  waitFor c2s.sendParts.len == 0:
    client.tick()
  client.debug.tickTime = 1.0 + ConnTimeout
  client.tick()
  doAssert len(client.deadConnections) == 1
  doAssert len(client.connections) == 0

block:
  # Text large message.

  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())

  doAssert client.maxUdpPacket == 492
  var buffer = "large:"
  for i in 0 ..< 1000:
    buffer.add "<data>"
  doAssert buffer.len == 6006
  var c2s = client.connect(server.address)
  client.send(c2s, buffer)

  var got = 0
  waitFor got == 1 and c2s.sendParts.len == 0:
    client.tick()
    server.tick()
    for msg in server.messages:
      doAssert msg.data == buffer
      inc got
      doAssert got == 1

block:
  # Stress test many messages.

  var dataToSend = newSeq[string]()

  for i in 0 ..< 1000:
    dataToSend.add &"data #{i}, its cool!"

  # stress
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())
  var c2s = client.connect(server.address)
  for d in dataToSend:
    client.send(c2s, d)
  for i in 0 ..< 1000:
    client.tick()
    server.tick()
    sleep(1)
    for msg in server.messages:
      var index = dataToSend.find(msg.data)
      # make sure message is there
      doAssert index != -1
      dataToSend.delete(index)
    if dataToSend.len == 0: break
  # make sure all messages made it
  doAssert dataToSend.len == 0, &"datatoSend.len: {datatoSend.len}"

block:
  # Stress test many messages with packet loss 10%.

  var dataToSend = newSeq[string]()
  for i in 0 ..< 1000:
    dataToSend.add &"data #{i}, its cool!"

  # stress
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())
  client.debug.dropRate = 0.2 # 20% packet loss rate is broken for most things

  var c2s = client.connect(server.address)
  for d in dataToSend:
    client.send(c2s, d)
  for i in 0 ..< 1000:
    client.tick()
    server.tick()
    sleep(2)
    for msg in server.messages:
      var index = dataToSend.find(msg.data)
      # make sure message is there
      doAssert index != -1
      dataToSend.delete(index)
    if dataToSend.len == 0: break
  # make sure all messages made it
  doAssert dataToSend.len == 0

block:
  # Stress test many clients.

  var dataToSend = newSeq[string]()
  for i in 0 ..< 100:
    dataToSend.add &"data #{i}, its cool!"

  # stress
  var server = newReactor("127.0.0.1", nextPort())
  for d in dataToSend:
    var client = newReactor()
    var c2s = client.connect(server.address)
    client.send(c2s, d)
    client.tick()

  server.debug.tickTime = 1.0
  var newCount = 0
  waitFor server.connections.len == 100:
    server.tick()
    newCount += server.newConnections.len
    for msg in server.messages:
      let index = dataToSend.find(msg.data)
      doAssert index != -1
      dataToSend.delete(index)

  doAssert len(server.connections) == 100
  doAssert newCount == 100
  # make sure all messages made it
  doAssert dataToSend.len == 0

  server.debug.tickTime = 1.0 + ConnTimeout
  server.tick()

  doAssert len(server.connections) == 0, $server.connections.len
  doAssert len(server.deadConnections) == 100, $server.deadConnections.len

block:
  # Test punch through.
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  var c2s = client.connect(server.address)
  client.punchThrough(server.address)
  client.send(c2s, "hi")
  client.tick()
  waitFor server.messages.len > 0:
    server.tick()
  doAssert server.messages.len == 1
  doAssert server.messages[0].data == "hi"

block:
  # Test maxUdpPacket and maxInFlight.

  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())

  client.maxUdpPacket = 100
  client.maxInFlight = 10_000

  var buffer = "large:"
  for i in 0 ..< 1000:
    buffer.add "<data>"

  var c2s = client.connect(server.address)
  client.send(c2s, buffer)
  client.send(c2s, buffer)

  doAssert c2s.sendParts.len == 122

  client.tick()

  doAssert c2s.stats.saturated == true
  doAssert c2s.stats.inFlight <= client.maxInFlight,
    &"stats.inFlight: {c2s.stats.inFlight}"

  # Without a server tick there are no ACKs, so the window must stay full.
  let queued = c2s.stats.inQueue
  doAssert queued > 0
  client.tick()
  doAssert c2s.sendParts.len == 122
  doAssert c2s.stats.inQueue == queued
  doAssert c2s.stats.saturated
  doAssert c2s.stats.inFlight <= client.maxInFlight

  # ACKs can arrive across ticks, and messages are cleared by each tick.
  var got = 0
  waitFor c2s.sendParts.len == 0 and got == 2:
    client.tick()
    doAssert client.connections.len == 1
    doAssert c2s.stats.inFlight <= client.maxInFlight
    server.tick()
    for msg in server.messages:
      doAssert msg.data == buffer
      doAssert msg.sequenceNum == got.uint32
      inc got
      doAssert got <= 2

  doAssert c2s.sendParts.len == 0, &"sendParts left: {c2s.sendParts.len}"
  doAssert c2s.stats.inFlight == 0, &"stats.inFlight: {c2s.stats.inFlight}"
  doAssert c2s.stats.saturated == false
  doAssert got == 2, &"messages got: {got}"
  doAssert c2s.stats.latencyTs.avg() > 0
  doAssert c2s.stats.throughputTs.avg() > 0

block:
  # Test retry.

  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())

  var c2s = client.connect(server.address)
  client.send(c2s, "test")

  client.tick()

  doAssert c2s.sendParts.len == 1

  let firstSentTime = c2s.sendParts[0].sentTime

  client.debug.tickTime = epochTime() + AckTime

  client.tick()

  doAssert c2s.sendParts[0].sentTime != firstSentTime # We sent the part again

block:
  # Test junk data.

  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())

  var c2s = client.connect(server.address)

  client.rawSend(c2s.address, "asdf")

  client.tick()
  server.tick()

  # No new connection, no crash
  doAssert server.newConnections.len == 0
  doAssert server.connections.len == 0

  var msg = ""
  msg.addUint32(PartMagic)
  msg.addStr("aasdfasdfaasdfaasdfasdfsdfsdasdfasdfsaasdfasdffsadfaasdfasdfa")

  client.rawSend(c2s.address, msg)

  client.tick()
  server.tick()

  # No new connection, no crash
  doAssert server.newConnections.len == 0
  doAssert server.connections.len == 0

block:
  # Text disconnect packet.
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  var c2s = client.connect(server.address)

  client.send(c2s, "hi")
  client.tick()
  waitFor server.messages.len > 0:
    server.tick()

  doAssert len(server.messages) == 1
  doAssert len(server.connections) == 1
  doAssert len(client.connections) == 1

  # A timeout must not satisfy the remote disconnect assertion.
  server.debug.tickTime = server.time
  client.disconnect(c2s)

  doAssert len(client.deadConnections) == 1
  doAssert len(client.connections) == 0

  client.tick()
  waitFor server.deadConnections.len > 0:
    server.tick()

  doAssert len(server.deadConnections) == 1
  doAssert server.deadConnections[0].id == c2s.id
  doAssert len(server.connections) == 0

block:
  # Test mange larger messages.
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())

  client.maxInFlight = 1000

  var buffer = ""
  for i in 0 ..< 10_000:
    buffer.add "F"

  var c2s = client.connect(server.address)

  for p in 0 ..< 20:
    client.send(c2s, buffer)

  var gotNumber = 0

  waitFor gotNumber == 20 and c2s.sendParts.len == 0:
    client.tick()
    doAssert client.connections.len == 1
    doAssert c2s.stats.inFlight <= client.maxInFlight
    server.tick()
    for msg in server.messages:
      doAssert msg.data == buffer
      doAssert msg.sequenceNum == gotNumber.uint32
      inc gotNumber
      doAssert gotNumber <= 20

  doAssert gotNumber == 20

block:
  var server = newReactor("127.0.0.1", nextPort())
  for i in 0 ..< 100:
    server.tick()
    for msg in server.messages:
      echo "GOT MESSAGE: ", msg.data
      server.send(msg.conn, "you said:" & msg.data)
    if i == 10:
      var client = newReactor()
      var c2s = client.connect(server.address)
      client.send(c2s, "hi")
      client.disconnect(c2s)
      client.disconnect(c2s)
