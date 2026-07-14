import
  flatty/binny, hashes, nativesockets, net, netty/timeseries, random,
  sequtils, std/monotimes, strformat, times, os

export Port, timeseries

const
  PartMagic = 0xFFDDFF33.uint32
  AckMagic = 0xFF33FF11.uint32
  DisconnectMagic = 0xFF77FF99.uint32
  PunchMagic = 0x00000000.uint32
  HeaderSize = 4 + 4 + 4 + 2 + 2
  AckTime = 0.250     ## Seconds to wait before sending the packet again.
  ConnTimeout = 10.00 ## Seconds to wait until timing-out the connection.
  DefaultMaxUdpPacket = 508 - HeaderSize
  DefaultMaxInFlight = 250_000
  DefaultMaxConnections = 1000
  DefaultMaxRecvParts = 1000

type
  NettyError* = object of CatchableError

  Address* = object
    ## A host/port of the client.
    host*: string
    port*: Port

  DebugConfig* = object
    tickTime*: float64    ## Override the time processed by calls to tick.
    dropRate*: float32    ## [0, 1] % simulated drop rate.
    readLatency*: float32 ## Min simulated read latency in seconds.
    sendLatency*: float32 ## Min simulated send latency in seconds.

  Reactor* = ref object
    ## Main networking system that can open or receive connections.
    r: Rand
    id*: uint32
    address*: Address
    socket: Socket
    time: float64
    maxInFlight*: int     ## Max bytes in-flight on the socket.
    maxConnections*: int  ## Max accepted or outbound connections.
    maxRecvParts*: int    ## Max buffered receive parts per connection.
    maxUdpPacket*: int    ## Max payload bytes per outgoing UDP packet.
    debug*: DebugConfig

    connections*: seq[Connection]
    newConnections*: seq[Connection]  ## New connections since last tick.
    deadConnections*: seq[Connection] ## Dead connections since last tick.
    messages*: seq[Message]

  ConnectionStats* = object
    inFlight*: int   ## How many bytes are currently in flight.
    inQueue*: int    ## How many bytes are currently waiting to be sent.
    saturated*: bool ## If this conn cannot send until it receives acks.
    latencyTs*: TimeSeries
    throughputTs*: TimedSamples

  Connection* = ref object
    id*: uint32
    reactorId*: uint32
    address*: Address
    stats*: ConnectionStats
    lastActiveTime*: float64

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

func seqLess(a, b: uint32): bool {.inline.} =
  ## True if a is before b in RFC1982 serial number space.
  cast[int32](a - b) < 0

func genId(reactor: Reactor): uint32 {.inline.} =
  reactor.r.rand(0u32 .. uint32.high).uint32

func currentTime(reactor: Reactor): float64 {.inline.} =
  ## Prefer debug tick override when set so send() matches tick time.
  if reactor.debug.tickTime != 0:
    reactor.debug.tickTime
  else:
    reactor.time

func newConnection(reactor: Reactor, address: Address): Connection =
  result = Connection()
  result.id = reactor.genId()
  result.reactorId = reactor.id
  result.address = address

  result.stats.latencyTs = newTimeSeries()
  result.stats.throughputTs = newTimedSamples()

func getConn(reactor: Reactor, connId: uint32): Connection =
  for conn in reactor.connections:
    if conn.id == connId:
      return conn

func updateSendStats(reactor: Reactor) =
  ## Recount in-flight bytes after sends or acks.
  for conn in reactor.connections:
    var
      inFlight: int
      saturated: bool
    for part in conn.sendParts:
      if part.acked:
        continue
      if inFlight + part.data.len > reactor.maxInFlight:
        saturated = true
        break
      if part.sentTime != 0:
        inFlight += part.data.len
    conn.stats.inFlight = inFlight
    conn.stats.saturated = saturated

