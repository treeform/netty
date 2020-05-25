import fidget, vmath, fidget/opengl/base, fidget/opengl/context, netty, random,
  netty/flatty, tables, strformat, times

randomize()

type
  Player = object
    pos: Vec2
    vel: Vec2

  Packet = object
    id: int
    player: Player

var
  myId = rand(0 .. 10000)
  me: Player
  client = newReactor()
  connection = client.connect("127.0.0.1", 2001)

  others: Table[int, Player]
  othersSmoothPos: Table[int, Vec2]

  debugPosSeq: seq[Vec2]

client.debug.dropRate = 0.0
client.debug.minLatency = 0.5

loadFont("Changa Bold", "Changa-Bold.ttf")

proc tickMain() =
  # Note: this function runs at 240hz.
  #echo focused
  if focused and mouse.pos.inRect(vec2(0, 0), windowFrame):
    if ((windowFrame / 2) - mouse.pos).length > 0:
      me.vel -= dir(windowFrame / 2, mouse.pos) * 0.1
  me.vel *= 0.9 # friction
  me.pos += me.vel

  if frameCount mod 10 == 0:
    client.send(connection, Packet(id: myId, player: me).toFlatty())

  for msg in client.messages:
    var p = msg.data.fromFlatty(Packet)
    debugPosSeq.add(p.player.pos)
    if debugPosSeq.len > 100:
      debugPosSeq = debugPosSeq[1..^1]
    if p.id != myId:
      others[p.id] = p.player
      if p.id notin othersSmoothPos:
         othersSmoothPos[p.id] = p.player.pos

  client.tick()

  for id, other in others.mpairs:
    othersSmoothPos[id] = lerp(othersSmoothPos[id], other.pos, 0.01) + other.vel

proc drawMain() =
  # Note: this functions runs at monitor refresh rate (usually 60hz).
  clearColorBuffer(color(1, 1, 1, 1))

  ctx.saveTransform()
  ctx.translate(-me.pos + windowFrame / 2)

  for x in 0 .. 10:
    for y in 0 .. 10:
      ctx.drawSprite("tile.png", vec2(x.float32 * 100, y.float32 * 100))

  ctx.drawSprite("star.png", me.pos)

  for id, other in others.pairs:
    ctx.drawSprite("star.png", othersSmoothPos[id], color=color(1,0,0,1))

  for pos in debugPosSeq:
    ctx.drawSprite("star.png", pos, color=color(0,1,0,1), scale=0.05)


  ctx.restoreTransform()

  font "Changa Bold", 20, 200, 40, hLeft, vTop
  text "networks":
    box 30, 30, 400, 600
    fill "#202020"
    textAlign hLeft, vTop
    characters &"""
    Fps: {1/avgFrameTime}
    Network:
      avgLatency: {(connection.stats.latencyTs.avg()*1000).int} ms
      maxLatency: {(connection.stats.latencyTs.max()*1000).int} ms
      dropRate: {client.debug.dropRate*100} %
      inFlight: {connection.stats.inFlight} bytes
      throughput: {connection.stats.throughputTs.avg().int} bytes
    """


startFidget(
  draw = drawMain,
  tick = tickMain,
  w = 1280,
  h = 800,
  openglVersion = (4, 1),
  msaa = msaa4x,
  mainLoopMode = RepaintSplitUpdate
)
