import hashes, nativesockets, net, netty/hexprint, random, sequtils, streams,
    strformat, times

export Port, hexprint

const
  partMagic = uint32(0xFFDDFF33)
  ackMagic = uint32(0xFF33FF11)
  disconnectMagic = uint32(0xFF77FF99)
  punchMagic = uint32(0x00000000)
  headerSize = 4 + 4 + 4 + 2 + 2
  ackTime = 0.250     ## Seconds to wait before sending the packet again.
  connTimeout = 10.00 ## Seconds to wait until timing-out the connection.
  defaultMaxUdpPacket = 508 - headerSize
  defaultMaxInFlight = 25_000

type
  Address* = object
    ## A host/port of the client.
    host*: string
    port*: Port

  DebugConfig* = object
    tickTime*: float64 ## Override the time processed by calls to tick.
    dropRate*: float32 ## [0, 1] % simulated drop rate.
    maxUdpPacket*: int ## Max size of each outgoing UDP packet in bytes.

  Reactor* = ref object
    ## Main networking system that can open or receive connections.
    id*: uint32
    address*: Address
    socket: Socket
    time: float64
    maxInFlight*: int                 ## Max bytes in-flight on the socket.
    debug*: DebugConfig

    connections*: seq[Connection]
    newConnections*: seq[Connection]  ## New connections since last tick.
    deadConnections*: seq[Connection] ## Dead connections since last tick.
    messages*: seq[Message]

  ConnectionStats* = object
    inFlight*: int     ## How many bytes are currently in flight.
    saturated*: bool   ## If this conn cannot send until it receives acks.
    avgLatency*: float32 ## Avg conn latency.
    maxLatency*: float32 ## Max conn latency.
    throughput*: int  ## Avg conn throughput in bytes.

    latencySamples: seq[float32]
    latencySamplesAt: int
    throughputSamples: seq[(float64, int32)]
    throughputSamplesAt: int

  Connection* = ref object
    id*: uint32
    reactorId*: uint32
    address*: Address
    stats*: ConnectionStats

    sendParts: seq[Part]    ## Parts queued to be sent.
    recvParts: seq[Part]    ## Parts that have been read from the socket.
    sendSequenceNum: uint32 ## Next message sequence num when sending.
    recvSequenceNum: uint32 ## Next message sequence number to receive.

  Part = ref object
    ## Part of a Message.
    sequenceNum: uint32 ## The message sequence number.
    connId: uint32      ## The id of the connection this belongs to.
    numParts: uint16    ## How many parts there are to the Message this part of.
    partNum: uint16     ## The part of the Message this is.
    data: string

    # Sending
    queuedTime: float64
    sentTime: float64
    acked: bool
    ackedTime: float64

  Message* = object
    conn*: Connection
    sequenceNum*: uint32
    data*: string

var
  r = initRand((epochTime() * 1_000_000).int)

func initAddress*(host: string, port: int): Address =
  result.host = host
  result.port = Port(port)

func `$`*(address: Address): string =
  ## Address to string.
  &"{address.host}:{address.port.int}"

func `$`*(conn: Connection): string =
  ## Connection to string.
  &"Connection({conn.address}, id:{conn.id}, reactor: {conn.reactorId})"

func `$`*(part: Part): string =
  ## Part to string.
  &"Part({part.sequenceNum}:{part.partNum}/{part.numParts} ACK:{part.acked})"

func `$`*(msg: Message): string =
  ## Message to string.
  &"Message(from: {msg.conn.address} #{msg.sequenceNum}, size:{msg.data.len})"

func hash*(x: Address): Hash =
  ## Computes a hash for the address.
  hash((x.host, x.port))

proc genId(): uint32 {.inline.} =
  r.rand(high(uint32).int).uint32

