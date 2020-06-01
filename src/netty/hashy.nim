## Hash functions based on flatty
import hashes, flatty

export Hash

proc hash*(x: Hash): Hash = x

{.push overflowChecks: off.}
proc sdbm(s: string): int =
  for c in s:
    result = c.int + (result shl 6) + (result shl 16) - result

proc djb2(s: string): int =
  result = 53810036436437415.int # Usually 5381
  for c in s:
    result = result * 33 + c.int

proc hashy*[T](x: T): Hash =
  ## Takes structures and turns them into binary string.
  let s = x.toFlatty()
  djb2(s)
{.pop.}

when isMainModule:
  echo hashy(1.int8)
  echo hashy(1.uint8)
  echo hashy(1.int16)
  echo hashy(1.uint16)
  echo hashy(1.int32)
  echo hashy(1.uint32)
  echo hashy(1.int64)
  echo hashy(1.uint64)
  echo hashy(1.float32)
  echo hashy(1.float64)
  echo hashy("the number one")
  echo hashy("the number one, the number one")
  echo hashy("the number one, the number one, the number one")