func read(reactor: Reactor, conn: Connection): (bool, Message) =
  if conn.recvParts.len == 0:
    return

  let
    sequenceNum = conn.recvSequenceNum
    numParts = conn.recvParts[0].numParts

  if numParts == 0 or conn.recvParts.len < numParts.int:
    return

  var good = true
  for i in 0.uint16 ..< numParts:
    if conn.recvParts[i].ackedTime + reactor.debug.readLatency >
      reactor.time:
      good = false
      break

    if not(
      conn.recvParts[i].sequenceNum == sequenceNum and
      conn.recvParts[i].numParts == numParts and
      conn.recvParts[i].partNum == i
    ):
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
  conn.recvParts.delete(0 .. numParts.int - 1)

func divideAndSend(reactor: Reactor, conn: Connection, data: string) =
  ## Divides a packet into parts and gets it ready to be sent.
  if data.len == 0:
    return
  conn.stats.inQueue += data.len

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

    let maxAt = min(at + reactor.maxUdpPacket, data.len)
    part.data = data[at ..< maxAt]
    at = maxAt
    parts.add(part)

  if parts.len > high(uint16).int:
    raise newException(NettyError, "message has too many parts")

  for part in parts.mitems:
    part.numParts = parts.len.uint16
    part.queuedTime = reactor.currentTime()

  conn.sendParts.add(parts)
  inc conn.sendSequenceNum

proc rawSend(reactor: Reactor, address: Address, packet: string) =
  ## Low level send to a socket.
  if reactor.socket == nil:
    return
  if reactor.debug.dropRate != 0:
    if reactor.r.rand(1.0) <= reactor.debug.dropRate:
      return
  try:
    reactor.socket.sendTo(address.host, address.port, packet)
  except OSError:
    return

proc sendNeededParts(reactor: Reactor) =
  for conn in reactor.connections:
    for part in conn.sendParts:
      if part.acked:
        continue

      if conn.stats.inFlight + part.data.len > reactor.maxInFlight:
        conn.stats.saturated = true
        break

      # Waiting for ACK / RTO; still counts as in-flight.
      if part.sentTime != 0 and
        part.sentTime + AckTime > reactor.time:
        conn.stats.inFlight += part.data.len
        continue

      if part.queuedTime + reactor.debug.sendLatency > reactor.time:
        continue

      let firstSend = part.sentTime == 0
      conn.stats.inFlight += part.data.len
      if firstSend:
        conn.stats.inQueue -= part.data.len

      part.sentTime = reactor.time

      var packet = newStringOfCap(HeaderSize + part.data.len)
      packet.addUint32(PartMagic)
      packet.addUint32(part.sequenceNum)
      packet.addUint32(part.connId)
      packet.addUint16(part.partNum)
      packet.addUint16(part.numParts)
      packet.addStr(part.data)

      reactor.rawSend(conn.address, packet)

  reactor.updateSendStats()

proc sendSpecial(
  reactor: Reactor, conn: Connection, part: Part, magic: uint32
) =
  assert reactor.id == conn.reactorId
  assert conn.id == part.connId

  var packet = newStringOfCap(HeaderSize)
  packet.addUint32(magic)
  packet.addUint32(part.sequenceNum)
  packet.addUint32(part.connId)
  packet.addUint16(part.partNum)
  packet.addUint16(part.numParts)

  reactor.rawSend(conn.address, packet)

func deleteAckedParts(reactor: Reactor) =
  for conn in reactor.connections:
    var pos, bytesAcked: int
    for part in conn.sendParts:
      if not part.acked:
        break
      inc pos
      bytesAcked += part.data.len

    if pos > 0:
      var minTime = float64.high
      for i in 0 ..< pos:
        let part = conn.sendParts[i]
        minTime = min(minTime, part.queuedTime)

      conn.stats.latencyTs.add((reactor.time - minTime).float32)
      conn.sendParts.delete(0 .. pos - 1)

    conn.stats.throughputTs.add(reactor.time, bytesAcked.float64)

