import std/streams
# import msgpack4nim

type MsgBuffer* = ref object of StringStreamObj

export streams

proc init*(x: typedesc[MsgBuffer], data: sink string): MsgBuffer =
  result = new x
  # Initialize StringStream base by copying fields from a new StringStream:
  var ss = newStringStream()
  result.data = data
  result.closeImpl = ss.closeImpl
  result.atEndImpl = ss.atEndImpl
  result.setPositionImpl = ss.setPositionImpl
  result.getPositionImpl = ss.getPositionImpl
  result.readDataStrImpl = ss.readDataStrImpl
  when nimvm:
    discard
  else:
    result.readDataImpl = ss.readDataImpl
    result.peekDataImpl = ss.peekDataImpl
    result.writeDataImpl = ss.writeDataImpl
  # result.setEncodingMode(encodingMode)


proc init*(x: typedesc[MsgBuffer], cap: int = 0): MsgBuffer =
  result = init(x, newStringOfCap(cap))

proc readStrRemaining*(s: MsgBuffer): string =
  let ln = s.data.len() - s.getPosition() 
  result = newString(ln)
  if ln != 0:
    var rl = s.readData(addr(result[0]), ln)
    if rl != ln: raise newException(IOError, "string len mismatch")

proc readMsgBuffer*(s: MsgBuffer, length: int): MsgBuffer =
  result = MsgBuffer.init(length)
  if length != 0:
    var L = s.readData(addr(result.data[0]), length)
    result.setPosition(L)

proc readMsgBufferRemaining*(s: MsgBuffer): MsgBuffer =
  result = s.readMsgBuffer(s.data.len() - s.getPosition())

when false:
  macro lineinfo(code: untyped): untyped =
    result = newStrLitNode($(code.lineinfo))

  template logAllocStats*(level: static[Level], code: untyped) =
    ## Log allocations that occur during the code block
    ## must pass `-d:nimAllocStats` during compilation
    logRunExtra(level):
      let stats1 = getAllocStats()
      block:
        code
      let stats2 = getAllocStats()
      log(level, "[allocStats]", lineinfo(code), "::", $(stats2 - stats1))
    do: 
      code