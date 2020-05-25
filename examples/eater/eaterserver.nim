import netty, os

var server = newReactor("127.0.0.1", 2001)
echo "Listenting for UDP on ", server.address
while true:
  server.tick()
  for connection in server.newConnections:
    echo "[new] ", connection.address
  for connection in server.deadConnections:
    echo "[dead] ", connection.address
  for msg in server.messages:
    # send packet data to all connections
    for connection in server.connections:
      server.send(connection, msg.data)
  sleep(1)