proc readParts(reactor: Reactor) =
  var
    buf = newStringOfCap(reactor.maxUdpPacket + HeaderSize)
    host: string
    port: Port

  for _ in 0 ..< 1000:
    var byteLen: int
    try:
      byteLen = reactor.socket.recvFrom(
        buf, reactor.maxUdpPacket + HeaderSize, host, port
      )
    except OSError:
      when defined(nettyMagicSleep) and not defined(nettyBench):
        sleep(1)
      break

    if byteLen < 4:
      # Need a magic word at minimum.
      continue

    let address = initAddress(host, port.int)
    let magic = buf.readUint32(0)

    if magic == DisconnectMagic:
      if byteLen < 8:
        continue
      let connId = buf.readUint32(4)
      var conn = reactor.getConn(connId)
      if conn != nil:
        reactor.deadConnections.add(conn)
        reactor.connections.delete(reactor.connections.find(conn))
      continue

    if magic == PunchMagic:
      continue

    if byteLen < HeaderSize:
      continue

    if magic != PartMagic and magic != AckMagic:
      continue

    var part = Part()
    part.sequenceNum = buf.readUint32(4)
    part.connId = buf.readUint32(8)
    part.partNum = buf.readUint16(12)
    part.numParts = buf.readUint16(14)
    part.data = buf.readStr(HeaderSize, byteLen - HeaderSize)

    if part.numParts == 0 or part.partNum >= part.numParts:
      continue

    var conn = reactor.getConn(part.connId)
    if conn == nil:
      if magic == PartMagic and
        part.sequenceNum == 0 and
        part.partNum == 0:
        if reactor.connections.len >= reactor.maxConnections:
          continue
        conn = newConnection(reactor, address)
        conn.id = part.connId
        reactor.connections.add(conn)
        reactor.newConnections.add(conn)
      else:
        continue

    if reactor.debug.dropRate > 0.0:
      if reactor.r.rand(1.0) <= reactor.debug.dropRate:
        continue

    conn.lastActiveTime = reactor.time

    if magic == PartMagic:
      if seqLess(part.sequenceNum, conn.recvSequenceNum):
        # Already delivered; ACK so the sender stops retrying.
        part.acked = true
        part.ackedTime = reactor.time
        reactor.sendSpecial(conn, part, AckMagic)
        continue

      var pos: int
      var duplicate: bool
      for p in conn.recvParts:
        if seqLess(part.sequenceNum, p.sequenceNum):
          break
        if p.sequenceNum == part.sequenceNum:
          if p.partNum > part.partNum:
            break
          if p.partNum == part.partNum:
            duplicate = true
            break
        inc pos

      if duplicate:
        # Never assert on network bytes; ACK the part we already have.
        part.acked = true
        part.ackedTime = reactor.time
        reactor.sendSpecial(conn, part, AckMagic)
        continue

      if conn.recvParts.len >= reactor.maxRecvParts:
        # Receive window full; skip ACK so the sender retries later.
        continue

      part.acked = true
      part.ackedTime = reactor.time
      reactor.sendSpecial(conn, part, AckMagic)
      conn.recvParts.insert(part, pos)

    elif magic == AckMagic:
      for p in conn.sendParts:
        if p.sequenceNum == part.sequenceNum and
          p.numParts == part.numParts and
          p.partNum == part.partNum:
          if not p.acked:
            p.acked = true
            p.ackedTime = reactor.time

func combineParts(reactor: Reactor) =
  for conn in reactor.connections.mitems:
    while true:
      let (gotMsg, msg) = reactor.read(conn)
      if gotMsg:
        reactor.messages.add(msg)
      else:
        break

func timeoutConnections(reactor: Reactor) =
  ## See if any connections have timed out.
  var i = 0
  while i < reactor.connections.len:
    let conn = reactor.connections[i]
    if conn.lastActiveTime + ConnTimeout <= reactor.time:
      reactor.deadConnections.add(conn)
      reactor.connections.delete(i)
      continue
    inc i

