# nim c -r --threads:on --tlsEmulation:off tests\chatclientthreads

import netty, terminal

var client = newReactor()
var connection = client.connect("127.0.0.1", 2001)

# get persons name
echo "what is your name?"
var name = readLine(stdin)

# handle ctrl-c correclty on windows by stopping all threads
proc handleCtrlC() {.noconv.} =
  setupForeignThreadGc()
  quit(1)
setControlCHook(handleCtrlC)

# create a thread that just reads a single chart
var
  thread: Thread[tuple[a: int]]
  singleChar: char
proc readSingleChar(interval: tuple[a: int]) {.thread.} =
  while true:
    singleChar = getch()
createThread(thread, readSingleChar, (0, ))

# main loop
var line: string
while true:
  client.tick()
  for packet in client.packets:
    # we got a packet, rase current line user is typing
    stdout.eraseLine()
    # write packet line
    echo packet.data
    # write back the line was typing
    writeStyled(line)

  if singleChar != char(0):
    if singleChar == char(8):
      # handle backspace
      line.setLen(line.len - 1)
    else:
      line.add(singleChar)
    # a char got added, erase current line
    stdout.eraseLine()
    # write the line again
    writeStyled(line & " ")
    # put cursor in right spot
    stdout.setCursorXPos(line.len)

    if singleChar == char(13):
      # handle sending
      connection.send(name & ":" & line)
      # clear line, reset eveything
      # server should echo the line back
      line = ""
      stdout.eraseLine()
      stdout.setCursorXPos(0)

    # reset character
    singleChar = char(0)
