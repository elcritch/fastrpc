import sets

import std/logging
import ../utils/inettypes
import ../servertypes
import ../serverutils

import hashes

const EchoBufferSize = 1400
type 
  EchoOpts = ref object
    knownClients*: HashSet[(InetAddress, Socket)]
    prompt*: string
    bufferSize*: int

proc hash*(sock: Socket): Hash = hash(sock.getFd())

proc sendAllClients*(srv: ServerInfo[EchoOpts],
                     sourceClient: Socket,
                     message: string,
                     ) =

  var msg = srv.impl.opts.prompt & message & "\r\n"

  # tcp clients
  let fdkind = srv.selector.getData(sourceClient.getFd())
  let stype: SockType = fdkind.getSockType().get()

  for cfd, client in srv.receivers:
    if stype == SockType.SOCK_STREAM:
      client.send(msg)

  debug("sendAllClients:", $srv.impl.opts.knownClients)
  # udp clients
  for (ia, client) in srv.impl.opts.knownClients:
    client.sendTo(ia.host, ia.port, msg)

proc echoReadHandler*(srv: ServerInfo[EchoOpts],
                      sourceClient: Socket,
                      ) =
  let stype = srv.getSockType(sourceClient)
  debug("echoReadHandler:", "sourceClient:", sourceClient.getFd().int, "socktype:", stype)
  var
    message = newString(EchoBufferSize)

  case stype:
  of SockType.SOCK_STREAM:
    discard sourceClient.recv(message, EchoBufferSize)

  of SockType.SOCK_DGRAM:
    var
      address: IpAddress
      port: Port

    discard sourceClient.recvFrom(message, message.len(), address, port)
    srv.impl.opts.knownClients.incl((InetAddress(host: address, port: port), sourceClient))

  else:
    raise newException(ValueError, "unhandled socket type: " & $stype)

  if message == "":
    raise newException(InetClientDisconnected, "")
  else:
    debug("received from client:", message)

    srv.sendAllClients(sourceClient, message)


proc newEchoServer*(prefix = "", selfEchoDisable = false): Server[EchoOpts] =
  new(result)
  result.readHandler = echoReadHandler
  result.writeHandler = nil 
  result.opts = new(EchoOpts) 
  result.opts.knownClients = initHashSet[(InetAddress, Socket)]()
  result.opts.prompt = prefix
  result.opts.bufferSize = 1400
