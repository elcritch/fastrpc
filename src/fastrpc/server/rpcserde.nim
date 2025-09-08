import msgpack4nim
import msgpack4nim/msgpack2json

export msgpack4nim, msgpack2json

import ./rpcdatatypes
import ../utils/msgbuffer

proc rpcPack*(res: FastRpcParamsBuffer): FastRpcParamsBuffer {.inline.} =
  result = res

template rpcPack*(res: JsonNode): FastRpcParamsBuffer =
  var jpack = res.fromJsonNode()
  var ss = MsgBuffer.init(jpack)
  ss.setPosition(jpack.len())
  FastRpcParamsBuffer(buf: ss)

proc rpcPack*[T](res: T): FastRpcParamsBuffer =
  var ss = MsgBuffer.init()
  ss.pack(res)
  result = FastRpcParamsBuffer(buf: ss)

proc rpcUnpack*[T](obj: var T, ss: FastRpcParamsBuffer, resetStream = true) =
  try:
    if resetStream:
      ss.buf.setPosition(0)
    ss.buf.unpack(obj)
  except AssertionDefect as err:
    raise newException(ObjectConversionDefect,
                       "unable to parse parameters: " & err.msg)
