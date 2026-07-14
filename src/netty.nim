import
  flatty/binny, hashes, nativesockets, net, netty/timeseries, random,
  std/[deques, monotimes, tables], strformat, times, os

export Port, timeseries

const
  PartMagic = 0xFFDDFF33.uint32
  AckMagic = 0xFF33FF11.uint32
  AckBundleMagic = 0xFF33FF22.uint32
  DisconnectMagic = 0xFF77FF99.uint32
  PunchMagic = 0x00000000.uint32
  HeaderSize = 4 + 4 + 4 + 2 + 2
  AckEntrySize = 4 + 4 + 2 + 2
  AckTime = 0.250     ## Seconds to wait before sending the packet again.
  ConnTimeout = 10.00 ## Seconds to wait until timing-out the connection.
  DefaultMaxUdpPacket = 508 - HeaderSize
  DefaultMaxInFlight = 250_000
  DefaultMaxConnections = 10_000
  DefaultMaxRecvParts = 1000
  MaxPartPool = 4096
  MaxUdpRecv = 2048 ## Socket read size; larger than part payload so ACK bundles fit.
  MaxPartsPerTick = 100_000 ## Max datagrams drained per tick.

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

  RecvSlot = object
    data: string
    ackedTime: float64
    present: bool

  RecvMessage = object
    numParts: uint16
    got: uint16
    slots: seq[RecvSlot]

  AckEntry = object
    sequenceNum: uint32
    connId: uint32
    partNum: uint16
    numParts: uint16

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
    connectionById: Table[uint32, Connection]
    partPool: seq[Part]
    outBuf: string
    pendingAcks: seq[AckEntry]
    pendingAckAddress: Address
    pendingAckSet: bool

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

    sendParts: Deque[Part] ## Parts queued to be sent.
    recvPending: Table[uint32, RecvMessage]
    recvPartCount: int ## Buffered receive parts (for the window cap).
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

func resetPart(part: Part) =
  part.sequenceNum = 0
  part.connId = 0
  part.numParts = 0
  part.partNum = 0
  part.data = ""
  part.queuedTime = 0
  part.sentTime = 0
  part.acked = false
  part.ackedTime = 0

func acquirePart(reactor: Reactor): Part =
  if reactor.partPool.len > 0:
    result = reactor.partPool.pop()
    resetPart(result)
  else:
    result = Part()

func releasePart(reactor: Reactor, part: Part) =
  if reactor.partPool.len < MaxPartPool:
    resetPart(part)
    reactor.partPool.add(part)

func newConnection(reactor: Reactor, address: Address): Connection =
  result = Connection()
  result.id = reactor.genId()
  result.reactorId = reactor.id
  result.address = address
  result.sendParts = initDeque[Part]()
  when defined(nettyBench):
    # Keep per-conn stats rings tiny so large-scale benches fit in RAM.
    result.stats.latencyTs = newTimeSeries(16)
    result.stats.throughputTs = newTimedSamples(16)
  else:
    result.stats.latencyTs = newTimeSeries()
    result.stats.throughputTs = newTimedSamples()

func getConn(reactor: Reactor, connId: uint32): Connection =
  if connId in reactor.connectionById:
    result = reactor.connectionById[connId]

func addConnection(reactor: Reactor, conn: Connection) =
  reactor.connections.add(conn)
  reactor.connectionById[conn.id] = conn

func removeConnection(reactor: Reactor, conn: Connection) =
  reactor.connectionById.del(conn.id)
  for i in 0 ..< reactor.connections.len:
    if reactor.connections[i] == conn:
      reactor.connections.del(i)
      break

func clearRecv(conn: Connection) =
  conn.recvPending.clear()
  conn.recvPartCount = 0

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
  if conn.recvSequenceNum notin conn.recvPending:
    return

  let pending = conn.recvPending[conn.recvSequenceNum]
  let
    sequenceNum = conn.recvSequenceNum
    numParts = pending.numParts

  if numParts == 0 or pending.got < numParts:
    return

  var good = true
  for i in 0.uint16 ..< numParts:
    let slot = pending.slots[i]
    if not slot.present:
      good = false
      break
    if slot.ackedTime + reactor.debug.readLatency > reactor.time:
      good = false
      break

  if not good:
    return

  var total: int
  for i in 0.uint16 ..< numParts:
    total += pending.slots[i].data.len

  result[0] = true
  result[1].conn = conn
  result[1].sequenceNum = sequenceNum
  result[1].data = newStringOfCap(total)
  for i in 0.uint16 ..< numParts:
    result[1].data.add(pending.slots[i].data)

  conn.recvPartCount -= numParts.int
  conn.recvPending.del(sequenceNum)
  inc conn.recvSequenceNum

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
    var part = reactor.acquirePart()
    part.sequenceNum = conn.sendSequenceNum
    part.connId = conn.id
    part.partNum = partNum
    inc partNum

    let maxAt = min(at + reactor.maxUdpPacket, data.len)
    part.data = data[at ..< maxAt]
    at = maxAt
    parts.add(part)

  if parts.len > high(uint16).int:
    for part in parts:
      reactor.releasePart(part)
    raise newException(NettyError, "message has too many parts")

  for part in parts.mitems:
    part.numParts = parts.len.uint16
    part.queuedTime = reactor.currentTime()
    conn.sendParts.addLast(part)

  inc conn.sendSequenceNum

