import posix
import nativesockets
import os
import net


when false:
  proc bindInterface*(sock: Socket) =
    when defined(macos):
      let idx = if_nametoindex("en0")
      setsockopt(sock.getFd(), IPPROTO_IP, IP_BOUND_IF, addr idx, sizeof(idx))
    elif defined(linux):
      let idx = if_nametoindex("en0")
      let res = setsockopt(sock.getFd(), posix.IPPROTO_IP, SO_BINDTODEVICE, addr idx, sizeof(idx).SockLen)

when defined(linux) or defined(macosx):

  proc isClosed(socket: Socket): bool =
    socket.getFd() == osInvalidSocket

  proc sendTo*(socket: Socket, address: IpAddress, port: Port,
              data: string, flags = 0'i32): int {.
                discardable, tags: [WriteIOEffect].} =
    ## This proc sends `data` to the specified `IpAddress` and returns
    ## the number of bytes written.
    ##
    ## Generally for use with connection-less (UDP) sockets.
    ##
    ## If an error occurs an OSError exception will be raised.
    ##
    ## This is the high-level version of the above `sendTo` function.
    assert(socket.getProtocol() != Protocol.IPPROTO_TCP, "Cannot `sendTo` on a TCP socket")
    assert(not socket.isClosed(), "Cannot `sendTo` on a closed socket")

    var sa: Sockaddr_storage
    var sl: SockLen
    toSockAddr(address, port, sa, sl)
    result = sendto(socket.getFd(), cstring(data), data.len().cint, flags.cint,
                    cast[ptr SockAddr](addr sa), sl)

    if result == -1'i32:
      let osError = osLastError()
      raiseOSError(osError)

  proc recvFrom*(socket: Socket, data: var string, length: int,
                address: var IpAddress, port: var Port, flags = 0'i32): int {.
                tags: [ReadIOEffect].} =
    ## Receives data from `socket`. This function should normally be used with
    ## connection-less sockets (UDP sockets). The source address of the data
    ## packet is stored in the `address` argument as either a string or an IpAddress.
    ##
    ## If an error occurs an OSError exception will be raised. Otherwise the return
    ## value will be the length of data received.
    ##
    ## .. warning:: This function does not yet have a buffered implementation,
    ##   so when `socket` is buffered the non-buffered implementation will be
    ##   used. Therefore if `socket` contains something in its buffer this
    ##   function will make no effort to return it.
    template adaptRecvFromToDomain(sockAddress: untyped, domain: Domain) =
      var addrLen = sizeof(sockAddress).SockLen
      result = recvfrom(socket.getFd(), cstring(data), length.cint, flags.cint,
                        cast[ptr SockAddr](addr(sockAddress)), addr(addrLen))

      if result != -1:
        data.setLen(result)

        when typeof(address) is string:
          address = getAddrString(cast[ptr SockAddr](addr(sockAddress)))
          when domain == Domain.AF_INET6:
            port = ntohs(sockAddress.sin6_port).Port
          else:
            port = ntohs(sockAddress.sin_port).Port
        else:
          data.setLen(result)
          sockAddress.fromSockAddr(addrLen, address, port)
      else:
        raiseOSError(osLastError())

    assert(socket.getProtocol() != Protocol.IPPROTO_TCP, "Cannot `recvFrom` on a TCP socket")
    # TODO: Buffered sockets
    data.setLen(length)

    case socket.getDomain()
    of Domain.AF_INET6:
      var sockAddress: Sockaddr_in6
      adaptRecvFromToDomain(sockAddress, Domain.AF_INET6)
    of Domain.AF_INET:
      var sockAddress: Sockaddr_in
      adaptRecvFromToDomain(sockAddress, Domain.AF_INET)
    else:
      raise newException(ValueError, "Unknown socket address family")

