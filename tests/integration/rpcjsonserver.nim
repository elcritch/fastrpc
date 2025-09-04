import fastrpc/socketserver
import fastrpc/socketservers/json_rpc_impl

import std/monotimes

const
  VERSION = "1.0.0"

# Define RPC Server #
proc rpc_server*(): RpcRouter =
  var rt = createRpcRouter()

  rpc(rt, "version") do() -> string:
    result = VERSION

  rpc(rt, "micros") do() -> int:
    let a = getMonoTime().ticks()
    result = int(a div 1000)

  rpc(rt, "add") do(a: int, b: int) -> int:
    result = a + b

  return rt

when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 5555, Protocol.IPPROTO_UDP),
    newInetAddr("0.0.0.0", 5555, Protocol.IPPROTO_TCP),
  ]

  let router = rpc_server()
  startSocketServer(inetAddrs, newJsonRpcServer(router, prefixMsgSize=true))
