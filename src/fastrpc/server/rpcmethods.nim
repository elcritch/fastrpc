import std/[tables, strutils, macros] 
import std/options
import std/times
import std/monotimes

import threading/channels

import ../utils/inettypes
import ../utils/inetqueues
import ../utils/msgbuffer
export inettypes, inetqueues

export options
import rpcdatatypes
export rpcdatatypes
import router
export router

proc makeProcName(s: string): string =
  result = ""
  for c in s:
    if c.isAlphaNumeric: result.add c

proc hasReturnType(params: NimNode): bool =
  if params != nil and params.len > 0 and params[0] != nil and
     params[0].kind != nnkEmpty:
    result = true

proc firstArgument(params: NimNode): (string, string) =
  if params != nil and
      params.len > 0 and
      params[1] != nil and
      params[1].kind == nnkIdentDefs:
    result = (params[1][0].strVal, params[1][1].repr)
  else:
    result = ("", "")

iterator paramsIter(params: NimNode): tuple[name, ntype: NimNode] =
  for i in 1 ..< params.len:
    let arg = params[i]
    let argType = arg[^2]
    for j in 0 ..< arg.len-2:
      yield (arg[j], argType)

proc mkParamsVars(paramsIdent, paramsType, params: NimNode): NimNode =
  ## Create local variables for each parameter in the actual RPC call proc
  if params.isNil: return

  result = newStmtList()
  var varList = newSeq[NimNode]()
  for paramid, paramType in paramsIter(params):
    let localName = ident(paramid.strVal)
    varList.add quote do:
      var `localName`: `paramType` = `paramsIdent`.`localName`
  result.add varList
  # echo "paramsSetup return:\n", treeRepr result

proc mkParamsType*(paramsIdent, paramsType, params: NimNode): NimNode =
  ## Create a type that represents the arguments for this rpc call
  ## 
  ## Example: 
  ## 
  ##   proc multiplyrpc(a, b: int): int {.rpc.} =
  ##     result = a * b
  ## 
  ## Becomes:
  ##   proc multiplyrpc(params: RpcType_multiplyrpc): int = 
  ##     var a = params.a
  ##     var b = params.b
  ##   
  ##   proc multiplyrpc(params: RpcType_multiplyrpc): int = 
  ## 
  if params.isNil: return

  var typObj = quote do:
    type
      `paramsType` = object
  var recList = newNimNode(nnkRecList)
  for paramIdent, paramType in paramsIter(params):
    # processing multiple variables of one type
    recList.add newIdentDefs(postfix(paramIdent, "*"), paramType)
  typObj[0][2][2] = recList
  result = typObj

macro rpcImpl*(p: untyped, publish: untyped, qarg: untyped): untyped =
  ## Define a remote procedure call.
  ## Input and return parameters are defined using proc's with the `rpc` 
  ## pragma. 
  ## 
  ## For example:
  ## .. code-block:: nim
  ##    proc methodname(param1: int, param2: float): string {.rpc.} =
  ##      result = $param1 & " " & $param2
  ##    ```
  ## 
  ## Input parameters are automatically marshalled from fast rpc binary 
  ## format (msgpack) and output parameters are automatically marshalled
  ## back to the fast rpc binary format (msgpack) for transport.
  
  let
    path = $p[0]
    params = p[3]
    pragmas = p[4]
    body = p[6]

  result = newStmtList()
  var
    parameters = params

  let
    # determine if this is a "system" rpc method
    pubthread = publish.kind == nnkStrLit and publish.strVal == "thread"
    serializer = publish.kind == nnkStrLit and publish.strVal == "serializer"
    syspragma = not pragmas.findChild(it.repr == "system").isNil

    # rpc method names
    pathStr = $path
    procNameStr = pathStr.makeProcName()

    # public rpc proc
    procName = ident(procNameStr & "Func")
    rpcMethod = ident(procNameStr)

    ctxName = ident("context")

    # parameter type name
    paramsIdent = genSym(nskVar, "rpcArgs")
    paramTypeName = ident("RpcType_" & procNameStr)

  var
    # process the argument types
    paramSetups = mkParamsVars(paramsIdent, paramTypeName, parameters)
    paramTypes = mkParamsType(paramsIdent, paramTypeName, parameters)
    procBody = if body.kind == nnkStmtList: body else: body.body

  let ContextType = ident "RpcContext"
  let ReturnType = if parameters.hasReturnType:
                      parameters[0]
                   else:
                      error("must provide return type")
                      ident "void"

  # Create the proc's that hold the users code 
  if not pubthread and not serializer:
    result.add quote do:
      `paramTypes`

      proc `procName`(`paramsIdent`: `paramTypeName`,
                      `ctxName`: `ContextType`
                      ): `ReturnType` =
        {.cast(gcsafe).}:
          `paramSetups`
          `procBody`

    # Create the rpc wrapper procs
    result.add quote do:
      proc `rpcMethod`(params: FastRpcParamsBuffer, context: `ContextType`): FastRpcParamsBuffer {.gcsafe, nimcall.} =
        var obj: `paramTypeName`
        obj.rpcUnpack(params)

        let res = `procName`(obj, context)
        result = res.rpcPack()

    if syspragma:
      result.add quote do:
        sysRegister(router, `path`, `rpcMethod`)
    else:
      result.add quote do:
        register(router, `path`, `rpcMethod`)

  elif pubthread:
    result.add quote do:
      var `rpcMethod`: FastRpcEventProc
      template `procName`(): `ReturnType` =
        `procBody`
      closureScope: # 
        `rpcMethod` =

          proc(): FastRpcParamsBuffer =
            let res = `procName`()
            result = rpcPack(res)

      register(router, `path`, `qarg`.evt, `rpcMethod`)
  elif serializer:
    var rpcFunc = quote do:
      proc `procName`(): `ReturnType` =
        `procBody`
    rpcFunc[3] = params
    let qarg = params[1]
    assert qarg.kind == nnkIdentDefs and qarg[0].repr == "queue"
    let qt = qarg[1] # first param...
    discard
    var rpcMethod = quote do:
      rpcQueuePacker(`rpcMethod`, `procName`, `qt`)
    # rpcMethod[3] = params
    result.add newStmtList(rpcFunc, rpcMethod)

