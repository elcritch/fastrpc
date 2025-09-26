import std/terminal
import std/colors
import std/net
import std/posix

export terminal, colors

enableTrueColors()
proc print*(text: varargs[string]) =
  stdout.write(text)
  stdout.write("\n")
  stdout.flushFile()

proc print*(color: Color, text: varargs[string]) =
  stdout.setForegroundColor(color)

  stdout.write text
  stdout.write "\n"
  stdout.setForegroundColor(fgDefault)
  stdout.flushFile()

var totalTime = 0'i64
var totalCalls = 0'i64

var
  id*: int = 1
  allTimes* = newSeq[int64]()

template timeBlock*[T](n: string, opts: T, blk: untyped): untyped =
  let t0 = getTime()
  blk

  let td = getTime() - t0
  if not opts.quiet and not opts.noprint:
    print colGray, "[took: ", $(td.inMicroseconds().float() / 1e3), " millis]"
  totalCalls.inc()
  totalTime = totalTime + td.inMicroseconds()
  allTimes.add(td.inMicroseconds())
  

proc setReceiveTimeout*(socket: Socket, timeoutMs: int) =
  var timeout: Timeval
  timeout.tv_sec = posix.Time(timeoutMs div 1000)
  timeout.tv_usec = Suseconds(timeoutMs mod 1000 * 1000)
  
  if setsockopt(socket.getFd(), SOL_SOCKET, SO_RCVTIMEO, 
                addr timeout, sizeof(timeout).Socklen) != 0:
    raise newException(OSError, "Failed to set receive timeout")

template readResponse*[T](opts: T): untyped = 
  if opts.udp:
    # UDP responses are a single datagram without a length prefix
    var address: IpAddress
    var port: Port
    var msg = newString(65535)
    let count = client.recvFrom(msg, msg.len(), address, port)
    if count == 0:
      print(colGray, "[udp socket read: 0, return]")
      return
    msg.setLen(count)
    if not opts.quiet and not opts.noprint:
      print(colGray, "[udp socket data: " & repr(msg) & "]")
      print colGray, "[udp read bytes: ", $msg.len(), "]"

    var rbuff = MsgBuffer.init(msg)
    var response: FastRpcResponse
    rbuff.unpack(response)
    if not opts.quiet and not opts.noprint:
      print colAquamarine, "[response:kind: ", repr(response.kind), "]"
      print colAquamarine, "[read response: ", repr response, "]"
    response
  else:
    # TCP responses are length-prefixed (2 bytes, big-endian)
    var msgLenBytes = client.recv(2, timeout = -1)
    if msgLenBytes.len() == 0:
      print(colGray, "[socket read: 0, return]")
      return
    var msgLen: int16 = msgLenBytes.fromStrBe16()
    if not opts.quiet and not opts.noprint:
      print(colGray, "[socket read:data:lenstr: " & repr(msgLenBytes) & "]")
      print(colGray, "[socket read:data:len: " & repr(msgLen) & "]")

    var msg = ""
    while msg.len() < msgLen:
      if not opts.quiet and not opts.noprint:
        print(colGray, "[reading msg]")
      let mb = client.recv(msgLen - msg.len(), timeout = -1)
      if not opts.quiet and not opts.noprint:
        print(colGray, "[read bytes: " & $mb.len() & "]")
      msg.add mb
    if not opts.quiet and not opts.noprint:
      print(colGray, "[socket data: " & repr(msg) & "]")

    if not opts.quiet and not opts.noprint:
      print colGray, "[read bytes: ", $msg.len(), "]"
      print colGray, "[read: ", repr(msg), "]"

    var rbuff = MsgBuffer.init(msg)
    var response: FastRpcResponse
    rbuff.unpack(response)

    if not opts.quiet and not opts.noprint:
      print colAquamarine, "[response:kind: ", repr(response.kind), "]"
      print colAquamarine, "[read response: ", repr response, "]"
    response

template prettyPrintResults*(response: untyped): untyped = 
  var resbuf = MsgBuffer.init(response.result.buf.data)
  mnode = resbuf.toJsonNode()
  if not opts.noprint and not opts.noresults:
    if opts.prettyPrint:
      print(colOrange, pretty(mnode))
    else:
      print(colOrange, $(mnode))
