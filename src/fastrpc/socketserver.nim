import std/nativesockets
import std/net
import std/selectors
import std/tables
import std/posix

import ./utils/inettypes
import ./utils/logging

import servertypes

export servertypes
export inettypes

import strutils, sequtils

template withExecHandler(pname, handlerProc, blk: untyped) =
  ## check handlerProc isn't nil and handle any unexpected errors
  try:
    if handlerProc != nil:
      let `pname` {.inject.} = handlerProc
      `blk`
  except OSError as err:
    info("[SocketServer]::", "unhandled error from server handler: ", repr `handlerProc`)
    info("[SocketServer]:: error name: ", $err.name, " message: ", $err.msg, " code: ", $err.errorCode)
    for se in err.getStackTraceEntries():
      info("[SocketServer]:: error stack trace: ", $se.filename, ":", $se.line, " ", $se.procname)
    srv.errorCount.inc()
  except CatchableError, Defect, Exception:
    let err = getCurrentException()
    info("[SocketServer]::", "unhandled error from server handler: ", repr `handlerProc`)
    info("[SocketServer]:: error name: ", $err.name, " message: ", $err.msg)
    for se in err.getStackTraceEntries():
      info("[SocketServer]:: error stack trace: ", $se.filename, ":", $se.line, " ", $se.procname)
    srv.errorCount.inc()

template withReceiverSocket*(name: untyped, fd: SocketHandle, modname: string, blk: untyped) =
  ## handle checking receiver sockets
  try:
    let `name` {.inject.} = srv.receivers[fd]
    `blk`
  except KeyError:
    debug("[SocketServer]::", modname, ":missing socket: ", repr(fd), "skipping")

template withClientSocketErrorCleanups*(socktable: Table[SocketHandle, Socket],
                                        key: ReadyKey,
                                        blk: untyped) =
  ## handle client socket errors / reading / writing / etc
  try:
    `blk`
  except InetClientDisconnected:
    var client: Socket
    discard `socktable`.pop(key.fd.SocketHandle, client)
    srv.selector.unregister(key.fd)
    discard posix.close(key.fd.cint)
    error("receiver socket disconnected: fd: ", $key.fd)
  except InetClientError:
    `socktable`.del(key.fd.SocketHandle)
    srv.selector.unregister(key.fd)
    discard posix.close(key.fd.cint)
    error("receiver socket rx/tx error: ", $(key.fd))


## ============ Socket Server Core Functions ============ ##

proc processEvents[T](srv: ServerInfo[T], selected: ReadyKey) = 
  log(lvlDebug, "[SocketServer]::", "processUserEvents:", "selected:fd:", selected.fd)
  withExecHandler(eventHandler, srv.impl.eventHandler):
    let evt: SelectEvent = srv.getEvent(selected.fd)
    log(lvlDebug, "[SocketServer]::", "processUserEvents:", "userEvent:", repr evt)
    # let queue = srv.queues[evt]

    withClientSocketErrorCleanups(srv.receivers, selected):
      eventHandler(srv, evt)

proc processWrites[T](srv: ServerInfo[T], selected: ReadyKey) = 
  log(lvlDebug, "[SocketServer]::", "processWrites:", "selected:fd:", selected.fd)
  withExecHandler(writeHandler, srv.impl.writeHandler):
    withReceiverSocket(sourceClient, selected.fd.SocketHandle, "processWrites"):
      withClientSocketErrorCleanups(srv.receivers, selected):
        writeHandler(srv, sourceClient)

