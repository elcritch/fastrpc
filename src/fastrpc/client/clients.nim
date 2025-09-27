import std/net
import std/options
import std/times
import std/json

import ../server/protocol
import ../server/rpcdatatypes
import ../utils/msgbuffer
import ../servertypes # for toStrBe16/fromStrBe16 helpers

export protocol
export rpcdatatypes
export msgbuffer

type
  FastRpcClient* = object
    ## Minimal client wrapper. User owns the socket lifecycle.
    socket*: Socket           ## pre-created socket (TCP or UDP)
    udp*: bool                ## true for UDP, false for TCP
    dest*: Option[(string, Port)] ## optional UDP destination if not connected
    nextId*: FastRpcId        ## auto-increment request id

  RpcCallError* = object of CatchableError
    code*: FastErrorCodes
    detail*: string
  RpcTimeoutError* = object of CatchableError

proc `=destroy`*(c: var FastRpcClient) =
  if c.socket != nil and c.socket.getFd().int != -1:
    c.socket.close()
  `=destroy`(c.socket)
  `=destroy`(c.udp)
  `=destroy`(c.dest)
  `=destroy`(c.nextId)

proc newFastRpcClientTcp*(socket: Socket): FastRpcClient =
  ## Create a TCP FastRPC client using an already-connected socket.
  ## TCP uses a 2-byte big-endian length prefix per message.
  FastRpcClient(socket: socket, udp: false, dest: none((string, Port)), nextId: 1)

proc newFastRpcClientUdp*(socket: Socket, host: string, port: Port): FastRpcClient =
  ## Create a UDP FastRPC client. If the socket is not connected, a destination
  ## host/port must be provided to use sendTo.
  FastRpcClient(socket: socket, udp: true, dest: some((host, port)), nextId: 1)

proc newFastRpcClient*(ipAddr: IpAddress, port: Port, udp: bool): FastRpcClient =
  let domain = if ipAddr.family == IpAddressFamily.IPv6: Domain.AF_INET6 else: Domain.AF_INET
  let protocol = if udp: Protocol.IPPROTO_UDP else: Protocol.IPPROTO_TCP
  let sockType = if udp: SOCK_DGRAM else: SOCK_STREAM
  let sock: Socket = newSocket(buffered=false, domain=domain, sockType=sockType, protocol=protocol)
  if udp:
    return newFastRpcClientUdp(sock, $ipAddr, port)
  else:
    return newFastRpcClientTcp(sock)

proc setUdpDestination*(c: var FastRpcClient, host: string, port: Port) =
  ## Update/set the UDP destination for this client.
  c.dest = some((host, port))

when defined(posix):
  import std/posix
  proc setReceiveTimeout*(c: var FastRpcClient, timeoutMs: int) =
    if c.udp: return

    var timeout: Timeval
    timeout.tv_sec = posix.Time(timeoutMs div 1000)
    timeout.tv_usec = Suseconds(timeoutMs mod 1000 * 1000)

    if setsockopt(c.socket.getFd(), SOL_SOCKET, SO_RCVTIMEO,
                  addr timeout, sizeof(timeout).Socklen) != 0:
      raise newException(OSError, "Failed to set receive timeout")

proc nextRequestId(c: var FastRpcClient): FastRpcId =
  if c.nextId <= 0: c.nextId = 1
  result = c.nextId
  inc c.nextId

proc makeRequest*(c: var FastRpcClient,
                  name: string,
                  params: FastRpcParamsBuffer,
                  kind: FastRpcType = Request,
                  system = false): FastRpcRequest =
  ## Build a FastRpcRequest with auto-increment id.
  let rpcKind = (if system: SystemRequest else: kind)
  FastRpcRequest(kind: rpcKind,
                 id: c.nextRequestId(),
                 procName: name,
                 params: params)

proc send*(c: FastRpcClient, req: FastRpcRequest) =
  ## Serialize and send a single FastRPC request on the underlying socket.
  var packer = MsgBuffer.init()
  packer.pack(req)
  let payload = packer.data

  if c.udp:
    if c.dest.isSome:
      let (host, port) = c.dest.get()
      c.socket.sendTo(host, port, payload)
    else:
      ## For UDP, if the socket is connected, a plain send works.
      c.socket.send(payload)
  else:
    let prefix = payload.len().int16.toStrBe16()
    c.socket.send(prefix & payload)

proc recv*(c: FastRpcClient, timeoutMs = -1): Option[FastRpcResponse] =
  ## Receive and decode a single FastRPC response from the socket.
  ## - For UDP: reads one datagram.
  ## - For TCP: reads 2-byte length prefix followed by full payload.
  var response: FastRpcResponse

  if c.udp:
    var ipaddr: IpAddress
    var port: Port
    var msg = newString(65_535)
    let count = c.socket.recvFrom(msg, msg.len(), ipaddr, port)
    if count <= 0:
      return none(FastRpcResponse)
    msg.setLen(count)
    var rbuff = MsgBuffer.init(msg)
    rbuff.unpack(response)
    return some(response)

  # TCP path
  let msgLenBytes = c.socket.recv(2, timeout = timeoutMs)
  if msgLenBytes.len() == 0:
    return none(FastRpcResponse)
  let msgLen = msgLenBytes.fromStrBe16().int

  var msg = newStringOfCap(msgLen)
  while msg.len < msgLen:
    let chunk = c.socket.recv(msgLen - msg.len, timeout = timeoutMs)
    if chunk.len == 0:
      return none(FastRpcResponse)
    msg.add(chunk)

  var rbuff = MsgBuffer.init(msg)
  rbuff.unpack(response)
  some(response)