proc tick*(reactor: Reactor) =
  if reactor.socket == nil:
    return

  if reactor.debug.tickTime != 0:
    reactor.time = reactor.debug.tickTime
  else:
    reactor.time = epochTime()

  reactor.newConnections.setLen(0)
  reactor.deadConnections.setLen(0)
  reactor.messages.setLen(0)

  for conn in reactor.connections:
    conn.stats.inFlight = 0
    conn.stats.saturated = false

  reactor.sendNeededParts()
  reactor.readParts()
  reactor.combineParts()
  reactor.deleteAckedParts()
  reactor.updateSendStats()
  reactor.timeoutConnections()

func connect*(reactor: Reactor, address: Address): Connection =
  ## Starts a new connection to an address.
  if reactor.connections.len >= reactor.maxConnections:
    raise newException(NettyError, "max connections reached")
  result = newConnection(reactor, address)
  result.reactorId = reactor.id
  result.lastActiveTime = reactor.time
  reactor.connections.add(result)
  reactor.newConnections.add(result)

func connect*(reactor: Reactor, host: string, port: int): Connection =
  ## Starts a new connection to host and port.
  reactor.connect(initAddress(host, port))

func send*(reactor: Reactor, conn: Connection, data: string) =
  assert reactor.id == conn.reactorId
  reactor.divideAndSend(conn, data)

proc sendMagic(
  reactor: Reactor,
  address: Address,
  magic: uint32,
  connId: uint32,
  extra = ""
) =
  if reactor.socket == nil:
    return
  var packet = newStringOfCap(4 + 4 + extra.len)
  packet.addUint32(magic)
  packet.addUint32(connId)
  packet.addStr(extra)

  try:
    reactor.socket.sendTo(address.host, address.port, packet)
  except OSError:
    return

proc disconnect*(reactor: Reactor, conn: Connection) =
  ## Disconnects the connection.
  assert reactor.id == conn.reactorId
  for i in 0 .. 10:
    reactor.sendMagic(conn.address, DisconnectMagic, conn.id)
  reactor.deadConnections.add(conn)
  let index = reactor.connections.find(conn)
  if index != -1:
    reactor.connections.delete(index)

proc close*(reactor: Reactor) =
  ## Closes the UDP socket and clears local connection state.
  if reactor.socket != nil:
    let conns = reactor.connections
    for conn in conns:
      for i in 0 .. 10:
        reactor.sendMagic(conn.address, DisconnectMagic, conn.id)
    reactor.socket.close()
    reactor.socket = nil
  reactor.connections.setLen(0)
  reactor.newConnections.setLen(0)
  reactor.deadConnections.setLen(0)
  reactor.messages.setLen(0)

proc punchThrough*(reactor: Reactor, address: Address) =
  ## Tries to punch through to host/port.
  for i in 0 .. 10:
    reactor.sendMagic(address, PunchMagic, 0, "punch through")

proc punchThrough*(reactor: Reactor, host: string, port: int) =
  ## Tries to punch through to host/port.
  reactor.punchThrough(initAddress(host, port))

proc newReactor*(address: Address): Reactor =
  ## Creates a new reactor with address.
  result = Reactor()
  result.r = initRand(getMonoTime().ticks)
  result.id = result.genId()
  result.maxInFlight = DefaultMaxInFlight
  result.maxConnections = DefaultMaxConnections
  result.maxRecvParts = DefaultMaxRecvParts

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

  result.maxUdpPacket = DefaultMaxUdpPacket

  result.tick()

proc newReactor*(host: string, port: int): Reactor =
  ## Creates a new reactor with host and port.
  newReactor(initAddress(host, port))

proc newReactor*(): Reactor =
  ## Creates a new reactor with system chosen address.
  newReactor("", 0)
