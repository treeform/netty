# Netty - reliable UDP connection for Nim.

`nimble install netty`

![Github Actions](https://github.com/treeform/netty/workflows/Github%20Actions/badge.svg)

Netty is a reliable connection over UDP aimed at games. Normally UDP packets can get duplicated, dropped, or come out of order. Netty makes sure packets are not duplicated, re-sends them if they get dropped, and all packets come in order. UDP packets might also get split if they are above 512 bytes and also can fail to be sent if they are bigger than 1-2k. Netty breaks up big packets and sends them in pieces making sure each piece comes reliably in order. Finally sometimes it's impossible for two clients to communicate direclty with TCP because of NATs, but Netty provides hole punching which allows them to connect.

## Is Netty a implementation of TCP?

TCP is really bad for short latency sensitive messages. TCP was designed for throughput (downloading files) not latency (games). Netty will resend stuff faster than TCP, Netty will not buffer and you also get nat punch-through (which TCP does not have). Netty is basically "like TCP but for games". You should not be using Netty if you are will be sending large mount of data. By default Netty is capped at 250K of data in flight.

## Features:

| feature                   | TCP   | UDP      | Netty |
| ------------------------- | ----- | -------- | ------- |
| designed for low latency  | no    | yes      | yes     |
| designed for throughput   | yes   | no       | no      |
| packet framing            | no    | yes      | yes     |
| packet ordering           | yes   | no       | yes     |
| packet splitting          | yes   | no       | yes     |
| packet retry              | yes   | no       | yes     |
| packet reduplication      | yes   | no       | yes     |
| hole punch through        | no    | yes      | yes     |
| connection handling       | yes   | no       | yes     |
| congestion control        | yes   | no       | yes     |


# Echo Server/Client example

## server.nim

```nim
import netty

# listen for a connection on localhost port 1999
var server = newReactor("127.0.0.1", 1999)
echo "Listenting for UDP on 127.0.0.1:1999"
# main loop
while true:
  # must call tick to both read and write
  server.tick()
  # usually there are no new messages, but if there are
  for msg in server.messages:
    # print message data
    echo "GOT MESSAGE: ", msg.data
    # echo message back to the client
    server.send(msg.conn, "you said:" & msg.data)
```

## client.nim

```nim
import netty

# create connection
var client = newReactor()
# connect to server
var c2s = client.connect("127.0.0.1", 1999)
# send message on the connection
client.send(c2s, "hi")
# main loop
while true:
  # must call tick to both read and write
  client.tick()
  # usually there are no new messages, but if there are
  for msg in client.messages:
    # print message data
    echo "GOT MESSAGE: ", msg.data
```

# Chat Server/Client example

## chatserver.nim

```nim
import netty

var server = newReactor("127.0.0.1", 2001)
echo "Listenting for UDP on 127.0.0.1:2001"
while true:
  server.tick()
  for connection in server.newConnections:
    echo "[new] ", connection.address
  for connection in server.deadConnections:
    echo "[dead] ", connection.address
  for msg in server.messages:
    echo "[msg]", msg.data
    # send msg data to all connections
    for connection in server.connections:
      server.send(connection, msg.data)
```

## chatclient.nim

```nim
import netty

var client = newReactor()
var connection = client.connect("127.0.0.1", 2001)

# get persons name
echo "what is your name?"
var name = readLine(stdin)
echo "note: press enter to see if people sent you things"

while true:
  client.tick()
  for msg in client.messages:
    echo msg.data

  # wait for user to type a line
  let line = readLine(stdin)
  if line.len > 0:
    client.send(connection, name & ":" & line)
```
