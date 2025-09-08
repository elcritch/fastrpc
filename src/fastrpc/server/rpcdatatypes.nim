
import std/tables, std/sets, std/macros, std/sysrand
import std/sugar, std/options
import std/strutils

export sugar

import std/selectors
import std/times

import threading/channels
export sets, selectors, channels

import ../utils/inettypes
import ../utils/inetqueues
import ../utils/logging

import protocol
export protocol
export options


type
  FastRpcErrorStackTrace* = object
    code*: int
    msg*: string
    stacktrace*: seq[string]

  # Context for servicing an RPC call 
  RpcContext* = object
    id*: FastrpcId
    clientId*: InetClientHandle

  # Procedure signature accepted as an RPC call by server
  FastRpcProc* = proc(params: FastRpcParamsBuffer,
                      context: RpcContext
                      ): FastRpcParamsBuffer {.gcsafe, nimcall.}

  FastRpcBindError* = object of ValueError
  FastRpcAddressUnresolvableError* = object of ValueError

  RpcSubId* = int32
  RpcSubOpts* = object
    subid*: RpcSubId
    evt*: SelectEvent
    timeout*: Duration
    source*: string

  RpcStreamSerializerClosure* = proc(): FastRpcParamsBuffer {.closure.}

  RpcSubClients* = object
    eventProc*: RpcStreamSerializerClosure
    subs*: TableRef[InetClientHandle, RpcSubId]

  FastRpcRouter* = ref object
    procs*: Table[string, FastRpcProc]
    sysprocs*: Table[string, FastRpcProc]
    subEventProcs*: Table[SelectEvent, RpcSubClients]
    subNames*: Table[string, SelectEvent]
    stacktraces*: bool
    subscriptionTimeout*: Duration
    inQueue*: InetMsgQueue
    outQueue*: InetMsgQueue
    registerQueue*: InetEventQueue[InetQueueItem[RpcSubOpts]]


type
  ## Rpc Streamer Task types
  RpcStreamSerializer*[T] =
    proc(queue: InetEventQueue[T]): RpcStreamSerializerClosure {.nimcall.}

  TaskOption*[T] = object
    data*: T
    ch*: Chan[T]

  RpcStreamTask*[T, O] = proc(queue: InetEventQueue[T], options: TaskOption[O])


  ThreadArg*[T, U] = object
    queue*: InetEventQueue[T]
    opt*: TaskOption[U]

  RpcStreamThread*[T, U] = Thread[ThreadArg[T, U]]

proc randBinString*(): RpcSubId =
  var idarr: array[sizeof(RpcSubId), byte]
  if urandom(idarr):
    result = cast[RpcSubId](idarr)
  else:
    result = RpcSubId(0)

proc newFastRpcRouter*(
    inQueueSize = 2,
    outQueueSize = 2,
    registerQueueSize = 2,
): FastRpcRouter =
  new(result)
  result.procs = initTable[string, FastRpcProc]()
  result.sysprocs = initTable[string, FastRpcProc]()
  result.subEventProcs = initTable[SelectEvent, RpcSubClients]()
  result.stacktraces = defined(debug)

  let
    inQueue = InetMsgQueue.init(size=inQueueSize)
    outQueue = InetMsgQueue.init(size=outQueueSize)
    registerQueue =
      InetEventQueue[InetQueueItem[RpcSubOpts]].init(size=registerQueueSize)
  
  result.inQueue = inQueue
  result.outQueue = outQueue
  result.registerQueue = registerQueue

proc subscribe*(
    router: FastRpcRouter,
    procName: string,
    clientId: InetClientHandle,
    timeout = initDuration(milliseconds= -1),
    source = "",
): Option[RpcSubId] =
  # send a request to fastrpcserver to subscribe a client to a subscription
  let 
    to =
      if timeout != initDuration(milliseconds= -1): timeout
      else: router.subscriptionTimeout
  let subid: RpcSubId = randBinString()
  log(lvlDebug, "fastrouter:subscribing::", procName, "subid:", subid)
  let val = RpcSubOpts(subid: subid,
                       evt: router.subNames[procName],
                       timeout: to,
                       source: source)
  var item = isolate InetQueueItem[RpcSubOpts].init(clientId, val)
  if router.registerQueue.trySend(item):
    result = some(subid)

proc listMethods*(rt: FastRpcRouter): seq[string] =
  ## list the methods in the given router. 
  result = newSeqOfCap[string](rt.procs.len())
  for name in rt.procs.keys():
    result.add name

proc listSysMethods*(rt: FastRpcRouter): seq[string] =
  ## list the methods in the given router. 
  result = newSeqOfCap[string](rt.sysprocs.len())
  for name in rt.sysprocs.keys():
    result.add name

template rpcQueuePacker*(procName: untyped,
                         rpcProc: untyped,
                         qt: untyped,
                            ): untyped =
  proc `procName`*(queue: `qt`): RpcStreamSerializerClosure  =
      result = proc (): FastRpcParamsBuffer =
        let res = `rpcProc`(queue)
        result = rpcPack(res)

proc wrapResponse*(id: FastRpcId, resp: FastRpcParamsBuffer, kind = Response): FastRpcResponse = 
  result.kind = kind
  result.id = id
  result.result = resp

proc wrapResponseError*(id: FastRpcId, err: FastRpcError): FastRpcResponse = 
  result.kind = Error
  result.id = id
  var ss = MsgBuffer.init()
  ss.pack(err)
  result.result = FastRpcParamsBuffer(buf: ss)

proc wrapResponseError*(id: FastRpcId, code: FastErrorCodes, msg: string, err: ref Exception, stacktraces: bool): FastRpcResponse = 
  let errobj = FastRpcError(code: SERVER_ERROR, msg: msg)
  if stacktraces and not err.isNil():
    errobj.trace = @[]
    for se in err.getStackTraceEntries():
      let file: string = rsplit($(se.filename), '/', maxsplit=1)[^1]
      errobj.trace.add( ($se.procname, file, se.line, ) )
  result = wrapResponseError(id, errobj)