proc newConnection(reactor: Reactor, address: Address): Connection =
  result = Connection()
  result.id = genId()
  result.reactorId = reactor.id
  result.address = address

  result.stats.latencySamples = newSeq[float32](1024)
  result.stats.throughputSamples = newSeq[(float64, int32)](1024)

func getConn(reactor: Reactor, connId: uint32): Connection =
  for conn in reactor.connections:
    if conn.id == connId:
      return conn

proc read(reactor: Reactor, conn: Connection): (bool, Message) =
  if conn.recvParts.len == 0:
    return

  let
    sequenceNum = conn.recvSequenceNum
    numParts = conn.recvParts[0].numParts

  if conn.recvParts.len < numParts.int:
    return

  var good = true
  for i in 0.uint16 ..< numParts:
    if not(conn.recvParts[i].sequenceNum == sequenceNum and
      conn.recvParts[i].numParts == numParts and
      conn.recvParts[i].partNum == i):
      good = false
      break

  if not good:
    return

  result[0] = true
  result[1].conn = conn
  result[1].sequenceNum = sequenceNum

  for i in 0.uint16 ..< numParts:
    result[1].data.add(conn.recvParts[i].data)

  inc conn.recvSequenceNum
  conn.recvParts.delete(0, numParts - 1)

proc divideAndSend(reactor: Reactor, conn: Connection, data: string) =
  ## Divides a packet into parts and gets it ready to be sent.
  assert data.len != 0

  var
    parts: seq[Part]
    partNum: uint16
    at: int

  while at < data.len:
    var part = Part()
    part.sequenceNum = conn.sendSequenceNum
    part.connId = conn.id
    part.partNum = partNum
    inc partNum

    let maxAt = min(at + reactor.debug.maxUdpPacket, data.len)
    part.data = data[at ..< maxAt]
    at = maxAt
    parts.add(part)

  assert parts.len < high(uint16).int

  for part in parts.mitems:
    part.numParts = parts.len.uint16
    part.queuedTime = reactor.time

  conn.sendParts.add(parts)
  inc conn.sendSequenceNum

proc rawSend(reactor: Reactor, address: Address, packet: string) =
  ## Low level send to a socket.
  if reactor.debug.dropRate != 0:
    if rand(1.0) <= reactor.debug.dropRate:
      return
  try:
    reactor.socket.sendTo(address.host, address.port, packet)
  except:
    return

proc sendNeededParts(reactor: Reactor) =
  var i = 0
  while i < reactor.connections.len:
    let conn = reactor.connections[i]
    var
      inFlight: int
      saturated: bool
    for part in conn.sendParts:
      if inFlight + part.data.len > reactor.maxInFlight:
        saturated = true
        break

      if part.acked or (part.sentTime + ackTime > reactor.time):
        continue

      if part.queuedTime + connTimeout <= reactor.time:
        reactor.deadConnections.add(conn)
        reactor.connections.delete(i)
        dec(i)
        break

      inFlight += part.data.len

      part.sentTime = reactor.time

      var stream = newStringStream()
      stream.write(partMagic)
      stream.write(part.sequenceNum)
      stream.write(part.connId)
      stream.write(part.partNum)
      stream.write(part.numParts)
      stream.write(part.data)
      stream.setPosition(0)
      let packet = stream.readAll()
      reactor.rawSend(conn.address, packet)

    conn.stats.inFlight = inFlight
    conn.stats.saturated = saturated
    inc i

proc sendSpecial(
  reactor: Reactor, conn: Connection, part: Part, magic: uint32
) =
  assert reactor.id == conn.reactorId
  assert conn.id == part.connId

  var stream = newStringStream()
  stream.write(magic)
  stream.write(part.sequenceNum)
  stream.write(part.connId)
  stream.write(part.partNum)
  stream.write(part.numParts)
  stream.setPosition(0)
  let packet = stream.readAll()
  reactor.rawSend(conn.address, packet)

