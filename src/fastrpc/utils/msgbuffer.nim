import std/streams
import msgpack4nim

type MsgBuffer* = MsgStream

export msgpack4nim, streams

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
