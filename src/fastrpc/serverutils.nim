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