proc deleteAckedParts(reactor: Reactor) =
  for conn in reactor.connections:
    var
      pos, bytesAcked: int
    for part in conn.sendParts:
      if not part.acked:
        break
      inc pos
      bytesAcked += part.data.len
    if pos > 0:
      var
        minTime = float64.high
        maxTime: float64
      for i in 0 ..< pos:
        let part = conn.sendParts[i]
        minTime = min(minTime, part.queuedTime)
        maxTime = max(maxTime, part.ackedTime)

      if conn.stats.latencySamplesAt >= conn.stats.throughputSamples.len:
        conn.stats.latencySamplesAt = 0
      conn.stats.latencySamples[conn.stats.latencySamplesAt] =
        (maxTime - minTime).float32
      inc conn.stats.latencySamplesAt

      conn.sendParts.delete(0, pos - 1)

    if conn.stats.throughputSamplesAt >= conn.stats.throughputSamples.len:
      conn.stats.throughputSamplesAt = 0
    conn.stats.throughputSamples[conn.stats.throughputSamplesAt] =
      (reactor.time, bytesAcked.int32)
    inc conn.stats.throughputSamplesAt

proc readParts(reactor: Reactor) =
  var
    buf = newStringOfcap(reactor.debug.maxUdpPacket)
    host: string
    port: Port

  for _ in 0 ..< 1000:
    var byteLen: int
    try:
      byteLen = reactor.socket.recvFrom(
        buf, reactor.debug.maxUdpPacket + headerSize, host, port
      )
    except:
      break

    let address = initAddress(host, port.int)

    var
      stream = newStringStream(buf)
      magic = stream.readUint32()

    if magic == disconnectMagic:
      let connId = stream.readUint32()
      var conn = reactor.getConn(connId)
      if conn != nil:
        reactor.deadConnections.add(conn)
        reactor.connections.delete(reactor.connections.find(conn))
      continue

    if magic == punchMagic:
      #echo &"Received punch through from {address}"
      continue

    if byteLen < headerSize:
      # A valid packet will have at least the header.
      echo &"Received packet of invalid size {reactor.address}"
      break

    var part = Part()
    part.sequenceNum = stream.readUint32()
    part.connId = stream.readUint32()
    part.partNum = stream.readUint16()
    part.numParts = stream.readUint16()
    part.data = buf[headerSize ..^ 1]

    var conn = reactor.getConn(part.connId)
    if conn == nil:
      if magic == partMagic and part.sequenceNum == 0 and part.partNum == 0:
        conn = newConnection(reactor, address)
        conn.id = part.connId
        reactor.connections.add(conn)
        reactor.newConnections.add(conn)
      else:
        continue

    if reactor.debug.dropRate > 0.0:
      if rand(1.0) <= reactor.debug.dropRate:
        continue

    if magic == partMagic:
      part.acked = true
      part.ackedTime = reactor.time
      reactor.sendSpecial(conn, part, ackMagic)

      if part.sequenceNum < conn.recvSequenceNum:
        continue

      var pos: int
      for p in conn.recvParts:
        if p.sequenceNum > part.sequenceNum:
          break

        if p.sequenceNum == part.sequenceNum:
          if p.partNum > part.partNum:
            break

          if p.partNum == part.partNum:
            # Duplicate
            pos = -1
            assert p.data == part.data
            break

        inc pos

      if pos != -1: # If not a duplicate
        conn.recvParts.insert(part, pos)

    elif magic == ackMagic:
      for p in conn.sendParts:
        if p.sequenceNum == part.sequenceNum and
          p.numParts == part.numParts and
          p.partNum == part.partNum:
          if not p.acked:
            p.acked = true
            p.ackedTime = reactor.time

    else:
      # Unrecognized packet
      discard

proc combineParts(reactor: Reactor) =
  for conn in reactor.connections.mitems:
    while true:
      let (gotMsg, msg) = reactor.read(conn)
      if gotMsg:
        reactor.messages.add(msg)
      else:
        break

