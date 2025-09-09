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
  Cbor.encode(buffer, req)

proc rpcUnpack*(buffer: MsgBuffer, req: var FastRpcRequest) =
  Cbor.decode(buffer, req)

proc rpcPack*(so: var MsgBuffer,
              res: FastRpcResponse,
              size: int) =
  Cbor.encode(so, res)

proc rpcUnpack*(buffer: MsgBuffer, res: var FastRpcResponse) =
  Cbor.decode(buffer, res)

proc rpcPack*(buffer: var MsgBuffer, err: FastRpcError) =
  Cbor.encode(buffer, err)

proc rpcUnpack*(buffer: MsgBuffer, err: var FastRpcError) =
  Cbor.decode(buffer, err)

proc rpcToJsonNode*(buffer: MsgBuffer): JsonNode =
  Cbor.toJsonNode(buffer)

proc rpcFromJsonNode*(buffer: MsgBuffer, node: JsonNode) =
  Cbor.fromJsonNode(buffer, node)