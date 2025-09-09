import cbor_serialization

import ./rpcdatatypes
import ../utils/msgbuffer

export cbor_serialization

## MsgPack serde implementations ##

proc rpcPack*(res: FastRpcParamsBuffer): FastRpcParamsBuffer {.inline.} =
  result = res

proc rpcPack*(res: JsonNode): FastRpcParamsBuffer =
  var jpack = res.fromJsonNode()
  var ss = MsgBuffer.init(jpack)
  ss.setPosition(jpack.len())
  FastRpcParamsBuffer(buf: ss)

proc rpcPack*[T](res: T): FastRpcParamsBuffer =
  var ss = MsgBuffer.init()
  Cbor.decode(ss, res)
  result = FastRpcParamsBuffer(buf: ss)

proc rpcUnpack*[T](obj: var T, ss: FastRpcParamsBuffer, resetStream = true) =
  try:
    if resetStream:
      ss.buf.setPosition(0)
    ss.buf.unpack(obj)
  except AssertionDefect as err:
    raise newException(ObjectConversionDefect,
                       "unable to parse parameters: " & err.msg)

proc rpcPack*(buffer: MsgBuffer, req: FastRpcRequest) =
  msgpack4nim.pack(buffer, req)

proc rpcUnpack*(buffer: MsgBuffer, req: var FastRpcRequest) =
  msgpack4nim.unpack(buffer, req)

proc rpcPack*(so: var MsgBuffer,
              res: FastRpcResponse,
              size: int) =
  msgpack4nim.pack(so, res)

proc rpcUnpack*(buffer: MsgBuffer, res: var FastRpcResponse) =
  msgpack4nim.unpack(buffer, res)

proc rpcPack*(buffer: var MsgBuffer, err: FastRpcError) =
  msgpack4nim.pack(buffer, err)

proc rpcUnpack*(buffer: MsgBuffer, err: var FastRpcError) =
  msgpack4nim.unpack(buffer, err)

proc rpcToJsonNode*(buffer: MsgBuffer): JsonNode =
  msgpack2json.toJsonNode(buffer)

proc rpcFromJsonNode*(buffer: MsgBuffer, node: JsonNode) =
  msgpack2json.fromJsonNode(buffer, node)