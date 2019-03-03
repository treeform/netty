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
    echo "[msg]", packet.data
    # send packet data to all connections
    for connection in server.connections:
      connection.send(packet.data)