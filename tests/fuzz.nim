## Packet fuzzer for netty's UDP receive path.
##
## Sends adversarial and random datagrams at a reactor and requires that
## `tick` never raises. Catchable errors and silent drops are fine; process
## death or uncaught Defects are not.
##
## Run: nim r tests/fuzz.nim
## Replay: nim r tests/fuzz.nim --replay <hex>

import
  std/[os, random, strutils],
  flatty/binny

include netty

var nextPortNumber = 5000
proc nextPort(): int =
  result = nextPortNumber
  inc nextPortNumber

proc toHex(s: string): string =
  for c in s:
    result.add toHex(c.ord, 2)

proc fromHex(h: string): string =
  var i = 0
  while i + 1 < h.len:
    result.add chr(parseHexInt(h[i .. i + 1]))
    i += 2

proc partPacket(
  sequenceNum, connId: uint32,
  partNum, numParts: uint16,
  data: string
): string =
  result.addUint32(PartMagic)
  result.addUint32(sequenceNum)
  result.addUint32(connId)
  result.addUint16(partNum)
  result.addUint16(numParts)
  result.addStr(data)

proc corners(): seq[string] =
  ## Deterministic packets most likely to trip the parser.
  result.add ""
  for n in 1 .. 20:
    result.add newString(n)
  var d = ""
  d.addUint32(DisconnectMagic)
  result.add d
  d.addUint32(0)
  result.add d
  result.add partPacket(0, 1, 0, 0, "x")
  result.add partPacket(0, 1, 1, 1, "x")
  result.add partPacket(0, 1, 0, 1, "")
  result.add partPacket(0, 1, 0, 1, "ok")
  result.add partPacket(
    high(uint32), high(uint32), high(uint16), high(uint16), "z"
  )
  var ack = ""
  ack.addUint32(AckMagic)
  ack.addUint32(0)
  ack.addUint32(1)
  ack.addUint16(0)
  ack.addUint16(1)
  result.add ack
  var punch = ""
  punch.addUint32(PunchMagic)
  result.add punch
  result.add partPacket(0, 9, 0, 100, "tiny")

proc randPacket(r: var Rand): string =
  case r.rand(0 .. 7)
  of 0:
    result = newString(r.rand(0 .. 64))
    for i in 0 ..< result.len:
      result[i] = char(r.rand(255))
  of 1:
    result = partPacket(
      r.rand(uint32),
      r.rand(uint32),
      r.rand(uint16),
      r.rand(uint16),
      newString(r.rand(0 .. 200))
    )
  of 2:
    result.addUint32(DisconnectMagic)
    if r.rand(1.0) < 0.7:
      result.addUint32(r.rand(uint32))
  of 3:
    result.addUint32(AckMagic)
    result.addUint32(r.rand(uint32))
    result.addUint32(r.rand(uint32))
    result.addUint16(r.rand(uint16))
    result.addUint16(r.rand(uint16))
  of 4:
    result.addUint32(PunchMagic)
    result.add newString(r.rand(0 .. 32))
  of 5:
    result = partPacket(0, r.rand(uint32), 0, 1, "open")
  of 6:
    result = partPacket(
      r.rand(0u32 .. 20u32),
      r.rand(uint32),
      0,
      r.rand(1u16 .. 8u16),
      "frag"
    )
  else:
    result = newString(r.rand(0 .. 8))

proc feed(server, attacker: Reactor, packet: string) =
  attacker.rawSend(server.address, packet)
  attacker.tick()
  server.tick()

proc fuzzAll(packets: seq[string]) =
  var server = newReactor("127.0.0.1", nextPort())
  server.maxConnections = 32
  server.maxRecvParts = 64
  var attacker = newReactor()
  for packet in packets:
    try:
      feed(server, attacker, packet)
    except Exception as e:
      echo "CRASH on packet ", toHex(packet)
      echo "  ", e.name, ": ", e.msg
      quit(1)

proc main() =
  if paramCount() >= 2 and paramStr(1) == "--replay":
    fuzzAll(@[fromHex(paramStr(2))])
    echo "replay ok"
    return

  echo "=== corner packets ==="
  fuzzAll(corners())

  let total =
    if paramCount() >= 1:
      parseInt(paramStr(1))
    else:
      2000

  echo "=== random packets x ", total, " ==="
  var
    r = initRand(0x11E77)
    packets = newSeq[string](total)
  for i in 0 ..< total:
    packets[i] = randPacket(r)
  fuzzAll(packets)

  echo "=== fuzz summary: ok ==="

main()