## Callback-style RPCs: router.rpc("name") do(a: T, b: U) -> R: body
macro rpc*(router: var FastRpcRouter, path: string, cb: untyped): untyped =
  ## Register an RPC using a callback form:
  ##   router.rpc("add") do(a: int, b: int) -> int:
  ##     a + b
  ## The callback may reference `context` and use `rpcReply(...)`.

  let pathStr = path.strVal
  # Ensure we have a DO block with formal params
  if cb.kind != nnkDo:
    error "rpc expects a `do(...)` callback block"

  var params: NimNode
  var body: NimNode
  if cb.len >= 7 and cb[3].kind == nnkFormalParams and cb[6].kind == nnkStmtList:
    params = cb[3]
    body = cb[6]
  else:
    error "rpc callback has malformed parameters"
  discard

  let
    procNameStr = pathStr.makeProcName()
    rpcMethod = ident(procNameStr)
    ContextType = ident "RpcContext"
    paramsIdent = genSym(nskVar, "rpcArgs")
    paramTypeName = ident("RpcType_" & procNameStr)
    innerName = genSym(nskProc, procNameStr & "Inner")

  var
    paramTypes = mkParamsType(paramsIdent, paramTypeName, params)

  # Build inner proc formal params: (a: T, b: U, context: RpcContext) -> ReturnType
  var innerFormal = newTree(nnkFormalParams, newEmptyNode())
  # return type will be set below once we compute ReturnType
  for paramid, paramType in paramsIter(params):
    innerFormal.add newIdentDefs(ident(paramid.strVal), paramType, newEmptyNode())
  let ctxParam = genSym(nskParam, "ctx")
  innerFormal.add newIdentDefs(ctxParam, ContextType, newEmptyNode())

  # Wrapper call args to inner proc: rpcArgs.a, rpcArgs.b, ctxPass
  var innerCallArgs = newSeq[NimNode]()
  for paramid, _ in paramsIter(params):
    innerCallArgs.add newDotExpr(paramsIdent, ident(paramid.strVal))
  let ctxPassSym = genSym(nskLet, "ctxPass")
  innerCallArgs.add ctxPassSym
  let innerCall = newCall(innerName, innerCallArgs)

  # Determine return type
  var ReturnType: NimNode
  if params.hasReturnType:
    ReturnType = params[0]
  else:
    # Handle form: do(args): Type: <body>
    if body.kind == nnkStmtList and body.len == 1 and body[0].kind == nnkCall:
      let call = body[0]
      if call.len >= 2 and call[1].kind == nnkStmtList:
        ReturnType = call[0]
        body = call[1]
      else:
        error("rpc callback must declare a return type")
    else:
      error("rpc callback must declare a return type")

  # set return type on innerProc formals
  innerFormal[0] = ReturnType

  # Construct inner proc with the user's body
  # Prepend 'let context = ctxParam' so `rpcReply` templates can see it
  var bindContext = newTree(nnkLetSection,
    newIdentDefs(ident("context"), newEmptyNode(), ctxParam)
  )
  var innerBody = newStmtList(bindContext, body)

  var innerProc = newTree(nnkProcDef,
    innerName,              # name
    newEmptyNode(),         # pattern
    newEmptyNode(),         # generic params
    innerFormal,            # formal params
    newEmptyNode(),         # pragmas
    newEmptyNode(),         # exceptions
    innerBody               # body (user callback body, with context bound)
  )
  discard
  # debug output for one expansion
  # echo "RPC:GEN:innerFormal:\n", innerFormal.treeRepr
  # echo "RPC:GEN:innerProc:\n", innerProc.treeRepr

  # Generate wrapper proc and registration
  result = quote do:
    `paramTypes`
    `innerProc`

    proc `rpcMethod`(pbuf: FastRpcParamsBuffer, context: `ContextType`): FastRpcParamsBuffer {.gcsafe, nimcall.} =
      var `paramsIdent`: `paramTypeName`
      `paramsIdent`.rpcUnpack(pbuf)
      let `ctxPassSym` = context
      let ret: `ReturnType` = `innerCall`
      result = rpcPack(ret)

    register(`router`, `path`, `rpcMethod`)

