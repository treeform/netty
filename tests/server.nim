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
