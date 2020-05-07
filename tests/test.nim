import strformat, osproc, random, streams, os

include netty

var s = newFileStream("tests/test-output.txt", fmWrite)

s.writeLine "Testing netty"

randomize(2001)

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

  s.writeLine "client should have part ACK:true"

  display("server", server)
  display("client", client)

  s.writeLine "id should match"
  assert server.connections[0].id == client.connections[0].id

block:
  s.writeLine "testing large message"

  var server = newReactor("127.0.0.1", 2002)
  var client = newReactor("127.0.0.1", 2003)

  s.writeLine maxUdpPacket
  var buffer = "large:"
  for i in 0..<1000:
    buffer.add "<data>"
  s.writeLine "sent", buffer.len
  var c2s = client.connect(server.address)
  client.send(c2s, buffer)

  for i in 0..10:
    client.tick()
    server.tick()

    for msg in server.messages:
      s.writeLine "got", msg.data.len
      s.writeLine "they match", msg.data == buffer

block:
  s.writeLine "many messages stress test"

  var dataToSend = newSeq[string]()
  s.writeLine "1000 messages"
  for i in 0..1000:
    dataToSend.add &"data #{i}, its cool!"

  # stress
  var server = newReactor("127.0.0.1", 2004)
  var client = newReactor("127.0.0.1", 2005)
  var c2s = client.connect(server.address)
  for d in dataToSend:
    client.send(c2s, d)
  for i in 0..1000:
    client.tick()
    server.tick()
    for msg in server.messages:
      var index = dataToSend.find(msg.data)
      # make sure message is there
      assert index != -1
      dataToSend.delete(index)
  # make sure all messages made it
  assert dataToSend.len == 0
  s.writeLine dataToSend

block:
  s.writeLine "many messages stress test with packet loss 10%"

  var dataToSend = newSeq[string]()
  for i in 0..1000:
    dataToSend.add &"data #{i}, its cool!"

  # stress
  var server = newReactor("127.0.0.1", 2006)
  var client = newReactor("127.0.0.1", 2007)
  client.debug.dropRate = 0.2 # 20% packet loss rate is broken for most things
  s.writeLine "20% drop rate"
  var c2s = client.connect(server.address)
  for d in dataToSend:
    client.send(c2s, d)
  for i in 0..1000:
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
  server.tick(epochTime() + connTimeout)

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
  client.tick(time = epochTime() + connTimeout)
  assert len(client.deadConnections) == 1
  assert len(client.connections) == 0

s.close()

let (outp, _) = execCmdEx("git diff tests/test-output.txt")
if len(outp) != 0:
  echo outp
  quit("Output does not match")
