# nim c -r --verbosity:0 tests\netpipetest > tests\netpipe.test.txt; git diff tests\netpipe.test.txt


include netpipe
import print, strformat, sequtils, os

echo "Testing netpipe"

randomize(2001)



proc display(name: string, r: Reactor) =
  echo "REACTOR: ", name, " (", r.address, ")"
  for c in r.connections:
    echo "  CONN: ", c.address
    for part in c.sentParts:
      echo "    SENT PART: ", part
    for part in c.recvParts:
      echo "    RECV PART: ", part
  for packet in r.packets:
    echo "  PACKET: ", packet



block:
  echo "simple test"
  var server = newReactor("127.0.0.1", 1999)
  var client = newReactor()
  maxUdpPacket = 100
  var c2s = client.connect(server.address)
  c2s.send("hi")
  for i in 0..10:
    client.tick()
    server.tick()
    for packet in server.packets:
      print "PACKET ", packet.data


block:
  echo "main test"

  var server = newReactor("127.0.0.1", 2000)
  var client = newReactor("127.0.0.1", 2001)

  display("server", server)
  display("client", client)

  echo "connect"
  var c2s = client.connect(server.address)

  display("server", server)
  display("client", client)

  print "client --------- 'hey you' ----------> server"

  c2s.send("hey you")
  client.tick()
  server.tick()

  print "server should have packet"
  print "client should have part ACK:false"

  display("server", server)
  display("client", client)

  server.tick() # get packet, ack packet
  client.tick() # get ack

  print "client should have part ACK:true"

  display("server", server)
  display("client", client)

  print "rid should match"
  assert server.connections[0].rid == client.connections[0].rid

  c2s.disconnect()

block:
  echo "testing large packet"

  var server = newReactor("127.0.0.1", 2002)
  var client = newReactor("127.0.0.1", 2003)

  maxUdpPacket = 100
  print maxUdpPacket
  var buffer = "large:"
  for i in 0..<1000:
    buffer.add "<data>"
  print "sent", buffer.len
  var c2s = client.connect(server.address)
  c2s.send(buffer)

  for i in 0..10:
    client.tick()
    server.tick()

    for packet in server.packets:
      print "got", packet.data.len
      print "they match", packet.data == buffer


block:
  echo "many packets stress test"

  var dataToSend = newSeq[string]()
  print "1000 packets"
  for i in 0..1000:
    dataToSend.add &"data #{i}, its cool!"

  # stress
  var server = newReactor("127.0.0.1", 2004)
  var client = newReactor("127.0.0.1", 2005)
  var c2s = client.connect(server.address)
  for d in dataToSend:
    c2s.send(d)
  for i in 0..100:
    client.tick()
    server.tick()
    for packet in server.packets:
      var index = dataToSend.find(packet.data)
      # make sure packet is there
      assert index != -1
      dataToSend.delete(index)
  # make sure all packets made it
  assert dataToSend.len == 0
  print dataToSend


block:
  echo "many packets stress test with packet loss 10%"

  var dataToSend = newSeq[string]()
  for i in 0..1000:
    dataToSend.add &"data #{i}, its cool!"

  # stress
  var server = newReactor("127.0.0.1", 2006)
  var client = newReactor("127.0.0.1", 2007)
  client.simDropRate = 0.2 # 20% packet loss rate is broken for most things
  print "20% drop rate"
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
  print dataToSend
  assert dataToSend.len == 0



block:
  echo "many clients stress test"

  print "100 clients"
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
  print dataToSend


block:
  echo "punch through test"
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
      print "PACKET ", packet.data
