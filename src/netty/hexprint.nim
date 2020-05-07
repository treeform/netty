import streams, strutils

proc hexPrint*(buf: Stream): string =
  ## Prints a string in hex format of the old DOS debug program.
  ## Useful for looking at binary dumps.
  ## hexPrint("Hi how are you doing today?")
  ## 0000:  48 69 20 68 6F 77 20 61-72 65 20 79 6F 75 20 64 Hi how are you d
  ## 0010:  6F 69 6E 67 20 74 6F 64-61 79 3F .. .. .. .. .. oing today?.....
  var start = buf.getPosition()
  buf.setPosition(0)
  while not buf.atEnd():
    # Print the label.
    result.add(toHex(buf.getPosition(), 4))
    result.add(": ")
    let line = buf.readStr(16)

    # Print the bytes.
    for i in 0 ..< 16:
      if i < line.len:
        let b = line[i]
        result.add(toHex(int b, 2))
      else:
        result.add("..")
      if i == 7:
        result.add("-")
      else:
        result.add(" ")

    # Print the ascii.
    for i in 0 ..< 16:
      if i < line.len:
        let b = line[i]
        if ord(b) >= 32 and ord(b) <= 126:
          result.add(b)
        else:
          result.add('.')
      else:
        result.add('.')

    result.add("\n")
  buf.setPosition(start)

proc hexPrint*(buf: string): string =
  newStringStream(buf).hexPrint()
