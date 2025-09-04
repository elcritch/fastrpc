import std/endians
import std/sugar
import std/oserrors
import std/net
import std/options

import ./utils/logging
import ./utils/msgbuffer
import ./utils/inettypes

import server/rpcdatatypes

export options

type
  Server*[T] = ref object
    opts*: T
    # queues*: seq[InetMsgQueue]
    readHandler*: ServerHandler[T]
    writeHandler*: ServerHandler[T]
    eventHandler*: EventHandler[T]
    events*: seq[SelectEvent]
    postProcessHandler*: ServerProcessor[T]

  ServerInfo*[T] = ref object 
    ## Represents type for the select/epoll based socket server
    impl*: Server[T]
    selector*: Selector[FdKind]
    listners*: Table[SocketHandle, Socket]
    receivers*: Table[SocketHandle, Socket]
    errorCount*: uint64

  FdKind* = object
    case isQueue*: bool
    of true:
      evt: SelectEvent
    of false:
      stype: SockType

  ServerHandler*[T] = proc (srv: ServerInfo[T],
                            sock: Socket,
                            ) {.nimcall.}

  EventHandler*[T] = proc (srv: ServerInfo[T],
                            # queue: InetMsgQueue,
                            evt: SelectEvent,
                            ) {.nimcall.}

  ServerProcessor*[T] = proc (srv: ServerInfo[T],
                              results: seq[ReadyKey],
                              ) {.nimcall.}

  SocketClientMessage* = ref object
    ss: MsgBuffer

proc getEvtOpt*(fdkind: FdKind): Option[SelectEvent] =
  if fdkind.isQueue: result = some(fdkind.evt)
proc getSockTypeOpt*(fdkind: FdKind): Option[SockType] =
  if not fdkind.isQueue: result = some(fdkind.stype)

proc initFdKind*(stype: SockType): FdKind =
  result = FdKind(isQueue: false, stype: stype)
proc initFdKind*(evt: SelectEvent): FdKind =
  result = FdKind(isQueue: true, evt: evt)

proc getEvent*[T](srv: ServerInfo[T], sock: SocketHandle | int): SelectEvent =
  let fdkind = srv.selector.getData(sock)
  if fdkind.isQueue:
    return fdkind.evt
  else:
    raise newException(KeyError, "no SelectEvent data")
proc getEvent*[T](srv: ServerInfo[T], sock: Socket): SelectEvent =
  getEvent(srv, sock.getFd())

proc getSockType*[T](srv: ServerInfo[T], sock: SocketHandle | int): SockType =
  let fdkind = srv.selector.getData(sock)
  if not fdkind.isQueue:
    return fdkind.stype
  else:
    raise newException(KeyError, "no SelectEvent data")
proc getSockType*[T](srv: ServerInfo[T], sock: Socket): SockType =
  getSockType(srv, sock.getFd())

proc getSockType*(fdkind: FdKind): Option[SockType] =
  if not fdkind.isQueue: result = some(fdkind.stype)

proc getOpts*[T](srv: ServerInfo[T]): T =
  result = srv.impl.opts

proc newServerInfo*[T](
          serverImpl: Server[T],
          selector: Selector[FdKind],
          listners: seq[Socket],
          receivers: seq[Socket],
        ): ServerInfo[T] = 
  ## setup server info
  result = new(ServerInfo[T])
  result.impl = serverImpl
  result.selector = selector
  result.listners = initTable[SocketHandle, Socket]()
  result.receivers = initTable[SocketHandle, Socket]()
  # result.queues = initTable[SelectEvent, InetMsgQueue]()

  # handle socket based listners (e.g. tcp)
  for listner in listners:
    result.listners[listner.getFd()] = listner
  # handle any packet receiver's (e.g. udp, can)
  for receiver in receivers:
    result.receivers[receiver.getFd()] = receiver
  # for queue in queues:
    # result.queues[queue.evt] = queue 

proc sendSafe*(socket: Socket, data: string) =
  # Checks for disconnect errors when sending
  # This makes it easy to handle dirty disconnects
  try:
    socket.send(data)
  except OSError as err:
    if err.errorCode == ENOTCONN:
      var etcp = newException(InetClientDisconnected, "")
      etcp.errorCode = err.errorCode
      raise etcp
    else:
      raise err

proc sendChunks*(sourceClient: Socket, rmsg: string, chunksize: int) =
  let rN = rmsg.len()
  log(lvlDebug, "rpc handler send client: bytes:", rN)
  var i = 0
  while i < rN:
    var j = min(i + chunksize, rN) 
    var sl = rmsg[i..<j]
    sourceClient.sendSafe(move sl)
    i = j

proc toStrBe16*(str: var string, ln: int16) =
  var sz: int32 = ln.int16
  bigEndian16(str.cstring(), addr sz)
proc toStrBe16*(ln: int16): string =
  result = newString(2)
  result.toStrBe16(ln)
proc fromStrBe16*(datasz: string): int16 =
  assert datasz.len() >= 2
  bigEndian16(addr result, datasz.cstring())

proc newSocketPair*(sockType: SockType = SockType.SOCK_STREAM,
                    protocol: Protocol = Protocol.IPPROTO_IP,
                    domain: Domain = Domain.AF_UNIX,
                    buffered = true,
                   ): (Socket, Socket) =
  ## create socket pairing 

  log(lvlDebug, "newSocketPair: ", [toInt(domain), toInt(sockType), toInt(protocol)])
  var socketFds: array[2, cint]
  let status = posix.socketpair(
                             toInt(domain),
                             toInt(sockType),
                             toInt(protocol),
                             socketFds)
  if status != 0: 
    raise newException(OSError, "error making socket pair: " &
      osErrorMsg(OSErrorCode(status)))

  result[0] = newSocket(SocketHandle(socketFds[0]), domain,
                        sockType, protocol, buffered)
  result[1] = newSocket(SocketHandle(socketFds[1]), domain,
                        sockType, protocol, buffered)
