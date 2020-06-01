# Like StringStream but without the Stream and side effects.

func readUInt8*(s: string, i: int): uint8 =
  s[i].uint8

func addUInt8*(s: var string, i: uint8) =
  s.add i.char

func readUInt16*(s: string, i: int): uint16 =
  s[i+0].uint16 shl 0 +
  s[i+1].uint16 shl 8

func addUInt16*(s: var string, v: uint16) =
  s.add ((v and 0x00FF) shr 0).char
  s.add ((v and 0xFF00) shr 8).char

func readUInt32*(s: string, i: int): uint32 =
  s[i+0].uint32 shl 0 +
  s[i+1].uint32 shl 8 +
  s[i+2].uint32 shl 16 +
  s[i+3].uint32 shl 24

func addUInt32*(s: var string, v: uint32) =
  s.add ((v and 0x000000FF) shr 0).char
  s.add ((v and 0x0000FF00) shr 8).char
  s.add ((v and 0x00FF0000) shr 16).char
  s.add ((v and 0xFF000000.uint32) shr 24).char

func readUInt64*(s: string, i: int): uint64 =
  s[i+0].uint64 shl 0 +
  s[i+1].uint64 shl 8 +
  s[i+2].uint64 shl 16 +
  s[i+3].uint64 shl 24 +
  s[i+4].uint64 shl 32 +
  s[i+5].uint64 shl 40 +
  s[i+6].uint64 shl 48 +
  s[i+7].uint64 shl 56

func addUInt64*(s: var string, v: uint64) =
  s.add ((v and (0xFF.uint64 shl 0)) shr 0).char
  s.add ((v and (0xFF.uint64 shl 8)) shr 8).char
  s.add ((v and (0xFF.uint64 shl 16)) shr 16).char
  s.add ((v and (0xFF.uint64 shl 24)) shr 24).char
  s.add ((v and (0xFF.uint64 shl 32)) shr 32).char
  s.add ((v and (0xFF.uint64 shl 40)) shr 40).char
  s.add ((v and (0xFF.uint64 shl 48)) shr 48).char
  s.add ((v and (0xFF.uint64 shl 56)) shr 56).char

func readInt8*(s: string, i: int): int8 = cast[int8](s.readUInt8(i))
func addInt8*(s: var string, i: int8) = s.addUInt8(cast[uint8](i))
func readInt16*(s: string, i: int): int16 = cast[int16](s.readUInt16(i))
func addInt16*(s: var string, i: int16) = s.addUInt16(cast[uint16](i))
func readInt32*(s: string, i: int): int32 = cast[int32](s.readUInt32(i))
func addInt32*(s: var string, i: int32) = s.addUInt32(cast[uint32](i))
func readInt64*(s: string, i: int): int64 = cast[int64](s.readUInt64(i))
func addInt64*(s: var string, i: int64) = s.addUInt64(cast[uint64](i))

func readFloat32*(s: string, i: int): float32 = cast[float32](s.readUInt32(i))
func addFloat32*(s: var string, f: float32) = s.addUInt32(cast[uint32](f))
func readFloat64*(s: string, i: int): float64 = cast[float64](s.readUInt64(i))
func addFloat64*(s: var string, f: float64) = s.addUInt64(cast[uint64](f))

func addStr*(s: var string, str: string) =
  s.add(str)
func readStr*(s: string, i: int, l: int): string =
  s[i ..< min(s.len, i + l)]

# func maybeSwap(u: uint16, swap: bool): uint16 =
#   if swap:
#     ((u and 0xFF) shl 8) or ((u and 0xFF00) shr 8)
#   else:
#     u

when isMainModule:
  import streams, netty/hexPrint

  block:
    var s = ""
    s.addUInt8(0x12.uint8)
    echo hexPrint(s)
    assert s.readUint8(0) == 0x12.uint8

    var ss = newStringStream()
    ss.write(0x12.uint8)
    ss.setPosition(0)
    assert ss.readAll() == s

  block:
    var s = ""
    s.addUInt16(0x1234.uint16)
    echo hexPrint(s)
    assert s.readUint16(0) == 0x1234.uint16

    var ss = newStringStream()
    ss.write(0x1234.uint16)
    ss.setPosition(0)
    assert ss.readAll() == s

  block:
    var s = ""
    s.addUInt32(0x12345678.uint32)
    echo hexPrint(s)
    assert s.readUint32(0) == 0x12345678.uint32

    var ss = newStringStream()
    ss.write(0x12345678.uint32)
    ss.setPosition(0)
    assert ss.readAll() == s

  block:
    var s = ""
    s.addUInt64(0x12345678AABBCC.uint64)
    echo hexPrint(s)
    assert s.readUint64(0) == 0x12345678AABBCC.uint64

    var ss = newStringStream()
    ss.write(0x12345678AABBCC.uint64)
    ss.setPosition(0)
    assert ss.readAll() == s

  block:
    var s = ""
    s.addInt8(-12.int8)
    assert s.readInt8(0) == -12.int8

  block:
    var s = ""
    s.addInt16(-1234.int16)
    assert s.readInt16(0) == -1234.int16

  block:
    var s = ""
    s.addInt32(-12345678.int32)
    assert s.readInt32(0) == -12345678.int32

  block:
    var s = ""
    s.addInt64(-123456781234.int64)
    assert s.readInt64(0) == -123456781234.int64

  block:
    var s = ""
    s.addFloat32(-3.14.float32)
    assert s.readFloat32(0) == -3.14.float32

  block:
    var s = ""
    s.addFloat64(-3.14.float64)
    assert s.readFloat64(0) == -3.14.float64
