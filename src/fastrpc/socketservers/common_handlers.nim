import sugar

import mcu_utils/logging
import mcu_utils/msgbuffer

import mcu_utils/inettypes


proc senderClosure*(sourceClient: Socket): SocketClientSender =
  var lenBuf = newString(2)
  capture sourceClient:
    result =
      proc (data: string): bool =
        try:
          lenBuf.toStrBe16(data.len().int16)
          sourceClient.sendSafe(lenBuf & data)
          return true
        except OSError:
          raise newException(InetClientDisconnected, "client error")
        except Exception as err:
          logException(err, "socker sender:", lvlError)
          return false

proc senderClosure*(sourceClient: Socket, host: IpAddress, port: Port): SocketClientSender =
  capture sourceClient, host, port:
    result =
      proc (data: string): bool =
        try:
          sourceClient.sendTo(host, port, data)
          return true
        except OSError:
          raise newException(InetClientDisconnected, "client error")
        except Exception as err:
          logException(err, "socket sender:", lvlError)
          return false

template customPacketRpcHandler*(handlerName, rpcExec: untyped): untyped =

  proc `handlerName`*[T](srv: SocketServerInfo[T],
                         result: ReadyKey,
                         sourceClient: Socket,
                         sourceType: SockType,
                         data: T) =
    var
      buffer = MsgBuffer.init(data.bufferSize)
      host: IpAddress
      port: Port

    buffer.setPosition(0)
    var sender: SocketClientSender

    # Get network data
    if sourceType == SockType.SOCK_STREAM:
      discard sourceClient.recv(buffer.data, data.bufferSize)
      if buffer.data == "":
        raise newException(InetClientDisconnected, "")
      let
        msglen = buffer.readUintBe16().int
      if buffer.data.len() != 2 + msglen:
        raise newException(OSError, "invalid length: read: " &
                           $buffer.data.len() & " expect: " & $(2 + msglen))
      sender = senderClosure(sourceClient)
    elif sourceType == SockType.SOCK_DGRAM:
      discard sourceClient.recvFrom(buffer.data, buffer.data.len(), host, port)
      sender = senderClosure(sourceClient, host, port)
    else:
      raise newException(ValueError, "unhandled socket type: " & $sourceType)

    # process rpc
    var response = `rpcExec`(data.router, move buffer, sender)

    # logDebug("msg: data: ", repr(response))
    discard sender(response)

