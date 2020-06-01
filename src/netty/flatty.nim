## Convert any nim objects, numbers, strings, refs to and from binary format.

import snappy, binny, tables, typetraits

# Forward declarations.
func toFlatty[T](s: var string, x: seq[T])
func toFlatty(s: var string, x: object)
func toFlatty(s: var string, x: ref object)
func toFlatty[T: distinct](s: var string, x: T)
func toFlatty[K, V](s: var string, x: Table[K, V])
func toFlatty[N, T](s: var string, x: array[N, T])
func toFlatty[T: tuple](s: var string, x: T)
func fromFlatty[T](s: string, i: var int, x: var seq[T])
func fromFlatty(s: string, i: var int, x: var object)
func fromFlatty(s: string, i: var int, x: var ref object)
func fromFlatty[T: distinct](s: string, i: var int, x: var T)
func fromFlatty[K, V](s: string, i: var int, x: var Table[K, V])
func fromFlatty[N, T](s: string, i: var int, x: var array[N, T])
func fromFlatty[T: tuple](s: string, i: var int, x: var T)
func fromFlatty*[T](s: string, x: typedesc[T]): T

# Booleans
func toFlatty(s: var string, x: bool) =
  s.addUInt8(x.uint8)

func fromFlatty(s: string, i: var int, x: var bool) =
  x = s.readUInt8(i).bool
  i += 1

# Numbers
func toFlatty(s: var string, x: uint8) = s.addUInt8(x)
func toFlatty(s: var string, x: int8) = s.addInt8(x)
func toFlatty(s: var string, x: uint16) = s.addUInt16(x)
func toFlatty(s: var string, x: int16) = s.addInt16(x)
func toFlatty(s: var string, x: uint32) = s.addUInt32(x)
func toFlatty(s: var string, x: int32) = s.addInt32(x)
func toFlatty(s: var string, x: uint64) = s.addUInt64(x)
func toFlatty(s: var string, x: int64) = s.addInt64(x)
func toFlatty(s: var string, x: float32) = s.addFloat32(x)
func toFlatty(s: var string, x: float64) = s.addFloat64(x)

func fromFlatty(s: string, i: var int, x: var uint8) =
  x = s.readUInt8(i)
  i += 1

func fromFlatty(s: string, i: var int, x: var int8) =
  x = s.readInt8(i)
  i += 1

func fromFlatty(s: string, i: var int, x: var uint16) =
  x = s.readUInt16(i)
  i += 2

func fromFlatty(s: string, i: var int, x: var int16) =
  x = s.readInt16(i)
  i += 2

func fromFlatty(s: string, i: var int, x: var uint32) =
  x = s.readUInt32(i)
  i += 4

func fromFlatty(s: string, i: var int, x: var int32) =
  x = s.readInt32(i)
  i += 4

func fromFlatty(s: string, i: var int, x: var uint64) =
  x = s.readUInt64(i)
  i += 8

func fromFlatty(s: string, i: var int, x: var int64) =
  x = s.readInt64(i)
  i += 8

func fromFlatty(s: string, i: var int, x: var int) =
  x = s.readInt64(i).int
  i += 8

func fromFlatty(s: string, i: var int, x: var float32) =
  x = s.readFloat32(i)
  i += 4

func fromFlatty(s: string, i: var int, x: var float64) =
  x = s.readFloat64(i)
  i += 8


# Enums
func toFlatty[T: enum](s: var string, x: T) =
  s.addInt64(x.int)

func fromFlatty[T: enum](s: string, i: var int, x: var T) =
  x = cast[T](s.readInt64(i))
  i += 8

# Strings
func toFlatty(s: var string, x: string) =
  s.addInt64(x.len)
  s.add(x)

func fromFlatty(s: string, i: var int, x: var string) =
  let len = s.readInt64(i).int
  i += 8
  x = s[i ..< i + len]
  i += len

# Seq
func toFlatty[T](s: var string, x: seq[T]) =
  s.addInt64(x.len.int64)
  for e in x:
    s.toFlatty(e)

func fromFlatty[T](s: string, i: var int, x: var seq[T]) =
  let len = s.readInt64(i)
  i += 8
  x.setLen(len)
  for j in 0 ..< len:
    s.fromFlatty(i, x[j])

# Objects
func toFlatty(s: var string, x: object) =
  for _, e in x.fieldPairs:
    s.toFlatty(e)

func fromFlatty(s: string, i: var int, x: var object) =
  for _, e in x.fieldPairs:
    s.fromFlatty(i, e)

func toFlatty(s: var string, x: ref object) =
  let isNil = x == nil
  s.toFlatty(isNil)
  if not isNil:
    for _, e in x[].fieldPairs:
      s.toFlatty(e)

func fromFlatty(s: string, i: var int, x: var ref object) =
  var isNil: bool
  s.fromFlatty(i, isNil)
  if not isNil:
    new(x)
    for _, e in x[].fieldPairs:
      s.fromFlatty(i, e)

# Distinct
func toFlatty[T: distinct](s: var string, x: T) =
  s.toFlatty(x.distinctBase)

func fromFlatty[T: distinct](s: string, i: var int, x: var T) =
  s.fromFlatty(i, x.distinctBase)

# Tables
func toFlatty[K, V](s: var string, x: Table[K, V]) =
  s.addInt64(x.len.int64)
  for k, v in x:
    s.toFlatty(k)
    s.toFlatty(v)

func fromFlatty[K, V](s: string, i: var int, x: var Table[K, V]) =
  let len = s.readInt64(i)
  i += 8
  for _ in 0 ..< len:
    var
      k: K
      v: V
    s.fromFlatty(i, k)
    s.fromFlatty(i, v)
    x[k] = v

# Arrays
func toFlatty[N, T](s: var string, x: array[N, T]) =
  for e in x:
    s.toFlatty(e)

func fromFlatty[N, T](s: string, i: var int, x: var array[N, T]) =
  for j in 0 ..< x.len:
    s.fromFlatty(i, x[j])

# Tuples
func toFlatty[T: tuple](s: var string, x: T) =
  for _, e in x.fieldPairs:
    s.toFlatty(e)

func fromFlatty[T: tuple](s: string, i: var int, x: var T) =
  for _, e in x.fieldPairs:
    s.fromFlatty(i, e)

func toFlatty*[T](x: T): string =
  ## Takes structures and turns them into binary string.
  result.toFlatty(x)

func fromFlatty*[T](s: string, x: typedesc[T]): T =
  ## Takes binary string and turn into structures.
  var i = 0
  s.fromFlatty(i, result)
