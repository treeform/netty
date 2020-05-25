import os, osproc, streams, strformat

include netty

var s = newFileStream("tests/test-output.txt", fmWrite)

s.writeLine "Testing netty"

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
  var server = newReactor("127.0.0.1", 1999)
  var client = newReactor()
  var c2s = client.connect(server.address)
  client.send(c2s, "hi")
  client.tick()
  server.tick()
  for msg in server.messages:
    s.writeLine "MESSAGE ", msg.data

block:
  s.writeLine "main test"

  var server = newReactor("127.0.0.1", 2000)
  var client = newReactor("127.0.0.1", 2001)

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
  assert server.connections[0].id == client.connections[0].id

block:
  s.writeLine "testing large message"

  var server = newReactor("127.0.0.1", 2002)
  var client = newReactor("127.0.0.1", 2003)

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
  var server = newReactor("127.0.0.1", 2004)
  var client = newReactor("127.0.0.1", 2005)
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
      assert index != -1
      dataToSend.delete(index)
    if dataToSend.len == 0: break
  # make sure all messages made it
  assert dataToSend.len == 0, &"datatoSend.len: {datatoSend.len}"
  s.writeLine dataToSend

block:
  s.writeLine "many messages stress test with packet loss 10%"

  var dataToSend = newSeq[string]()
  for i in 0 ..< 1000:
    dataToSend.add &"data #{i}, its cool!"

  # stress
  var server = newReactor("127.0.0.1", 2006)
  var client = newReactor("127.0.0.1", 2007)
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
      assert index != -1
      dataToSend.delete(index)
    if dataToSend.len == 0: break
  # make sure all messages made it
  s.writeLine dataToSend
  assert dataToSend.len == 0

block:
  s.writeLine "many clients stress test"

  s.writeLine "100 clients"
  var dataToSend = newSeq[string]()
  for i in 0 ..< 100:
    dataToSend.add &"data #{i}, its cool!"

  # stress
  var server = newReactor("127.0.0.1", 2008)
  for d in dataToSend:
    var client = newReactor()
    var c2s = client.connect(server.address)
    client.send(c2s, d)
    client.tick()

  server.tick()

  assert len(server.connections) == 100
  assert len(server.newConnections) == 100

  for msg in server.messages:
    var index = dataToSend.find(msg.data)
    # make sure message is there
    assert index != -1
    dataToSend.delete(index)
  # make sure all messages made it
  assert dataToSend.len == 0
  s.writeLine dataToSend

  var shouldBeDead: seq[uint32]

  for i in 0 ..< 50:
    let conn = server.connections[i]
    shouldBeDead.add(conn.id)
    server.send(server.connections[i], "timeout_trigger")
  server.tick()

  # Cause timeouts
  server.debug.tickTime = epochTime() + connTimeout
  server.tick()

  assert len(server.connections) == 50
  assert len(server.deadConnections) == 50

  for conn in server.deadConnections:
    shouldBeDead.delete(shouldBeDead.find(conn.id))

  assert len(shouldBeDead) == 0

block:
  s.writeLine "punch through test"
  var server = newReactor("127.0.0.1", 2009)
  var client = newReactor()
  var c2s = client.connect(server.address)
  client.punchThrough(server.address)
  client.send(c2s, "hi")
  client.tick()
  server.tick()
  for msg in server.messages:
    s.writeLine "MESSAGE ", msg.data

block:
  s.writeLine "single client disconnect"
  var server = newReactor("127.0.0.1", 2010)
  var client = newReactor()
  var c2s = client.connect(server.address)
  client.send(c2s, "hi")
  client.tick()
  server.tick()
  assert len(server.messages) == 1
  assert len(server.connections) == 1
  client.debug.tickTime = epochTime() + connTimeout
  client.tick()
  assert len(client.deadConnections) == 1
  assert len(client.connections) == 0

block:
  s.writeLine "testing maxUdpPacket and maxInFlight"

  var server = newReactor("127.0.0.1", 2011)
  var client = newReactor("127.0.0.1", 2012)

  client.debug.maxUdpPacket = 100
  client.maxInFlight = 10_000

  var buffer = "large:"
  for i in 0 ..< 1000:
    buffer.add "<data>"
  s.writeLine "sent", buffer.len
  var c2s = client.connect(server.address)
  client.send(c2s, buffer)
  client.send(c2s, buffer)

  assert c2s.sendParts.len == 122

  client.tick() # can only send 100 parts due to maxInFlight and maxUdpPacket

  assert c2s.stats.saturated == true

  server.tick() # receives 100 parts, sends acks back

  assert server.messages.len == 1, &"len: {server.messages.len}"
  assert c2s.stats.inFlight < client.maxInFlight,
    &"stats.inFlight: {c2s.stats.inFlight}"
  assert c2s.stats.saturated == true

  client.tick() # process the 100 acks, 22 parts left in flight

  assert c2s.sendParts.len == 22
  assert c2s.stats.inFlight == 2106, &"stats.inFlight: {c2s.stats.inFlight}"
  assert c2s.stats.saturated == false

  server.tick() # process the last 22 parts, send 22 acks

  assert server.messages.len == 1, &"len: {server.messages.len}"

  client.tick() # receive the 22 acks

  assert c2s.sendParts.len == 0
  assert c2s.stats.inFlight == 0, &"stats.inFlight: {c2s.stats.inFlight}"
  assert c2s.stats.saturated == false
  assert c2s.stats.avgLatency > 0
  assert c2s.stats.throughput > 0

block:
  s.writeLine "testing retry"

  var server = newReactor("127.0.0.1", 2013)
  var client = newReactor("127.0.0.1", 2014)

  var c2s = client.connect(server.address)
  client.send(c2s, "test")

  client.tick()

  assert c2s.sendParts.len == 1

  let firstSentTime = c2s.sendParts[0].sentTime

  client.debug.tickTime = epochTime() + ackTime

  client.tick()

  assert c2s.sendParts[0].sentTime != firstSentTime # We sent the part again

block:
  s.writeLine "testing junk data"

  var server = newReactor("127.0.0.1", 2015)
  var client = newReactor("127.0.0.1", 2016)

  var c2s = client.connect(server.address)

  client.rawSend(c2s.address, "asdf")

  client.tick()
  server.tick()

  # No new connection, no crash
  assert server.newConnections.len == 0
  assert server.connections.len == 0

  var stream = newStringStream()
  stream.write(partMagic)
  stream.write("aasdfasdfaasdfaasdfasdfsdfsdasdfasdfsaasdfasdffsadfaasdfasdfa")
  stream.setPosition(0)
  let packet = stream.readAll()

  client.rawSend(c2s.address, packet)

  client.tick()
  server.tick()

  # No new connection, no crash
  assert server.newConnections.len == 0
  assert server.connections.len == 0

block:
  s.writeLine "disconnect packet"
  var server = newReactor("127.0.0.1", 2017)
  var client = newReactor()
  var c2s = client.connect(server.address)
  client.send(c2s, "hi")
  client.tick()
  server.tick()
  assert len(server.messages) == 1
  assert len(server.connections) == 1
  assert len(client.connections) == 1
  client.disconnect(c2s)
  assert len(client.deadConnections) == 1
  assert len(client.connections) == 0
  client.tick()
  server.tick()
  assert len(server.deadConnections) == 1
  assert len(server.connections) == 0


s.close()

let (outp, _) = execCmdEx("git diff tests/test-output.txt")
if len(outp) != 0:
  echo outp
  quit("Output does not match")
