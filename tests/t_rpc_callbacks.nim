import std/unittest
import std/json

import fastrpc/server/rpcmethods

suite "Callback-style RPCs":
  test "basic add returns sum":
    var router = newFastRpcRouter()

    router.rpc("add") do(a: int, b: int) -> int:
      result = a + b

    check router.hasMethod("add")

    let procAdd = router.procs["add"]

    var args = RpcType_add(a: 2, b: 3)
    let paramsBuf = rpcPack(args)

    var ctx = RpcContext(id: FastRpcId(0), clientId: InetClientHandle.empty())
    let resBuf = procAdd(paramsBuf, ctx)

    var sum = 0
    resBuf.buf.setPosition(0)
    resBuf.buf.unpack(sum)
    check sum == 5

  test "context is available in callback":
    var router = newFastRpcRouter()

    router.rpc("ctxid") do(a: int): FastRpcId:
      result = context.id

    check router.hasMethod("ctxid")

    let procCtx = router.procs["ctxid"]
    var args = RpcType_ctxid(a: 7)
    let paramsBuf = rpcPack(args)

    var ctx = RpcContext(id: FastRpcId(12345), clientId: InetClientHandle.empty())
    let resBuf = procCtx(paramsBuf, ctx)

    var rid: FastRpcId = 0
    resBuf.buf.setPosition(0)
    resBuf.buf.unpack(rid)
    check rid == FastRpcId(12345)
