import flatty/binny, os, osproc, streams, strformat

include netty

var nextPortNumber = 3000
proc nextPort(): int =
  ## Use next port, so that we don't reuse ports during test.
  result = nextPortNumber
  inc nextPortNumber

block:
  # Text simple send.
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  var c2s = client.connect(server.address)
  client.send(c2s, "hi")
  client.tick()
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
  server.tick()

  # server should have message
  doAssert server.messages.len == 1

  # client should have part ACK:false
  doAssert client.connections[0].sendParts.len == 1
  doAssert client.connections[0].recvParts.len == 0

  server.tick() # get message, ack message
  client.tick() # get ack

  # client should not have any parts now, acked parts deleted
  doAssert client.connections[0].sendParts.len == 0
  doAssert client.connections[0].recvParts.len == 0

  # id should match
  doAssert server.connections[0].id == client.connections[0].id

block:
  # Text single client disconnect.
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  client.debug.tickTime = 1.0
  client.tick()
  var c2s = client.connect(server.address)
  client.send(c2s, "hi")
  client.tick()
  server.tick()
  client.tick()
  doAssert len(server.messages) == 1, $server.messages.len
  doAssert len(server.connections) == 1, $server.connections.len
  client.debug.tickTime = 1.0 + connTimeout
  client.tick()
  doAssert len(client.deadConnections) == 1
  doAssert len(client.connections) == 0

block:
  # Text large message.

  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())

  doAssert client.debug.maxUdpPacket == 492
  var buffer = "large:"
  for i in 0 ..< 1000:
    buffer.add "<data>"
  doAssert buffer.len == 6006
  var c2s = client.connect(server.address)
  client.send(c2s, buffer)

  for i in 0 ..< 10:
    client.tick()
    server.tick()

    for msg in server.messages:
      # large packets match
      doAssert msg.data == buffer

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
    sleep(1)
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
  server.tick()

  doAssert len(server.connections) == 100
  doAssert len(server.newConnections) == 100

  for msg in server.messages:
    var index = dataToSend.find(msg.data)
    # make sure message is there
    doAssert index != -1
    dataToSend.delete(index)
  # make sure all messages made it
  doAssert dataToSend.len == 0

  server.debug.tickTime = 1.0 + connTimeout
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
  server.tick()
  doAssert server.messages.len == 1
  doAssert server.messages[0].data == "hi"

block:
  # Test maxUdpPacket and maxInFlight.

  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())

  client.debug.maxUdpPacket = 100
  client.maxInFlight = 10_000

  var buffer = "large:"
  for i in 0 ..< 1000:
    buffer.add "<data>"

  var c2s = client.connect(server.address)
  client.send(c2s, buffer)
  client.send(c2s, buffer)

  doAssert c2s.sendParts.len == 122

  client.tick() # can only send 100 parts due to maxInFlight and maxUdpPacket

  doAssert c2s.stats.saturated == true

  server.tick() # receives 100 parts, sends acks back

  doAssert server.messages.len == 1, &"len: {server.messages.len}"
  doAssert c2s.stats.inFlight < client.maxInFlight,
    &"stats.inFlight: {c2s.stats.inFlight}"
  doAssert c2s.stats.saturated == true

  client.tick() # process the 100 acks, 22 parts left in flight

  doAssert c2s.sendParts.len == 22
  doAssert c2s.stats.inFlight == 2106, &"stats.inFlight: {c2s.stats.inFlight}"
  doAssert c2s.stats.saturated == false

  server.tick() # process the last 22 parts, send 22 acks

  doAssert server.messages.len == 1, &"len: {server.messages.len}"

  client.tick() # receive the 22 acks

  doAssert c2s.sendParts.len == 0
  doAssert c2s.stats.inFlight == 0, &"stats.inFlight: {c2s.stats.inFlight}"
  doAssert c2s.stats.saturated == false
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

  client.debug.tickTime = epochTime() + ackTime

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
  msg.addUint32(partMagic)
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
  server.tick()

  doAssert len(server.messages) == 1
  doAssert len(server.connections) == 1
  doAssert len(client.connections) == 1

  client.disconnect(c2s)

  doAssert len(client.deadConnections) == 1
  doAssert len(client.connections) == 0

  client.tick()
  server.tick()

  doAssert len(server.deadConnections) == 1
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

  while true:
    client.tick()
    server.tick()
    gotNumber += server.messages.len
    for msg in server.messages:
      doAssert msg.data == buffer
    if client.connections.len == 0:
      break

  doAssert gotNumber == 20
