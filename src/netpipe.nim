import hashes, nativesockets, net, tables, times, streams, random, sequtils
#import netpipe/osrandom

randomize()

export Port

const
  partMagic = uint32(0xFFDDFF33)
  ackMagic = uint32(0xFF33FF11)
  punchMagic = uint32(0x00000000)

const headerSize = 4 + 4 + 4 + 2 + 2
var maxUdpPacket = 508 - headerSize


const ackTime = 0.250 # time to wait before sending the packet again
const connTimeout = 10.00 # how long to wait until time out the connection

type
  Address* = object
    ## A host/port of the client
    host*: string
    port*: Port

  Reactor* = ref object
    ## Main networking system that can make or recive connections
    address*: Address
    socket*: Socket
    simDropRate: float
    maxInFlight: int
    time: float64

    connecting*: seq[Connection]
    connections*: seq[Connection]
    newConnections*: seq[Connection]
    deadConnections*: seq[Connection]
    packets*: seq[Packet]

  Connection* = ref object
    ## Single connection from this reactor to another reactor
    reactor*: Reactor
    connected*: bool
    address*: Address
    rid*: uint32
    sentParts: seq[Part]
    recvParts: seq[Part]
    sendSequenceNum: int
    recvSequenceNum: int

  Part* = ref object
    ## Part of a packet
    sequenceNum*: uint32 # which packet seq is it
    rid: uint32 # random number that is this connect
    numParts*: uint16 # number of parts
    partNum*: uint16 # which par is it

    # sending
    firstTime: float64
    lastTime: float64
    numSent: int
    acked: bool
    ackedTime: float64

    # reciving
    produced: bool
    data*: string

  Packet* = ref object
    ## Full packet
    connection*: Connection
    sequenceNum*: uint32 # which packet seq is it
    secret*: uint32
    data*: string


proc newAddress*(host: string, port: int): Address =
  result.host = host
  result.port = Port(port)


proc `$`*(address: Address): string =
  ## Address to string
  $address.host & ":" & $(address.port.int)


proc `$`*(conn: Connection): string =
  ## Connection to string
  "Connection(" & $conn.address & ")"


proc `$`*(part: Part): string =
  ## Part to string
  "Part(" & $part.sequenceNum & ":" & $part.partNum & "/" & $part.numParts & " ACK:" & $part.acked & ")"


proc `$`*(packet: Packet): string =
  ## Part to string
  "Packet(from: " & $packet.connection.address & " #" & $packet.sequenceNum & ", size:" & $packet.data.len & ")"


proc hash*(x: Address): Hash =
  ## Computes a Hash from and address
  var h: Hash = 0
  h = h !& hash(x.host)
  h = h !& hash(x.port)
  result = !$h


proc removeBack[T](s: var seq[T], what: T) =
  ## Remove an element in a seq, by copying the last element
  ## over its pos and shrinking seq by 1
  if s.len == 0: return
  for i in 0..<s.len:
    if s[i] == what:
      s[i] = s[^1]
      s.setLen(s.len - 1)
      return


proc tick*(reactor: Reactor)


proc newReactor*(address: Address): Reactor =
  ## Creates a new reactor with address
  var reactor = Reactor()
  reactor.address = address
  reactor.socket = newSocket(Domain.AF_INET, SockType.SOCK_DGRAM, Protocol.IPPROTO_UDP, false)
  reactor.socket.getFd().setBlocking(false)
  reactor.socket.bindAddr(reactor.address.port, reactor.address.host)
  let (hostLocal, portLocal) = reactor.socket.getLocalAddr()
  reactor.address.port = portLocal
  reactor.connections = @[]
  reactor.simDropRate = 0.0 #
  reactor.maxInFlight = 25000 # don't have more then 250K in flight on the socket
  reactor.tick()
  return reactor


proc newReactor*(host: string, port: int): Reactor =
  ## Creates a new reactor with host and port
  newReactor(newAddress(host, port))


proc newReactor*(): Reactor =
  ## Creates a new reactor with system chosen address
  newReactor("", 0)


