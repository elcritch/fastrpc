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

  RpcRequestContext* = object
    request*: FastRpcRequest
    payload*: string
    lengthPrefix*: string

  RpcResponseKind* = enum
    rrAck
    rrPublish
    rrFinal

  RawRpcResponse* = object
    response*: FastRpcResponse
    raw*: string

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

proc prepareRpcRequest*(call: FastRpcRequest, opts: var RpcOptions): RpcRequestContext =
  ensureNextId(opts)

  var request = call
  request.id = opts.nextId
  inc opts.nextId

  var packer = MsgBuffer.init()
  packer.pack(request)
  let payload = packer.data
  let prefix = if opts.udp: "" else: payload.len().int16.toStrBe16()

  RpcRequestContext(request: request,
                    payload: payload,
                    lengthPrefix: prefix)

proc transmitRpc*(client: Socket,
                  ctx: RpcRequestContext,
                  opts: RpcOptions) =
  if opts.udp:
    client.sendTo($opts.ipAddr.ipaddr, opts.port, ctx.payload)
  else:
    client.send(ctx.lengthPrefix & ctx.payload)

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

proc responseToJson*(response: FastRpcResponse): Option[JsonNode] =
  try:
    var resbuf = MsgBuffer.init(response.result.buf.data)
    some(resbuf.toJsonNode())
  except CatchableError:
    none(JsonNode)

proc decodeError*(response: FastRpcResponse): Option[FastRpcError] =
  try:
    var resbuf = MsgBuffer.init(response.result.buf.data)
    resbuf.setPosition(0)
    var err: FastRpcError
    resbuf.unpack(err)
    some(err)
  except CatchableError:
    none(FastRpcError)

proc toResponseEntry*(raw: RawRpcResponse,
                      kind: RpcResponseKind,
                      decodeJson = true,
                      decodeErrors = true): RpcResponseEntry =
  result = RpcResponseEntry(kind: kind,
                            response: raw.response,
                            raw: raw.raw)
  if decodeJson:
    result.json = responseToJson(raw.response)
  if decodeErrors and raw.response.kind == Error:
    result.error = decodeError(raw.response)

proc readRawResponse*(client: Socket, udp: bool): Option[RawRpcResponse] =
  var response: FastRpcResponse
  if udp:
    var address: IpAddress
    var port: Port
    var msg = newString(65_535)
    let count = client.recvFrom(msg, msg.len(), address, port)
    if count <= 0:
      return none(RawRpcResponse)
    msg.setLen(count)
    var rbuff = MsgBuffer.init(msg)
    rbuff.unpack(response)
    return some(RawRpcResponse(response: response, raw: msg))

  let msgLenBytes = client.recv(2, timeout = -1)
  if msgLenBytes.len() == 0:
    return none(RawRpcResponse)
  let msgLen = msgLenBytes.fromStrBe16().int

  var msg = newStringOfCap(msgLen)
  while msg.len < msgLen:
    let chunk = client.recv(msgLen - msg.len, timeout = -1)
    if chunk.len == 0:
      return none(RawRpcResponse)
    msg.add(chunk)

  var rbuff = MsgBuffer.init(msg)
  rbuff.unpack(response)
  some(RawRpcResponse(response: response, raw: msg))

proc collectPublishRawResponses*(client: Socket,
                                 opts: RpcOptions,
                                 initial: RawRpcResponse): (seq[RawRpcResponse], Option[RawRpcResponse]) =
  var publishes: seq[RawRpcResponse] = @[]
  var current = initial

  if current.response.kind != Publish:
    return (publishes, some(current))

  while true:
    publishes.add(current)

    let nextOpt = readRawResponse(client, opts.udp)
    if nextOpt.isNone:
      return (publishes, none(RawRpcResponse))

    current = nextOpt.get()
    if current.response.kind != Publish:
      return (publishes, some(current))

proc rawResponseToJson*(raw: RawRpcResponse): Option[JsonNode] =
  responseToJson(raw.response)

proc rawResponseError*(raw: RawRpcResponse): Option[FastRpcError] =
  decodeError(raw.response)

proc execRpc*(client: Socket,
              call: FastRpcRequest,
              opts: var RpcOptions,
              decodeJson = true,
              decodeErrors = true): RpcCallResult {.gcsafe.} =
  let ctx = prepareRpcRequest(call, opts)

  var callResult = RpcCallResult(callId: ctx.request.id,
                                 payload: ctx.payload,
                                 lengthPrefix: ctx.lengthPrefix)

  let start = getTime()
  transmitRpc(client, ctx, opts)

  var responseOpt = readRawResponse(client, opts.udp)
  if responseOpt.isNone:
    callResult.durationMicros = (getTime() - start).inMicroseconds()
    if opts.delay > 0:
      sleep(opts.delay)
    return callResult

  var raw = responseOpt.get()

  if opts.subscribe:
    callResult.responses.add(toResponseEntry(raw, rrAck, decodeJson, decodeErrors))
    responseOpt = readRawResponse(client, opts.udp)
    if responseOpt.isNone:
      callResult.durationMicros = (getTime() - start).inMicroseconds()
      if opts.delay > 0:
        sleep(opts.delay)
      return callResult
    raw = responseOpt.get()

  if raw.response.kind == Publish:
    let (publishes, finalOpt) = collectPublishRawResponses(client, opts, raw)
    for publish in publishes:
      callResult.responses.add(toResponseEntry(publish, rrPublish, decodeJson, decodeErrors))

    if finalOpt.isNone:
      callResult.durationMicros = (getTime() - start).inMicroseconds()
      if opts.delay > 0:
        sleep(opts.delay)
      return callResult

    raw = finalOpt.get()

    if raw.response.kind == Publish:
      # When the stream ends without a terminal message, treat it like an early exit.
      callResult.durationMicros = (getTime() - start).inMicroseconds()
      if opts.delay > 0:
        sleep(opts.delay)
      return callResult

  callResult.responses.add(toResponseEntry(raw, rrFinal, decodeJson, decodeErrors))
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