proc rawSend(reactor: Reactor, address: Address, packet: string): bool {.discardable.} =
  ## Low level send to a socket. False means try again next tick.
  if reactor.socket == nil:
    return false
  if reactor.debug.dropRate != 0:
    if reactor.r.rand(1.0) <= reactor.debug.dropRate:
      # Count as sent so simulated loss still uses RTO.
      return true
  try:
    reactor.socket.sendTo(address.host, address.port, packet)
    return true
  except OSError:
    return false

proc sendNeededParts(reactor: Reactor) =
  for conn in reactor.connections:
    for i in 0 ..< conn.sendParts.len:
      let part = conn.sendParts[i]
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

      reactor.outBuf.setLen(0)
      reactor.outBuf.addUint32(PartMagic)
      reactor.outBuf.addUint32(part.sequenceNum)
      reactor.outBuf.addUint32(part.connId)
      reactor.outBuf.addUint16(part.partNum)
      reactor.outBuf.addUint16(part.numParts)
      reactor.outBuf.addStr(part.data)

      if not reactor.rawSend(conn.address, reactor.outBuf):
        # OS send buffer full; retry next tick without burning RTO.
        conn.stats.saturated = true
        break

      if firstSend:
        conn.stats.inQueue -= part.data.len
      part.sentTime = reactor.time
      conn.stats.inFlight += part.data.len

  reactor.updateSendStats()

proc flushAcks(reactor: Reactor) =
  ## Sends queued ACKs, bundling when several share a destination.
  if not reactor.pendingAckSet or reactor.pendingAcks.len == 0:
    reactor.pendingAcks.setLen(0)
    reactor.pendingAckSet = false
    return

  let address = reactor.pendingAckAddress
  if reactor.pendingAcks.len == 1:
    let ack = reactor.pendingAcks[0]
    reactor.outBuf.setLen(0)
    reactor.outBuf.addUint32(AckMagic)
    reactor.outBuf.addUint32(ack.sequenceNum)
    reactor.outBuf.addUint32(ack.connId)
    reactor.outBuf.addUint16(ack.partNum)
    reactor.outBuf.addUint16(ack.numParts)
    discard reactor.rawSend(address, reactor.outBuf)
  else:
    # Keep bundles within a typical UDP datagram, independent of
    # maxUdpPacket (which only sizes message payloads).
    let maxEntries = max(1, (MaxUdpRecv - 6) div AckEntrySize)
    var at = 0
    while at < reactor.pendingAcks.len:
      let n = min(maxEntries, reactor.pendingAcks.len - at)
      reactor.outBuf.setLen(0)
      reactor.outBuf.addUint32(AckBundleMagic)
      reactor.outBuf.addUint16(n.uint16)
      for i in 0 ..< n:
        let ack = reactor.pendingAcks[at + i]
        reactor.outBuf.addUint32(ack.sequenceNum)
        reactor.outBuf.addUint32(ack.connId)
        reactor.outBuf.addUint16(ack.partNum)
        reactor.outBuf.addUint16(ack.numParts)
      discard reactor.rawSend(address, reactor.outBuf)
      at += n

  reactor.pendingAcks.setLen(0)
  reactor.pendingAckSet = false

proc queueAck(
  reactor: Reactor,
  address: Address,
  sequenceNum, connId: uint32,
  partNum, numParts: uint16
) =
  ## Queues an ACK, flushing when the destination changes.
  if reactor.pendingAckSet and (
    reactor.pendingAckAddress.host != address.host or
    reactor.pendingAckAddress.port != address.port
  ):
    reactor.flushAcks()

  if not reactor.pendingAckSet:
    reactor.pendingAckAddress = address
    reactor.pendingAckSet = true

  reactor.pendingAcks.add(AckEntry(
    sequenceNum: sequenceNum,
    connId: connId,
    partNum: partNum,
    numParts: numParts
  ))

func markAcked(
  conn: Connection,
  sequenceNum: uint32,
  partNum, numParts: uint16
) =
  for i in 0 ..< conn.sendParts.len:
    let p = conn.sendParts[i]
    if p.sequenceNum == sequenceNum and
      p.numParts == numParts and
      p.partNum == partNum:
      if not p.acked:
        p.acked = true
      return