proc newConnection*(socket: Reactor, address: Address): Connection =
  var conn = Connection()
  conn.reactor = socket
  conn.address = address
  conn.rid = uint32 rand(int uint32.high)
  conn.sentParts = @[]
  conn.recvParts = @[]
  return conn


proc getConn(reactor: Reactor, address: Address): Connection =
  for conn in reactor.connections.mitems:
    if conn.address == address:
      return conn


proc getConn(reactor: Reactor, address: Address, rid: uint32): Connection =
  for conn in reactor.connections.mitems:
    if conn.address == address and conn.rid == rid:
      return conn


proc read*(conn: Connection): Packet =
  if conn.recvParts.len == 0:
    return nil

  let numParts = int conn.recvParts[0].numParts
  let sequenceNum = int conn.recvSequenceNum
  if conn.recvParts.len < numParts:
    return nil

  # verify step
  var good = true
  for i in 0..<numParts:
    if not (conn.recvParts[i].sequenceNum == uint32(sequenceNum) and
        conn.recvParts[i].numParts == uint16(numParts) and
        conn.recvParts[i].partNum == uint16(i)):
      good = false
      break

  if not good:
    return nil

  # all good create packet
  var packet = Packet()
  packet.connection = conn
  packet.sequenceNum = uint32 sequenceNum
  packet.data = ""
  for i in 0..<numParts:
    packet.data.add conn.recvParts[i].data

  inc conn.recvSequenceNum
  conn.recvParts.delete(0, numParts-1)

  return packet


proc divideAndSend(reactor: Reactor, conn: Connection, data: string) =
  ## Divides a packet into parts and gets it ready to be sent
  var parts = newSeq[Part]()

  assert data.len != 0

  var partNum: uint16 = 0
  var at = 0
  while at < data.len:
    var part = Part()
    part.sequenceNum = uint32 conn.sendSequenceNum
    part.partNum = partNum
    let maxAt = min(at + maxUdpPacket, data.len)
    part.data = data[at ..< maxAt]
    inc partNum
    at = maxAt
    parts.add(part)
  for part in parts.mitems:
    part.numParts = uint16 parts.len
    part.rid = conn.rid
    part.firstTime = reactor.time
    part.lastTime = reactor.time
    conn.sentParts.add(part)
  inc conn.sendSequenceNum


proc rawSend(reactor: Reactor, address: Address, data: string) =
  ## Low level send to a socket
  if reactor.simDropRate != 0:
    # drop % of packets
    if rand(1.0) <= reactor.simDropRate:
      return
  try:
    reactor.socket.sendTo(address.host, address.port, data)
  except:
    return


proc sendNeededParts(reactor: Reactor) =
  var i = 0
  while i < reactor.connections.len:
    var conn = reactor.connections[i]
    inc i
    if not conn.connected: continue

    var inFlight = 0
    for part in conn.sentParts.mitems:

      # make sure we only keep max data in flight
      inFlight += part.data.len
      if inFlight > reactor.maxInFlight:
        break

      # looks for packet that need to be sent or re-sent
      if not part.acked and (part.numSent == 0 or part.lastTime + ackTime < reactor.time):

        if part.numSent > 0 and part.firstTime + connTimeout < reactor.time:
          # we have tried to resent packet but it did not take
          conn.connected = false
          reactor.deadConnections.add(conn)
          reactor.connections.removeBack(conn)
          break

        var packetData = newStringStream()
        packetData.write(partMagic)
        packetData.write(part.sequenceNum)
        packetData.write(part.rid)
        packetData.write(part.partNum)
        packetData.write(part.numParts)
        packetData.write(part.data)
        packetData.setPosition(0)
        var data = packetData.readAll()
        inc part.numSent
        part.lastTime = reactor.time
        reactor.rawSend(conn.address, data)


proc sendSpecail(reactor: Reactor, conn: Connection, part: Part, magic: uint32) =
  var packetData = newStringStream()
  packetData.write(magic)
  packetData.write(part.sequenceNum)
  packetData.write(part.rid)
  packetData.write(part.partNum)
  packetData.write(part.numParts)
  packetData.setPosition(0)
  var data = packetData.readAll()
  reactor.rawSend(conn.address, data)


