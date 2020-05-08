## Convert any nim objects, numbers, strings, refs to and from binary format.

import snappy, streams, tables

proc compress(s: string): string =
  cast[string](snappy.compress(cast[seq[byte]](s)))

proc uncompress(s: string): string =
  cast[string](snappy.uncompress(cast[seq[byte]](s)))

# Forward declarations.
proc toFlatty[T](s: Stream, x: seq[T])
proc fromFlatty[T](s: Stream, x: var seq[T])
proc toFlatty(s: Stream, x: object)
proc fromFlatty(s: Stream, x: var object)
proc toFlatty(s: Stream, x: ref object)
proc fromFlatty(s: Stream, x: var ref object)
proc toFlatty[T: distinct](s: Stream, x: T)
proc fromFlatty[T: distinct](s: Stream, x: var T)
proc toFlatty[K, V](s: Stream, x: Table[K, V])
proc fromFlatty[K, V](s: Stream, x: var Table[K, V])
proc toFlatty[N, T](s: Stream, x: array[N, T])
proc fromFlatty[N, T](s: Stream, x: var array[N, T])
proc toFlatty*[T](x: T): string
proc fromFlatty*[T](data: string, x: typedesc[T]): T
proc toFlatty[T: tuple](s: Stream, x: T)
proc fromFlatty[T: tuple](s: Stream, x: var T)

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
  s.write(x.len.uint32)
  s.write(x)

proc fromFlatty(s: Stream, x: var string) =
  let len = s.readUint32()
  x = s.readStr(len.int)

# Seq
proc toFlatty[T](s: Stream, x: seq[T]) =
  s.write(x.len.uint32)
  for e in x:
    s.toFlatty(e)

proc fromFlatty[T](s: Stream, x: var seq[T]) =
  let len = s.readUint32()
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

# Tables
proc toFlatty[K, V](s: Stream, x: Table[K, V]) =
  s.write(x.len.uint32)
  for k, v in x:
    s.toFlatty(k)
    s.toFlatty(v)

proc fromFlatty[K, V](s: Stream, x: var Table[K, V]) =
  let len = s.readUint32()
  for i in 0 ..< len:
    var
      k: K
      v: V
    s.fromFlatty(k)
    s.fromFlatty(v)
    x[k] = v

# Arrays
proc toFlatty[N, T](s: Stream, x: array[N, T]) =
  for e in x:
    s.toFlatty(e)

proc fromFlatty[N, T](s: Stream, x: var array[N, T]) =
  for i in 0 ..< x.len:
    s.fromFlatty(x[i])

# Tuples
proc toFlatty[T: tuple](s: Stream, x: T) =
  for _, e in x.fieldPairs:
    s.toFlatty(e)

proc fromFlatty[T: tuple](s: Stream, x: var T) =
  for _, e in x.fieldPairs:
    s.fromFlatty(e)

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
