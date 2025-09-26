import std/json
import std/net
import std/options
import std/os
import std/times
import std/posix

import msgpack4nim
import msgpack4nim/msgpack2json

import ../server/protocol
import ../servertypes

const
  DefaultUdpTimeoutMs* = 1_000

type
  RpcIpAddress* = object
    ipstring*: string
    ipaddr*: IpAddress

  RpcOptions* = object
    nextId*: FastRpcId
    count*: int
    delay*: int
    jsonArg*: string
    ipAddr*: RpcIpAddress
    port*: Port
    udp*: bool
    noresults*: bool
    prettyPrint*: bool
    quiet*: bool
    noprint*: bool
    system*: bool
    subscribe*: bool
    dryRun*: bool
    showstats*: bool
    keepalive*: bool
    receiveTimeoutMs*: int

  RpcResponseKind* = enum
    rrAck
    rrPublish
    rrFinal

  RpcResponseEntry* = object
    kind*: RpcResponseKind
    response*: FastRpcResponse
    raw*: string
    json*: Option[JsonNode]
    error*: Option[FastRpcError]

  RpcCallResult* = object
    callId*: FastRpcId
    payload*: string
    lengthPrefix*: string
    durationMicros*: int64
    responses*: seq[RpcResponseEntry]

  KeepAliveMessage* = object
    raw*: string
    json*: Option[JsonNode]
    parseError*: Option[string]

proc ensureNextId(opts: var RpcOptions) =
  if opts.nextId <= 0:
    opts.nextId = 1

proc setReceiveTimeout(socket: Socket, timeoutMs: int) =
  var timeout: Timeval
  timeout.tv_sec = posix.Time(timeoutMs div 1000)
  timeout.tv_usec = Suseconds(timeoutMs mod 1000 * 1000)

  if setsockopt(socket.getFd(), SOL_SOCKET, SO_RCVTIMEO,
                addr timeout, sizeof(timeout).Socklen) != 0:
    raise newException(OSError, "Failed to set receive timeout")

proc openRpcSocket*(opts: RpcOptions): Socket =
  let domain =
    if opts.ipAddr.ipaddr.family == IpAddressFamily.IPv6:
      Domain.AF_INET6
    else:
      Domain.AF_INET
  let protocol =
    if opts.udp:
      Protocol.IPPROTO_UDP
    else:
      Protocol.IPPROTO_TCP
  let sockType =
    if opts.udp:
      SockType.SOCK_DGRAM
    else:
      SockType.SOCK_STREAM

  result = newSocket(buffered = false,
                     domain = domain,
                     sockType = sockType,
                     protocol = protocol)

  if opts.udp:
    let timeout = if opts.receiveTimeoutMs > 0: opts.receiveTimeoutMs
                  else: DefaultUdpTimeoutMs
    setReceiveTimeout(result, timeout)
  else:
    result.connect(opts.ipAddr.ipstring, opts.port)

proc responseToJson(response: FastRpcResponse): Option[JsonNode] =
  try:
    var resbuf = MsgBuffer.init(response.result.buf.data)
    some(resbuf.toJsonNode())
  except CatchableError:
    none(JsonNode)

proc decodeError(response: FastRpcResponse): Option[FastRpcError] =
  try:
    var resbuf = MsgBuffer.init(response.result.buf.data)
    resbuf.setPosition(0)
    var err: FastRpcError
    resbuf.unpack(err)
    some(err)
  except CatchableError:
    none(FastRpcError)

proc makeEntry(response: FastRpcResponse, raw: string, kind: RpcResponseKind): RpcResponseEntry =
  result = RpcResponseEntry(kind: kind, response: response, raw: raw)
  result.json = responseToJson(response)
  if response.kind == Error:
    result.error = decodeError(response)

proc readResponse(client: Socket, udp: bool): Option[(FastRpcResponse, string)] =
  var response: FastRpcResponse
  if udp:
    var address: IpAddress
    var port: Port
    var msg = newString(65_535)
    let count = client.recvFrom(msg, msg.len(), address, port)
    if count <= 0:
      return none[(FastRpcResponse, string)]()
    msg.setLen(count)
    var rbuff = MsgBuffer.init(msg)
    rbuff.unpack(response)
    return some((response, msg))

  let msgLenBytes = client.recv(2, timeout = -1)
  if msgLenBytes.len() == 0:
    return none[(FastRpcResponse, string)]()
  let msgLen = msgLenBytes.fromStrBe16().int

  var msg = newStringOfCap(msgLen)
  while msg.len < msgLen:
    let chunk = client.recv(msgLen - msg.len, timeout = -1)
    if chunk.len == 0:
      return none[(FastRpcResponse, string)]()
    msg.add(chunk)

  var rbuff = MsgBuffer.init(msg)
  rbuff.unpack(response)
  some((response, msg))

proc execRpc*(client: Socket,
              call: FastRpcRequest,
              opts: var RpcOptions): RpcCallResult {.gcsafe.} =
  ensureNextId(opts)

  var request = call
  request.id = opts.nextId
  inc opts.nextId

  var packer = MsgBuffer.init()
  packer.pack(request)
  let payload = packer.data
  let prefix = if opts.udp: "" else: payload.len().int16.toStrBe16()

  var callResult = RpcCallResult(callId: request.id,
                                 payload: payload,
                                 lengthPrefix: prefix)

  let start = getTime()

  if opts.udp:
    client.sendTo($opts.ipAddr.ipaddr, opts.port, payload)
  else:
    client.send(prefix & payload)

  var responseOpt = readResponse(client, opts.udp)
  if responseOpt.isNone:
    callResult.durationMicros = (getTime() - start).inMicroseconds()
    if opts.delay > 0:
      sleep(opts.delay)
    return callResult

  var (response, raw) = responseOpt.get()

  if opts.subscribe:
    callResult.responses.add(makeEntry(response, raw, rrAck))
    responseOpt = readResponse(client, opts.udp)
    if responseOpt.isNone:
      callResult.durationMicros = (getTime() - start).inMicroseconds()
      if opts.delay > 0:
        sleep(opts.delay)
      return callResult
    (response, raw) = responseOpt.get()

  while response.kind == Publish:
    callResult.responses.add(makeEntry(response, raw, rrPublish))
    responseOpt = readResponse(client, opts.udp)
    if responseOpt.isNone:
      callResult.durationMicros = (getTime() - start).inMicroseconds()
      if opts.delay > 0:
        sleep(opts.delay)
      return callResult
    (response, raw) = responseOpt.get()

  callResult.responses.add(makeEntry(response, raw, rrFinal))
  callResult.durationMicros = (getTime() - start).inMicroseconds()

  if opts.delay > 0:
    sleep(opts.delay)

  callResult

proc recvKeepAlive*(client: Socket,
                    opts: RpcOptions,
                    bufferSize = 4_096): Option[KeepAliveMessage] =
  var buffer = newString(bufferSize)
  var count = 0

  if opts.udp:
    var address: IpAddress
    var port: Port
    count = client.recvFrom(buffer, buffer.len(), address, port)
  else:
    count = client.recv(buffer, buffer.len(), timeout = -1)

  if count <= 0:
    return none(KeepAliveMessage)

  buffer.setLen(count)
  var message = KeepAliveMessage(raw: buffer)
  try:
    message.json = some(buffer.toJsonNode())
  except CatchableError as err:
    message.parseError = some(err.msg)

  some(message)
