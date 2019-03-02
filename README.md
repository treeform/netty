# NetPipe - reliable UDP connection for Nim.

Reliable connection over UDP. UDP packets can get duplicated, dropped, or come out of order. NetPipe makes sure packets are not duplicated, resends them if they get dropepd. Makse sure all packets come in order. UDP packets might also get split if they are above 512 bytes and also can fail to be sent if they are bigger then 1-2k. NetPipe breaks up big packets and sends them in pices making sure each pice comes in order and reliably. Finally some times its impossible for two clients to communicate direclty because of NATs, but NetPipe provides UDP hole punching which allows them to connect.

Features:
* packet ordering
* packet splitting
* packet retry
* packet deduplication
* packet splitting and stiticing backup
* hole punch through.
* automatic handling of connects and disconnects

# Server/Client example

## server.nim

```nim
import netpipe

# listen for a connection on localhost port 1999
var server = newReactor("127.0.0.1", 1999)
echo "Listenting for UDP on 127.0.0.1:1999"
# main loop
while true:
  # must call tick to both read and write
  server.tick()
  # usually there are no new packets, but if there are
  for packet in server.packets:
    # print packet data
    echo "GOT PACKET: ", packet.data
    # echo packet back to the client
    packet.connection.send("you said:" & packet.data)

```

## client.nim

```nim
import netpipe

# create connection
var client = newReactor()
# connect to server
var c2s = client.connect("127.0.0.1", 1999)
# send message on the connection
c2s.send("hi")
# main loop
while true:
  # must call tick to both read and write
  client.tick()
  # usually there are no new packets, but if there are
  for packet in client.packets:
    # print packet data
    echo "GOT PACKET: ", packet.data
```

# Chat Server/Client example

## chatserver.nim

```nim
import netpipe

var server = newReactor("127.0.0.1", 2001)
echo "Listenting for UDP on 127.0.0.1:2001"
while true:
  server.tick()
  for connection in server.newConnections:
    echo "[new] ", connection.address
  for connection in server.deadConnections:
    echo "[dead] ", connection.address
  for packet in server.packets:
    echo packet.data
    # send packet data to all connections
    for connection in server.connections:
      connection.send(packet.data)
```

## chatclient.nim

```nim
import netpipe

var client = newReactor()
var connection = client.connect("127.0.0.1", 2001)

# get persons name
echo "what is your name?"
var name = readLine(stdin)
echo "note: press enter to see if people sent you things"

while true:
  client.tick()
  for packet in client.packets:
    echo packet.data

  # wait for user to type a line
  let line = readLine(stdin)
  if line.len > 0:
    connection.send(name & ":" & line)
```