func deleteAckedParts(reactor: Reactor) =
  for conn in reactor.connections:
    var bytesAcked: int
    var minTime = float64.high
    var popped: int
    while conn.sendParts.len > 0 and conn.sendParts.peekFirst().acked:
      let part = conn.sendParts.popFirst()
      bytesAcked += part.data.len
      minTime = min(minTime, part.queuedTime)
      inc popped
      reactor.releasePart(part)

    if popped > 0:
      conn.stats.latencyTs.add((reactor.time - minTime).float32)

    conn.stats.throughputTs.add(reactor.time, bytesAcked.float64)

proc readParts(reactor: Reactor) =
  var
    buf = newStringOfCap(MaxUdpRecv)
    host: string
    port: Port

  for _ in 0 ..< MaxPartsPerTick:
    var byteLen: int
    try:
      byteLen = reactor.socket.recvFrom(
        buf, MaxUdpRecv, host, port
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
        reactor.removeConnection(conn)
      continue

    if magic == PunchMagic:
      continue

    if magic == AckBundleMagic:
      if byteLen < 6:
        continue
      let count = buf.readUint16(4).int
      if count < 0 or byteLen < 6 + count * AckEntrySize:
        continue
      if reactor.debug.dropRate > 0.0:
        if reactor.r.rand(1.0) <= reactor.debug.dropRate:
          continue
      var off = 6
      for _ in 0 ..< count:
        let
          sequenceNum = buf.readUint32(off)
          connId = buf.readUint32(off + 4)
          partNum = buf.readUint16(off + 8)
          numParts = buf.readUint16(off + 10)
        off += AckEntrySize
        var conn = reactor.getConn(connId)
        if conn != nil:
          conn.lastActiveTime = reactor.time
          conn.markAcked(sequenceNum, partNum, numParts)
      continue

    if byteLen < HeaderSize:
      continue

    if magic != PartMagic and magic != AckMagic:
      continue

    let
      sequenceNum = buf.readUint32(4)
      connId = buf.readUint32(8)
      partNum = buf.readUint16(12)
      numParts = buf.readUint16(14)

    if numParts == 0 or partNum >= numParts:
      continue

    var conn = reactor.getConn(connId)
    if conn == nil:
      if magic == PartMagic and sequenceNum == 0 and partNum == 0:
        if reactor.connections.len >= reactor.maxConnections:
          continue
        conn = newConnection(reactor, address)
        conn.id = connId
        reactor.addConnection(conn)
        reactor.newConnections.add(conn)
      else:
        continue

    if reactor.debug.dropRate > 0.0:
      if reactor.r.rand(1.0) <= reactor.debug.dropRate:
        continue

    conn.lastActiveTime = reactor.time

    if magic == PartMagic:
      if seqLess(sequenceNum, conn.recvSequenceNum):
        reactor.queueAck(
          conn.address, sequenceNum, connId, partNum, numParts
        )
        continue

      if sequenceNum in conn.recvPending:
        let pending = conn.recvPending[sequenceNum]
        if partNum.int < pending.slots.len and
          pending.slots[partNum].present:
          reactor.queueAck(
            conn.address, sequenceNum, connId, partNum, numParts
          )
          continue
      elif conn.recvPartCount >= reactor.maxRecvParts:
        # Receive window full; skip ACK so the sender retries later.
        continue

      if sequenceNum notin conn.recvPending:
        var fresh = RecvMessage(numParts: numParts)
        fresh.slots.setLen(numParts.int)
        conn.recvPending[sequenceNum] = fresh

      var pending = conn.recvPending[sequenceNum]
      if pending.numParts != numParts:
        # Conflicting claim; ignore.
        continue
      if partNum.int >= pending.slots.len:
        continue
      if pending.slots[partNum].present:
        reactor.queueAck(
          conn.address, sequenceNum, connId, partNum, numParts
        )
        continue

      pending.slots[partNum].data =
        buf.readStr(HeaderSize, byteLen - HeaderSize)
      pending.slots[partNum].ackedTime = reactor.time
      pending.slots[partNum].present = true
      inc pending.got
      conn.recvPending[sequenceNum] = pending
      inc conn.recvPartCount

      reactor.queueAck(
        conn.address, sequenceNum, connId, partNum, numParts
      )

    elif magic == AckMagic:
      conn.markAcked(sequenceNum, partNum, numParts)

  reactor.flushAcks()

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
      reactor.connectionById.del(conn.id)
      reactor.connections.del(i)
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
  reactor.addConnection(result)
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
  reactor.removeConnection(conn)

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
  reactor.connectionById.clear()
  reactor.newConnections.setLen(0)
  reactor.deadConnections.setLen(0)
  reactor.messages.setLen(0)
  reactor.partPool.setLen(0)

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
