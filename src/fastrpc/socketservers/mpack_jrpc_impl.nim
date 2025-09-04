import sets
import json
import msgpack4nim/msgpack2json

import mcu_utils/logging
import mcu_utils/msgbuffer

import mcu_utils/inettypes
import ../socketservers/sockethelpers
import ../extrarouters/router_json

import common_handlers

export router_json

type 
  JsonRpcOpts* = ref object
    router*: RpcRouter
    bufferSize*: int
    prefixMsgSize*: bool

proc mpackJrpcExec*(rt: RpcRouter,
                    ss: sink MsgBuffer,
                    ): string =
  logDebug("msgpack processing")
  var rcall = msgpack2json.toJsonNode(ss.data)
  var res: JsonNode = rt.route(rcall)
  result = res.fromJsonNode()

customPacketRpcHandler(packetMpackJRpcHandler, mpackJrpcExec)

proc newMpackJRpcServer*(router: RpcRouter, bufferSize = 1400, prefixMsgSize = false): SocketServerImpl[JsonRpcOpts] =
  new(result)
  result.readHandler = packetMpackJRpcHandler
  result.writeHandler = nil 
  result.data = new(JsonRpcOpts) 
  result.data.bufferSize = bufferSize 
  result.data.router = router
  result.data.prefixMsgSize = prefixMsgSize
