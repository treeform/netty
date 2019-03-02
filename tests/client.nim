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