import msgpack4nim
import msgpack4nim/msgpack2json

export msgpack4nim, msgpack2json

import ./rpcdatatypes
import ../utils/msgbuffer

## MsgPack serde implementations ##

proc pack_type*[ByteStream](s: ByteStream, x: FastRpcParamsBuffer) =
  s.write(x.buf.data, x.buf.getPosition())

proc unpack_type*[ByteStream](s: ByteStream, x: var FastRpcParamsBuffer) =
  var params = s.readStrRemaining()
  x.buf = MsgBuffer.init()
  x.buf.data = params

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

proc packResponse*(res: FastRpcResponse,
                   size: int): QMsgBuffer =
  var so = newUniquePtr(MsgBuffer.init(size))
  msgpack4nim.pack(so[], res)
  so