macro rpcOption*(p: untyped): untyped =
  result = p

macro rpcSetter*(p: untyped): untyped =
  result = p
macro rpcGetter*(p: untyped): untyped =
  result = p

template rpc*(p: untyped): untyped =
  rpcImpl(p, nil, nil)

template rpcPublisher*(args: static[Duration], p: untyped): untyped =
  rpcImpl(p, args, nil)

template rpcThread*(p: untyped): untyped =
  `p`

template rpcSerializer*(p: untyped): untyped =
  # rpcImpl(p, "thread", qarg)
  # static: echo "RPCSERIALIZER:\n", treeRepr p
  rpcImpl(p, "serializer", nil)

macro DefineRpcs*(name: untyped, args: varargs[untyped]) =
  ## annotates that a proc is an `rpcRegistrationProc` and
  ## that it takes the correct arguments. In particular 
  ## the first parameter must be `router: var FastRpcRouter`. 
  ## 
  let
    params = if args.len() >= 2: args[0..^2]
             else: newSeq[NimNode]()
    pbody = args[^1]

  # if router.repr != "var FastRpcRouter":
  #   error("Incorrect definition for a `rpcNamespace`." &
  #   "The first parameter to an rpc registration namespace must be named `router` and be of type `var FastRpcRouter`." &
  #   " Instead got: `" & treeRepr(router) & "`")
  let rname = ident("router")
  result = quote do:
    proc `name`*(`rname`: var FastRpcRouter) =
      `pbody`
  
  var pArgs = result[3]
  for param in params:
    let parg = newIdentDefs(param[0], param[1])
    pArgs.add parg
  echo "PARGS: ", pArgs.treeRepr

macro DefineRpcTaskOptions*[T](name: untyped, args: varargs[untyped]) =
  ## annotates that a proc is an `rpcRegistrationProc` and
  ## that it takes the correct arguments. In particular 
  ## the first parameter must be `router: var FastRpcRouter`. 
  ## 
  let
    params = if args.len() >= 1: args[0..^2]
             else: newSeq[NimNode]()
    pbody = args[^1]

  let rname = ident("router")
  result = quote do:
    proc `name`*(`rname`: var FastRpcRouter) =
      `pbody`
  
  var pArgs = result[3]
  for param in params:
    let parg = newIdentDefs(param[0], param[1])
    pArgs.add parg
  echo "TASK:OPTS:\n", result.repr

macro registerRpcs*(router: var FastRpcRouter,
                    registerClosure: untyped,
                    args: varargs[untyped]) =
  result = quote do:
    `registerClosure`(`router`, `args`) # 

# template startDataStream*(
#         streamProc: untyped,
#         streamThread: untyped,
#         queue: untyped,
#         ): RpcStreamThread[T,U] =
#   var tchan: Chan[TaskOption[U]] = newChan[TaskOption[U]](1)
#   var arg = ThreadArg[T,U](queue: iqueue, chan: tchan)
#   var result: RpcStreamThread[T, U]
#   createThread[ThreadArg[T, U]](result, streamThread, move arg)
#   result

macro registerDatastream*[T,O,R](
              router: var FastRpcRouter,
              name: string,
              serializer: RpcStreamSerializer[T],
              reducer: RpcStreamTask[T, TaskOption[O]],
              queue: InetEventQueue[T],
              option: O,
              optionRpcs: R) =
  echo "registerDatastream: T: ", repr(T)
  result = quote do:
    let serClosure: RpcStreamSerializerClosure =
            `serializer`(`queue`)
    `optionRpcs`(`router`)
    router.register(`name`, `queue`.evt, serClosure)

  echo "REG:DATASTREAM:\n", result.repr
  echo ""

                      
proc getUpdatedOption*[T](chan: TaskOption[T]): Option[T] =
  # chan.tryRecv()
  return some(T())
proc getRpcOption*[T](chan: TaskOption[T]): T =
  # chan.tryRecv()
  return T()


proc rpcReply*[T](context: RpcContext, value: T, kind: FastRpcType): bool =
  ## pack data for the reply
  var packed: FastRpcParamsBuffer = rpcPack(value)
  let res: FastRpcResponse = wrapResponse(context.id, packed, kind)
  var so = MsgBuffer.init(res.result.buf.data.len() + sizeof(res))
  so.pack(res)

template rpcReply*(value: untyped): untyped =
  rpcReply(context, value, Publish)

template rpcPublish*(arg: untyped): untyped =
  rpcReply(context, arg, Publish)
