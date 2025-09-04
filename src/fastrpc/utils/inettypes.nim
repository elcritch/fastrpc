import nativesockets, net, selectors, posix, tables, hashes

export nativesockets, net, selectors, posix, tables

import json
export json

import threading/smartptrs
export smartptrs

type
  InetAddress* = object
    # Combined type for a remote IP address and service port
    host*: IpAddress
    port*: Port
    protocol*: net.Protocol
    socktype*: net.SockType

  CanMsgId* = object
    iface: int
    msgid: int

  InetClientType* = enum
    clEmpty,
    clSocket,
    clAddress,
    clCanBus

  InetClientObj* = object
    # Combined type for a remote IP address and service port
    case kind*: InetClientType  # the `kind` field is the discriminator
    of clEmpty:
      discard
    of clSocket:
      fd*: SocketHandle
    of clAddress:
      sfd*: SocketHandle
      host*: IpAddress
      port*: Port
    of clCanBus:
      msgid*: CanMsgId

    protocol*: net.Protocol
    socktype*: net.SockType

  InetClientHandle* = ConstPtr[InetClientObj]

type 
  InetClientDisconnected* = object of OSError
  InetClientError* = object of OSError

proc contains*(a: InetClientHandle, fd: SocketHandle): bool =
  let ao: InetClientObj = a[]
  case ao.kind:
  of clEmpty: discard
  of clAddress: discard
  of clCanBus: discard
  of clSocket: result = ao.fd == fd

proc contains*(a: InetClientHandle, arg: (IpAddress, Port)): bool =
  let ao: InetClientObj = a[]
  case ao.kind:
  of clEmpty: discard
  of clCanBus: discard
  of clSocket: discard
  of clAddress: result = ao.host == arg[0] and ao.port == arg[1]

proc `==`*(a, b: InetClientHandle): bool =
  let ao: InetClientObj = a[]
  let bo: InetClientObj = b[]
  if ao.kind != bo.kind: return false
  case ao.kind:
  of clEmpty:
    discard
  of clSocket:
    result = ao.fd == bo.fd
  of clAddress:
    result = ao.host == bo.host and ao.port == bo.port
  of clCanBus:
    result = ao.msgid == bo.msgid

proc hash*(hdl: InetClientHandle): Hash =
  ## Computes a Hash from `x`.
  var h: Hash = 0
  let obj: InetClientObj = hdl[]
  h = h !& hash(obj.kind)
  case obj.kind:
  of clEmpty:
    discard
  of clSocket:
    h = h !& hash(obj.fd)
  of clAddress:
    h = h !& hash(obj.host)
    h = h !& hash(obj.port)
  of clCanBus:
    h = h !& hash(obj.msgid)
  result = !$h


proc newInetAddr*(host: string, port: int, protocol = net.IPPROTO_TCP): InetAddress =
  result.host = parseIpAddress(host)
  result.port = Port(port)
  result.protocol = protocol
  result.socktype = protocol.toSockType()

proc inetDomain*(inetaddr: InetAddress): nativesockets.Domain = 
  case inetaddr.host.family:
  of IpAddressFamily.IPv4:
    result = Domain.AF_INET
  of IpAddressFamily.IPv6:
    result = Domain.AF_INET6 

proc empty*(x: typedesc[InetClientHandle]): InetClientHandle =
  result = newConstPtr InetClientObj(
    kind: clEMpty,
  )

proc newClientHandle*(fd: SocketHandle, protocol = net.IPPROTO_TCP): InetClientHandle =
  result = newConstPtr InetClientObj(
    kind: clSocket,
    fd: fd,
    protocol: protocol,
    socktype: protocol.toSockType(),
  )

proc newClientHandle*(host: IpAddress, port: Port, fd = SocketHandle(-1), protocol = net.IPPROTO_UDP): InetClientHandle =
  result = newConstPtr InetClientObj(
    kind: clAddress,
    sfd: fd,
    host: host,
    port: port,
    protocol: protocol,
    socktype: protocol.toSockType(),
  )

proc newClientHandle*(host: string, port: int, fd = SocketHandle(-1), protocol = net.IPPROTO_UDP): InetClientHandle =
  result = newConstPtr InetClientObj(
    kind: clAddress,
    sfd: fd,
    host: parseIpAddress(host),
    port: Port(port),
    protocol: protocol,
    socktype: protocol.toSockType(),
  )

proc newClientHandle*(msgid: CanMsgId, protocol = net.IPPROTO_RAW): InetClientHandle =
  result = newConstPtr InetClientObj(
    kind: clCanBus,
    msgid: msgid,
    protocol: protocol,
    socktype: protocol.toSockType(),
  )
