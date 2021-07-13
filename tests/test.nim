import flatty/binny, os, osproc, streams, strformat

include netty

var s = newFileStream("tests/test-output.txt", fmWrite)

s.writeLine "Testing netty"

var nextPortNumber = 3000
proc nextPort(): int =
  result = nextPortNumber
  inc nextPortNumber

proc display(name: string, r: Reactor) =
  s.writeLine "REACTOR: ", name, " (", r.address, ")"
  for c in r.connections:
    s.writeLine "  CONN: ", c.address
    for part in c.sendParts:
      s.writeLine "    SEND PART: ", part
    for part in c.recvParts:
      s.writeLine "    RECV PART: ", part
  for msg in r.messages:
    s.writeLine "  MESSAGE: ", msg

block:
  s.writeLine "simple test"
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  var c2s = client.connect(server.address)
  client.send(c2s, "hi")
  client.tick()
  server.tick()
  for msg in server.messages:
    s.writeLine "MESSAGE ", msg.data

block:
  s.writeLine "main test"

  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())

  display("server", server)
  display("client", client)

  s.writeLine "connect"
  var c2s = client.connect(server.address)

  display("server", server)
  display("client", client)

  s.writeLine "client --------- 'hey you' ----------> server"

  client.send(c2s, "hey you")
  client.tick()
  server.tick()

  s.writeLine "server should have message"
  s.writeLine "client should have part ACK:false"

  display("server", server)
  display("client", client)

  server.tick() # get message, ack message
  client.tick() # get ack

  s.writeLine "client should not have any parts now, acked parts deleted"

  display("server", server)
  display("client", client)

  s.writeLine "id should match"
  doAssert server.connections[0].id == client.connections[0].id

block:
  s.writeLine "single client disconnect"
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
  s.writeLine "testing large message"

  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())

  s.writeLine client.debug.maxUdpPacket
  var buffer = "large:"
  for i in 0 ..< 1000:
    buffer.add "<data>"
  s.writeLine "sent", buffer.len
  var c2s = client.connect(server.address)
  client.send(c2s, buffer)

  for i in 0 ..< 10:
    client.tick()
    server.tick()

    for msg in server.messages:
      s.writeLine "got", msg.data.len
      s.writeLine "they match", msg.data == buffer

block:
  s.writeLine "many messages stress test"

  var dataToSend = newSeq[string]()
  s.writeLine "1000 messages"
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
    sleep(10)
    for msg in server.messages:
      var index = dataToSend.find(msg.data)
      # make sure message is there
      doAssert index != -1
      dataToSend.delete(index)
    if dataToSend.len == 0: break
  # make sure all messages made it
  doAssert dataToSend.len == 0, &"datatoSend.len: {datatoSend.len}"
  s.writeLine dataToSend

block:
  s.writeLine "many messages stress test with packet loss 10%"

  var dataToSend = newSeq[string]()
  for i in 0 ..< 1000:
    dataToSend.add &"data #{i}, its cool!"

  # stress
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())
  client.debug.dropRate = 0.2 # 20% packet loss rate is broken for most things
  s.writeLine "20% drop rate"
  var c2s = client.connect(server.address)
  for d in dataToSend:
    client.send(c2s, d)
  for i in 0 ..< 1000:
    client.tick()
    server.tick()
    sleep(10)
    for msg in server.messages:
      var index = dataToSend.find(msg.data)
      # make sure message is there
      doAssert index != -1
      dataToSend.delete(index)
    if dataToSend.len == 0: break
  # make sure all messages made it
  s.writeLine dataToSend
  doAssert dataToSend.len == 0

block:
  s.writeLine "many clients stress test"

  s.writeLine "100 clients"
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
  s.writeLine dataToSend

  server.debug.tickTime = 1.0 + connTimeout
  server.tick()

  doAssert len(server.connections) == 0, $server.connections.len
  doAssert len(server.deadConnections) == 100, $server.deadConnections.len

block:
  s.writeLine "punch through test"
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor()
  var c2s = client.connect(server.address)
  client.punchThrough(server.address)
  client.send(c2s, "hi")
  client.tick()
  server.tick()
  for msg in server.messages:
    s.writeLine "MESSAGE ", msg.data

block:
  s.writeLine "testing maxUdpPacket and maxInFlight"

  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())

  client.debug.maxUdpPacket = 100
  client.maxInFlight = 10_000

  var buffer = "large:"
  for i in 0 ..< 1000:
    buffer.add "<data>"
  s.writeLine "sent", buffer.len
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
  s.writeLine "testing retry"

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
  s.writeLine "testing junk data"

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
  s.writeLine "disconnect packet"
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
  var server = newReactor("127.0.0.1", nextPort())
  var client = newReactor("127.0.0.1", nextPort())

  client.maxInFlight = 10_000

  var buffer = ""
  for i in 0 ..< 1_000_000:
    buffer.add "F"

  var c2s = client.connect(server.address)

  for p in 0 ..< 20:
    client.send(c2s, buffer)

  while true:
    client.tick()
    server.tick()
    if client.connections.len == 0:
      break

s.close()

var n = readFile("tests/test-output.txt")
var m = readFile("tests/test-output.master.txt")

if n != m:
  s.writeLine "Output does not match master."
