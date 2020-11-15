import netty, os

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
  sleep(1)