proc updateStats(reactor: Reactor) =
  for conn in reactor.connections.mitems:
    block latency:
      var
        total: float32
        maximum: float32
        divisor: int
      for sample in conn.stats.latencySamples:
        if sample > 0:
          total += sample
          inc(divisor)
          maximum = max(sample, maximum)

      conn.stats.avgLatency = if divisor > 0: total / divisor.float32 else: 0
      conn.stats.maxLatency = maximum

    block throughput:
      var
        totalBytes: int
        earliest = high(float64)
        latest = 0.float64
      for (time, bytes) in conn.stats.throughputSamples:
        if time == 0:
          continue
        totalBytes += bytes
        earliest = min(earliest, time)
        latest = max(latest, time)

      let delta = latest - earliest
      if delta > 0:
        conn.stats.throughput = (totalBytes.float64 / delta).int
      else:
        conn.stats.throughput = totalBytes

proc tick*(reactor: Reactor) =
  if reactor.debug.tickTime != 0:
    reactor.time = reactor.debug.tickTime
  else:
    reactor.time = epochTime()

  reactor.newConnections.setLen(0)
  reactor.deadConnections.setLen(0)
  reactor.messages.setLen(0)

  reactor.sendNeededParts()
  reactor.readParts()
  reactor.combineParts()
  reactor.deleteAckedParts()
  reactor.updateStats()

proc connect*(reactor: Reactor, address: Address): Connection =
  ## Starts a new connection to an address.
  result = newConnection(reactor, address)
  result.reactorId = reactor.id
  reactor.connections.add(result)
  reactor.newConnections.add(result)

proc connect*(reactor: Reactor, host: string, port: int): Connection =
  ## Starts a new connection to host and port.
  reactor.connect(initAddress(host, port))

proc send*(reactor: Reactor, conn: Connection, data: string) =
  assert reactor.id == conn.reactorId
  reactor.divideAndSend(conn, data)

proc sendMagic(
  reactor: Reactor,
  address: Address,
  magic: uint32,
  connId: uint32,
  extra = ""
) =
  var stream = newStringStream()
  stream.write(magic)
  stream.write(connId)
  stream.write(extra)
  stream.setPosition(0)
  let packet = stream.readAll()
  reactor.socket.sendTo(address.host, address.port, packet)

proc disconnect*(reactor: Reactor, conn: Connection) =
  ## Disconnects the connection.
  assert reactor.id == conn.reactorId
  for i in 0 .. 10:
    reactor.sendMagic(conn.address, disconnectMagic, conn.id)
  reactor.deadConnections.add(conn)
  reactor.connections.delete(reactor.connections.find(conn))

proc punchThrough*(reactor: Reactor, address: Address) =
  ## Tries to punch through to host/port.
  for i in 0 .. 10:
    reactor.sendMagic(address, punchMagic, 0, "punch through")

proc punchThrough*(reactor: Reactor, host: string, port: int) =
  ## Tries to punch through to host/port.
  reactor.punchThrough(initAddress(host, port))

proc newReactor*(address: Address): Reactor =
  ## Creates a new reactor with address.
  result = Reactor()
  result.id = genId()
  result.maxInFlight = defaultMaxInFlight

  result.address = address
  result.socket = newSocket(
    Domain.AF_INET,
    SockType.SOCK_DGRAM,
    Protocol.IPPROTO_UDP,
    buffered = false
  )
  result.socket.getFd().setBlocking(false)
  result.socket.bindAddr(result.address.port, result.address.host)

  let (_, portLocal) = result.socket.getLocalAddr()
  result.address.port = portLocal

  result.debug.maxUdpPacket = defaultMaxUdpPacket

  result.tick()

proc newReactor*(host: string, port: int): Reactor =
  ## Creates a new reactor with host and port.
  newReactor(initAddress(host, port))

proc newReactor*(): Reactor =
  ## Creates a new reactor with system chosen address.
  newReactor("", 0)