proc processReads[T](srv: ServerInfo[T], selected: ReadyKey) = 
  log(lvlDebug, "[SocketServer]::", "\n")
  log(lvlDebug, "[SocketServer]::", "processReads:", "selected:fd:", selected.fd)
  debug("[SocketServer]::", "processReads:", "listners:fd:",
            srv.listners.keys().toSeq().mapIt(it.int()).repr())
  log(lvlDebug, "[SocketServer]::", "processReads:", "receivers:fd:",
            srv.receivers.keys().toSeq().mapIt(it.int()).repr())

  if srv.listners.hasKey(selected.fd.SocketHandle):
    let server = srv.listners[selected.fd.SocketHandle]
    log(lvlDebug, "process connect on listner:", "fd:", selected.fd,
              "srvfd:", server.getFd().int)
    if SocketHandle(selected.fd) == server.getFd():
      var client: Socket = new(Socket)
      server.accept(client)
      client.getFd().setBlocking(false)
      srv.receivers[client.getFd()] = client
      let id: int = client.getFd().int
      log(lvlDebug, "client connected:", "fd:", id)
      registerHandle(srv.selector, client.getFd(), {Event.Read}, initFdKind(SOCK_STREAM))
  elif srv.receivers.hasKey(SocketHandle(selected.fd)):
    log(lvlDebug, "srv client:", "fd:", selected.fd)
    withExecHandler(readHandler, srv.impl.readHandler):
      withReceiverSocket(sourceClient, selected.fd.SocketHandle, "processReads"):
        withClientSocketErrorCleanups(srv.receivers, selected):
          readHandler(srv, sourceClient) 
  else:
    raise newException(OSError, "unknown socket type: fd: " & repr selected)

const
  FrpcSocketServerAlloStatsLvl {.strdefine.}: string = "lvlDebug"
  ssAllocStatsLvl = parseEnum[logging.Level](FrpcSocketServerAlloStatsLvl)

proc startSocketServer*[T](ipaddrs: openArray[InetAddress],
                           serverImpl: Server[T]) =
  # Setup and run a new SocketServer.
  var select: Selector[FdKind] = newSelector[FdKind]()
  var listners = newSeq[Socket]()
  var receivers = newSeq[Socket]()

  info "[SocketServer]::", "starting"
  for ia in ipaddrs:
    info "[SocketServer]::", "creating socket on: ",
            " ip: ", $ia.host, " port: ", $ia.port, " domain: ", $ia.inetDomain(),
            " sockType: ", $ia.socktype, " protocol: ", $ia.protocol

    var socket = newSocket(
      domain=ia.inetDomain(),
      sockType=ia.socktype,
      protocol=ia.protocol,
      buffered = false
    )
    debug "[SocketServer]::", "started: ", "fd: ", socket.getFd().int, "domain: ", $ia.inetDomain(), "socktype: ", $ia.socktype, "protocol: ", $ia.protocol

    socket.setSockOpt(OptReuseAddr, true)
    socket .getFd().setBlocking(false)
    socket.bindAddr(ia.port)

    var evts: set[Event]
    var stype: SockType

    if ia.protocol in {Protocol.IPPROTO_TCP}:
      socket.listen()
      listners.add(socket)
      stype = SOCK_STREAM
      evts = {Event.Read}
    elif ia.protocol in {Protocol.IPPROTO_UDP}:
      receivers.add(socket)
      stype = SOCK_DGRAM
      evts = {Event.Read}
    else:
      raise newException(ValueError, "unhandled protocol: " & $ia.protocol)

    registerHandle(select, socket.getFd(), evts, initFdKind(stype))
  
  for event in serverImpl.events:
    debug "[SocketServer]::", "userEvent:register:", repr(event)
    registerEvent(select, event, initFdKind(event))

  var srv = newServerInfo[T](serverImpl, select, listners, receivers)

  while true:
    block: # logAllocStats(ssAllocStatsLvl):
      var keys: seq[ReadyKey] = select.select(-1)
      debug "[SocketServer]::", "keys:", repr(keys)
    
      for key in keys:
        debug "[SocketServer]::", "key:", repr(key)
        if Event.Read in key.events:
            srv.processReads(key)
        if Event.User in key.events:
            srv.processEvents(key)
        if Event.Write in key.events:
            srv.processWrites(key)
      
      if serverImpl.postProcessHandler != nil:
        serverImpl.postProcessHandler(srv, keys)

  
  select.close()
  for listner in srv.listners.values():
    listner.close()