import strformat, osproc, random, streams, os

include netty

var s = newFileStream("tests/test-output.txt", fmWrite)

s.writeLine "Testing netty"

randomize(2001)

proc display(name: string, r: Reactor) =
  s.writeLine "REACTOR: ", name, " (", r.address, ")"
  for c in r.connections:
    s.writeLine "  CONN: ", c.address
    for part in c.sentParts:
      s.writeLine "    SENT PART: ", part
    for part in c.recvParts:
      s.writeLine "    RECV PART: ", part
  for packet in r.packets:
    s.writeLine "  PACKET: ", packet

block:
  s.writeLine "simple test"
  var server = newReactor("127.0.0.1", 1999)
  var client = newReactor()
  maxUdpPacket = 100
  var c2s = client.connect(server.address)
  c2s.send("hi")
  for i in 0..10:
    client.tick()
    server.tick()
    for packet in server.packets:
      s.writeLine "PACKET ", packet.data

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

  c2s.send("hey you")
  client.tick()
  server.tick()

  s.writeLine "server should have packet"
  s.writeLine "client should have part ACK:false"

  display("server", server)
  display("client", client)

  server.tick() # get packet, ack packet
  client.tick() # get ack

  s.writeLine "client should have part ACK:true"

  display("server", server)
  display("client", client)

  s.writeLine "rid should match"
  assert server.connections[0].rid == client.connections[0].rid

  c2s.disconnect()

block:
  s.writeLine "testing large packet"

  var server = newReactor("127.0.0.1", 2002)
  var client = newReactor("127.0.0.1", 2003)

  maxUdpPacket = 100
  s.writeLine maxUdpPacket
  var buffer = "large:"
  for i in 0..<1000:
    buffer.add "<data>"
  s.writeLine "sent", buffer.len
  var c2s = client.connect(server.address)
  c2s.send(buffer)

  for i in 0..10:
    client.tick()
    server.tick()

    for packet in server.packets:
      s.writeLine "got", packet.data.len
      s.writeLine "they match", packet.data == buffer

# block:
#   s.writeLine "many packets stress test"

#   var dataToSend = newSeq[string]()
#   s.writeLine "1000 packets"
#   for i in 0..1000:
#     dataToSend.add &"data #{i}, its cool!"

#   # stress
#   var server = newReactor("127.0.0.1", 2004)
#   var client = newReactor("127.0.0.1", 2005)
#   var c2s = client.connect(server.address)
#   for d in dataToSend:
#     c2s.send(d)
#   for i in 0..1000:
#     client.tick()
#     server.tick()
#     for packet in server.packets:
#       var index = dataToSend.find(packet.data)
#       # make sure packet is there
#       assert index != -1
#       dataToSend.delete(index)
#   # make sure all packets made it
#   assert dataToSend.len == 0
#   s.writeLine dataToSend

block:
  s.writeLine "many packets stress test with packet loss 10%"

  var dataToSend = newSeq[string]()
  for i in 0..1000:
    dataToSend.add &"data #{i}, its cool!"

  # stress
  var server = newReactor("127.0.0.1", 2006)
  var client = newReactor("127.0.0.1", 2007)
  client.simDropRate = 0.2 # 20% packet loss rate is broken for most things
  s.writeLine "20% drop rate"
  var c2s = client.connect(server.address)
  for d in dataToSend:
    c2s.send(d)
  for i in 0..1000:
    client.tick()
    server.tick()
    sleep(10)
    for packet in server.packets:
      var index = dataToSend.find(packet.data)
      # make sure packet is there
      assert index != -1
      dataToSend.delete(index)
    if dataToSend.len == 0: break
  # make sure all packets made it
  s.writeLine dataToSend
  assert dataToSend.len == 0

block:
  s.writeLine "many clients stress test"

  s.writeLine "100 clients"
  var dataToSend = newSeq[string]()
  for i in 0..100:
    dataToSend.add &"data #{i}, its cool!"

  # stress
  var server = newReactor("127.0.0.1", 2008)
  for d in dataToSend:
    var client = newReactor()
    var c2s = client.connect(server.address)
    c2s.send(d)
    client.tick()

  for i in 0..100:
    server.tick()
    for packet in server.packets:
      var index = dataToSend.find(packet.data)
      # make sure packet is there
      assert index != -1
      dataToSend.delete(index)
  # make sure all packets made it
  assert dataToSend.len == 0
  s.writeLine dataToSend

block:
  s.writeLine "punch through test"
  var server = newReactor("127.0.0.1", 2009)
  var client = newReactor()
  maxUdpPacket = 100
  var c2s = client.connect(server.address)
  client.punchThrough(server.address)
  c2s.send("hi")
  for i in 0..10:
    client.tick()
    server.tick()
    for packet in server.packets:
      s.writeLine "PACKET ", packet.data


s.close()

let (outp, _) = execCmdEx("git diff tests/test-output.txt")
if len(outp) != 0:
  echo outp
  quit("Output does not match")
