import sets

import std/logging
import ../utils/inettypes
import ../servertypes

type 
  EchoOpts = ref object
    knownClients: HashSet[InetAddress]
    prompt: string
    selfEchoDisable: bool

proc echoUdpReadHandler*(srv: ServerInfo[EchoOpts],
                         sourceClient: Socket,
                         ) =
  var
    message = newString(1400)
    address: IpAddress
    port: Port

  discard sourceClient.recvFrom(message, message.len(), address, port)

  if message == "":
    raise newException(InetClientDisconnected, "")
  else:
    srv.impl.opts.knownClients.incl(InetAddress(host: address, port: port))
    debug("received from client:", message)

    var msg = srv.impl.opts.prompt & message & "\r\n"
    for ia in srv.impl.opts.knownClients:
      sourceClient.sendTo(ia.host, ia.port, msg)

proc newEchoUdpServer*(prefix = "", selfEchoDisable = false): Server[EchoOpts] =
  new(result)
  result.readHandler = echoUdpReadHandler
  result.writeHandler = nil 
  result.opts = new(EchoOpts) 
  result.opts.knownClients = initHashSet[InetAddress]()
  result.opts.prompt = prefix
  result.opts.selfEchoDisable = selfEchoDisable 
