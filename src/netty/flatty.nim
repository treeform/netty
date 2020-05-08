## Convert any nim objects, numbers, strings, refs to and from binary format.

import snappy, streams

proc compress(s: string): string =
  cast[string](snappy.compress(cast[seq[byte]](s)))

proc uncompress(s: string): string =
  cast[string](snappy.uncompress(cast[seq[byte]](s)))

# Booleans
proc toFlatty(s: Stream, x: bool) =
  s.write(x.uint8)

proc fromFlatty(s: Stream, x: var bool) =
  x = s.readUint8().bool

# Numbers
proc toFlatty(s: Stream, x: SomeNumber) =
  s.write(x)

proc fromFlatty(s: Stream, x: var SomeNumber) =
  s.read(x)

# Enums
proc toFlatty(s: Stream, x: enum) =
  s.write(x)

proc fromFlatty[T: enum](s: Stream, x: var T) =
  s.read(x)

# Strings
proc toFlatty(s: Stream, x: string) =
  s.write(x.len)
  s.write(x)

proc fromFlatty(s: Stream, x: var string) =
  let len = s.readInt64()
  x = s.readStr(len.int)

# Seq
proc toFlatty[T](s: Stream, x: seq[T]) =
  s.write(x.len.int64)
  for e in x:
    s.toFlatty(e)

proc fromFlatty[T](s: Stream, x: var seq[T]) =
  let len = s.readUint64()
  x.setLen(len)
  for i in 0 ..< len:
    s.fromFlatty(x[i])

# Objects
proc toFlatty(s: Stream, x: object) =
  for _, e in x.fieldPairs:
    s.toFlatty(e)

proc fromFlatty(s: Stream, x: var object) =
  for _, e in x.fieldPairs:
    s.fromFlatty(e)

proc toFlatty(s: Stream, x: ref object) =
  let isNil = x == nil
  s.toFlatty(isNil)
  if not isNil:
    for _, e in x[].fieldPairs:
      s.toFlatty(e)

proc fromFlatty(s: Stream, x: var ref object) =
  var isNil: bool
  s.fromFlatty(isNil)
  if not isNil:
    new(x)
    for _, e in x[].fieldPairs:
      s.fromFlatty(e)

# Distinct
proc toFlatty[T: distinct](s: Stream, x: T) =
  s.write(x)

proc fromFlatty[T: distinct](s: Stream, x: var T) =
  s.read(x)

proc toFlatty*[T](x: T): string =
  ## Takes structures and turns them into binary string.
  var s = newStringStream()
  s.toFlatty(x)
  s.setPosition(0)
  return compress(s.readAll())

proc fromFlatty*[T](data: string, x: typedesc[T]): T =
  ## Takes binary string and turn into structures.
  var s = newStringStream(uncompress(data))
  s.fromFlatty(result)
