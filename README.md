# NetPipe - reliable UDP connection for Nim.

NetPipe is a reliable connection over UDP amed at games. Normally UDP packets can get duplicated, dropped, or come out of order. NetPipe makes sure packets are not duplicated, re-sends them if they get dropped. Makes sure all packets come in order. UDP packets might also get split if they are above 512 bytes and also can fail to be sent if they are bigger than 1-2k. NetPipe breaks up big packets and sends them in pieces making sure each piece comes reliably in order. Finally sometimes it's impossible for two clients to communicate direclty because of NATs, but NetPipe provides UDP hole punching which allows them to connect.

## Is netpipe a reimplementation of TCP?

TCP is really bad for short latency sensitive messages. TCP was designed for throughput (downloading files) not latency (games). Netpipe will resend stuff faster than TCP, netpipe will not buffer and you also get nat punch-through (which TCP does not have). Netpipe is basically "like TCP but for games".

## Features:

| feature                   | TCP   | UDP      | netpipe |
| ------------------------- | ----- | -------- | ------- |
| designed for low letnacy  | no    | yes      | yes     |
| designed for throughput   | yes   | no       | no      |
| packet framing            | no    | yes      | yes     |
| packet ordering           | yes   | no       | yes     |
| packet splitting          | yes   | no       | yes     |
| packet retry              | yes   | no       | yes     |
| packet deduplication      | yes   | no       | yes     |
| hole punch through        | no    | yes      | yes     |
| connection handling       | yes   | no       | yes     |
| congestion control        | yes   | no       | yes     |


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