proc decodeError*(resp: FastRpcResponse): FastRpcError =
  var resbuf = MsgBuffer.init(resp.result.buf.data)
  resbuf.setPosition(0)
  resbuf.unpack(result)

proc callRaw*(c: var FastRpcClient,
              name: string,
              params: FastRpcParamsBuffer,
              system = false,
              timeoutMs = -1,
              skipResponse = false
              ): FastRpcResponse =
  ## Perform a single RPC call and return one response.
  let req = c.makeRequest(name, params, kind = Request, system = system)
  c.send(req)
  if skipResponse:
    return FastRpcResponse(kind: Unsupported, id: req.id, result: FastRpcParamsBuffer())
  let respOpt = c.recv(timeoutMs)
  if respOpt.isNone:
    raise newException(RpcTimeoutError, "No response received")
  return respOpt.get()

proc call*[R](c: var FastRpcClient,
              name: string,
              params: FastRpcParamsBuffer,
              system = false,
              timeoutMs = -1,
              skipResponse = false): R =
  ## Call a method and decode the final result into type R.
  let resp = c.callRaw(name, params, system = system, timeoutMs = timeoutMs, skipResponse = skipResponse)
  case resp.kind
  of Error:
    let err = decodeError(resp)
    var e = newException(RpcCallError, err.msg)
    e.code = err.code
    e.detail = err.msg
    raise e
  of Response:
    var res: R
    res.rpcUnpack(resp.result)
    return res
  else:
    raise newException(IOError, "Unexpected response type: " & $resp.kind)

template call*[R, T](c: var FastRpcClient,
                     name: string,
                     args: T,
                     system = false,
                     timeoutMs = -1,
                     skipResponse = false): R =
  ## Convenience wrapper: pack args automatically using rpcPack.
  call[R](c, name, rpcPack(args), system = system, timeoutMs = timeoutMs, skipResponse = skipResponse)

proc callJson*(c: var FastRpcClient,
               name: string,
               args: JsonNode = %* {},
               system = false,
               timeoutMs = -1,
               skipResponse = false): JsonNode =
  ## JSON-friendly call: pass params as JsonNode, get JsonNode result.
  let resp = c.callRaw(name, rpcPack(args), system = system, timeoutMs = timeoutMs, skipResponse = skipResponse)
  case resp.kind
  of Error:
    let err = decodeError(resp)
    var e = newException(RpcCallError, err.msg)
    e.code = err.code
    e.detail = err.msg
    raise e
  of Response:
    var resbuf = MsgBuffer.init(resp.result.buf.data)
    resbuf.setPosition(0)
    return resbuf.toJsonNode()
  else:
    raise newException(IOError, "Unexpected response type: " & $resp.kind)

proc subscribe*(c: var FastRpcClient,
                name: string,
                args: FastRpcParamsBuffer,
                timeoutMs = -1,
                skipResponse = false): FastRpcId =
  ## Send a subscribe request. Returns the subscription id from the ack.
  let req = c.makeRequest(name, args, kind = Subscribe)
  c.send(req)
  if skipResponse:
    return FastRpcId(req.id)
  let ackOpt = c.recv(timeoutMs)
  if ackOpt.isNone:
    raise newException(RpcTimeoutError, "No subscribe ack received")
  let ack = ackOpt.get()

  if ack.kind == Error:
    let err = decodeError(ack)
    var e = newException(RpcCallError, err.msg)
    e.code = err.code
    e.detail = err.msg
    raise e
  elif ack.kind != Response:
    raise newException(IOError, "Unexpected subscribe ack type: " & $ack.kind)

  # Ack payload is a map like: {"subscription": <id>}
  var resbuf = MsgBuffer.init(ack.result.buf.data)
  resbuf.setPosition(0)
  let j = resbuf.toJsonNode()
  if j.hasKey("subscription"):
    return FastRpcId(j["subscription"].getInt)
  else:
    # Fallback: sometimes servers might use the request id as subscription id
    return FastRpcId(ack.id)

template subscribe*(c: var FastRpcClient,
                    name: string,
                    args: JsonNode,
                    timeoutMs = -1,
                    skipResponse = false): FastRpcId =
  ## JSON convenience wrapper for subscribe.
  subscribe(c, name, rpcPack(args), timeoutMs, skipResponse)

proc recvPublish*(c: FastRpcClient,
                  timeoutMs = -1): Option[(FastRpcId, FastRpcParamsBuffer)] =
  ## Receive the next publish message. Returns (subscriptionId, payload).
  let ropt = c.recv(timeoutMs)
  if ropt.isNone: return none((FastRpcId, FastRpcParamsBuffer))
  let r = ropt.get()
  if r.kind != Publish:
    return none((FastRpcId, FastRpcParamsBuffer))
  some((FastRpcId(r.id), r.result))

proc recvPublishJson*(c: FastRpcClient,
                      timeoutMs = -1): Option[(FastRpcId, JsonNode)] =
  ## Receive the next publish message and decode to JsonNode.
  let popt = c.recvPublish(timeoutMs)
  if popt.isNone: return none((FastRpcId, JsonNode))
  let (sid, params) = popt.get()
  var resbuf = MsgBuffer.init(params.buf.data)
  resbuf.setPosition(0)
  some((sid, resbuf.toJsonNode()))
