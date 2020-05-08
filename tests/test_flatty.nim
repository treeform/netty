import netty/flatty, tables

# Test booleans.
assert true.toFlatty.fromFlatty(bool) == true
assert false.toFlatty.fromFlatty(bool) == false

# Test numbers.
assert 123.toFlatty.fromFlatty(int) == 123
assert 123.uint8.toFlatty.fromFlatty(uint8) == 123
assert 123.uint16.toFlatty.fromFlatty(uint16) == 123
assert 123.uint32.toFlatty.fromFlatty(uint32) == 123
assert 123.uint64.toFlatty.fromFlatty(uint64) == 123
assert 123.int8.toFlatty.fromFlatty(int8) == 123
assert 123.int16.toFlatty.fromFlatty(int16) == 123
assert 123.int32.toFlatty.fromFlatty(int32) == 123
assert 123.int64.toFlatty.fromFlatty(int64) == 123
assert 123.456.toFlatty.fromFlatty(float) == 123.456
assert $(123.456.float32).toFlatty.fromFlatty(float32) == "123.4560012817383"
assert (123.456.float64).toFlatty.fromFlatty(float64) == 123.456

# Test strings.
var str: string
assert str.toFlatty.fromFlatty(string) == str
assert "".toFlatty.fromFlatty(string) == ""
assert "hello world".toFlatty.fromFlatty(string) == "hello world"
assert "乾隆己酉夏".toFlatty.fromFlatty(string) == "乾隆己酉夏"
assert "\0\0\0\0".toFlatty.fromFlatty(string) == "\0\0\0\0"

# Test arrays.
var arr: seq[int]
assert $(arr.toFlatty.fromFlatty(seq[int])) == $(arr)
assert $(@[1, 2, 3].toFlatty.fromFlatty(seq[int])) == $(@[1, 2, 3])
assert $(@[1.uint8, 2, 3].toFlatty.fromFlatty(seq[uint8])) ==
  $(@[1.uint8, 2, 3])
assert $(@["hi", "ho", "hey"].toFlatty.fromFlatty(seq[string])) ==
  $(@["hi", "ho", "hey"])
assert $(@[@["hi"], @[], @[]].toFlatty.fromFlatty(seq[seq[string]])) ==
  $(@[@["hi"], @[], @[]])

# Test enums.
type RandomEnum = enum
  Left
  Right
  Top
  Bottom

assert Left.toFlatty().fromFlatty(RandomEnum) == Left
assert Right.toFlatty().fromFlatty(RandomEnum) == Right
assert Top.toFlatty().fromFlatty(RandomEnum) == Top
assert Bottom.toFlatty().fromFlatty(RandomEnum) == Bottom

# Test regular objects.
type Foo = object
  id: int
  name: string
  time: float
  active: bool

let foo = Foo(id: 32, name: "yes", time: 16.77, active: true)
assert foo.toFlatty().fromFlatty(Foo) == foo

# Test ref objects.
type Bar = ref object
  id: int
  arr: seq[int]
  foo: Foo

var bar = Bar(id: 12)
var bar2 = bar.toFlatty().fromFlatty(Bar)
assert bar2 != nil
assert bar.id == bar2.id
assert bar.arr.len == 0
assert bar.foo == Foo()

# Test nested ref objects.
type Node = ref object
  left: Node
  right: Node
var node = Node(left: Node(left: Node()))
var node2 = node.toFlatty().fromFlatty(Node)
assert node2.left != nil
assert node2.left.left != nil
assert node2.left.left.left == nil
assert node2.right == nil

# Test distinct objects
type Ts = distinct float64
var ts = Ts(123.123)
func `==`(a, b: TS): bool = float64(a) == float64(b)
assert ts.toFlatty.fromFlatty(Ts) == ts

# Test tables
var table: Table[string, string]
table["hi"] = "bye"
table["foo"] = "bar"
assert table.toFlatty.fromFlatty(Table[string, string]) == table