proc deleteAckedParts(reactor: Reactor) =
  for conn in reactor.connections:
    ## look for packets that have been acked already
    var number = 0
    for part in conn.sentParts:
      if not part.acked:
        break
      inc number
    if number > 0:
      conn.sentParts.delete(0, number-1)


proc readParts(reactor: Reactor) =
  var data = newStringOfCap(maxUdpPacket)
  var host: string
  var port: Port
  var success: int

  # read 1000 parts
  for i in 0..<1000:
    try:
      success = reactor.socket.recvFrom(data, maxUdpPacket + headerSize, host, port)
    except:
      break
    if success < headerSize:
      echo "failed to recv ", $reactor.address
      break

    var part = Part()
    var address = Address()
    address.host = host
    address.port = port

    var stream = newStringStream(data)
    var magic = stream.readUint32()
    if magic == punchMagic:
      #echo "got punched from", host, port
      continue

    part.sequenceNum = stream.readUint32()
    part.rid = stream.readUint32()
    part.partNum = stream.readUint16()
    part.numParts = stream.readUint16()
    part.data = data[headerSize..^1]

    var conn = reactor.getConn(address, part.rid)
    if conn == nil:
      if magic == partMagic and part.sequenceNum == 0 and part.partNum == 0:
        conn = newConnection(reactor, address)
        conn.rid = part.rid
        reactor.connections.add(conn)
        reactor.newConnections.add(conn)
        conn.connected = true
      else:
        continue

    if magic == partMagic:
      # insert packets in the correct order
      part.acked = true
      part.ackedTime = reactor.time
      reactor.sendSpecail(conn, part, ackMagic)

      var pos = 0
      if part.sequenceNum >= uint32(conn.recvSequenceNum):
        for p in conn.recvParts:
          if p.sequenceNum > part.sequenceNum:
            break
          elif p.sequenceNum == part.sequenceNum:
            if p.partNum > part.partNum:
              break
            elif p.partNum == part.partNum:
              # duplicate
              pos = -1
              assert p.data == part.data
              break
          inc pos
        if pos != -1:
          conn.recvParts.insert(part, pos)

    elif magic == ackMagic:
      for p in conn.sentParts:
        if p.sequenceNum == part.sequenceNum and
            p.numParts == part.numParts and
            p.partNum == part.partNum:
          # found a part that was being acked
          if not p.acked:
            p.acked = true
            p.ackedTime = reactor.time

    else:
      discard
      #echo "got junk"


proc combinePackets(reactor: Reactor) =
  for conn in reactor.connections:
    while true:
      var packet = conn.read()
      if packet != nil:
        reactor.packets.add(packet)
      else:
        break


proc tick*(reactor: Reactor) =
  ## send and recives packets
  reactor.time = epochTime()
  reactor.newConnections.setLen(0)
  reactor.deadConnections.setLen(0)
  reactor.packets.setLen(0)
  reactor.sendNeededParts()
  reactor.deleteAckedParts()
  reactor.readParts()
  reactor.combinePackets()


proc connect*(reactor: Reactor, address: Address): Connection =
  ## Starts a new connectino to an address
  var conn = newConnection(reactor, address)
  conn.connected = true
  reactor.connections.add(conn)
  reactor.newConnections.add(conn)
  return conn


proc connect*(reactor: Reactor, host: string, port: int): Connection =
  ## Starts a new connectino to an address
  reactor.connect(newAddress(host, port))


proc send*(conn: Connection, data: string) =
  if conn.connected == true:
    conn.reactor.divideAndSend(conn, data)


proc disconnect*(conn: Connection) =
  conn.connected = false
  # TOOD Send disc packet


proc punchThrough*(reactor: Reactor, address: Address) =
  ## Tries to punch through to host/port
  for i in 0..10:
    reactor.socket.sendTo(address.host, address.port, char(0) & char(0) & char(0) & char(0) & "punch through")


proc punchThrough*(reactor: Reactor, host: string, port: int) =
  ## Tries to punch through to host/port
  reactor.punchThrough(newAddress(host, port))
