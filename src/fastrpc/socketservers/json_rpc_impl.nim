import sets
import json
import msgpack4nim/msgpack2json

import mcu_utils/logging
import mcu_utils/inettypes

import common_handlers

export router_json

type 
  JsonRpcOpts* = ref object
    router*: RpcRouter
    bufferSize*: int
    prefixMsgSize*: bool

proc jsonRpcExec*(rt: RpcRouter, msg: var string): string =
  logDebug("msgpack processing")
  var rcall = msgpack2json.toJsonNode(msg)
  var res: JsonNode = rt.route( rcall )
  result = res.fromJsonNode()

customPacketRpcHandler(packetRpcHandler, jsonRpcExec)

proc newJsonRpcServer*(router: RpcRouter, bufferSize = 1400, prefixMsgSize = false): SocketServerImpl[JsonRpcOpts] =
  new(result)
  result.readHandler = packetRpcHandler
  result.writeHandler = nil 
  result.data = new(JsonRpcOpts) 
  result.data.bufferSize = bufferSize 
  result.data.router = router
  result.data.prefixMsgSize = prefixMsgSize
