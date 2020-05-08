import netty, strformat

var server = newReactor("127.0.0.1", 2002)
var client = newReactor("127.0.0.1", 2003)

var c2s = client.connect(server.address)

var l: int

for i in 0 ..< 1000:
  block:
    var buffer = "large:"
    for i in 0 ..< 1000:
      buffer.add "<data>"

    client.send(c2s, buffer)

    for i in 0 ..< 10:
      client.tick()
      server.tick()

      var a, b, c: Message
      for msg in server.messages:
        a = msg
        b = msg
        b = a
        c = a
        l += (a.data.len + b.data.len + c.data.len)

  block:
    var dataToSend = newSeq[string]()
    for i in 0 ..< 1000:
      dataToSend.add &"data #{i}, its cool!"

    for d in dataToSend:
      client.send(c2s, d)
    for i in 0 ..< 1000:
      client.tick()
      server.tick()

      var a, b, c: Message
      for msg in server.messages:
        var index = dataToSend.find(msg.data)
        # make sure message is there
        assert index != -1
        dataToSend.delete(index)
        a = msg
        b = msg
        b = a
        c = a
        l += (a.data.len + b.data.len + c.data.len)
      if dataToSend.len == 0: break
    # make sure all messages made it
    assert dataToSend.len == 0, &"datatoSend.len: {datatoSend.len}"

echo l
