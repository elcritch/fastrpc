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

template timeBlock[T](n: string, opts: T, blk: untyped): untyped =
  let t0 = getTime()
  blk

  let td = getTime() - t0
  if not opts.quiet and not opts.noprint:
    print colGray, "[took: ", $(td.inMicroseconds().float() / 1e3), " millis]"
  totalCalls.inc()
  totalTime = totalTime + td.inMicroseconds()
  allTimes.add(td.inMicroseconds())
  

proc setReceiveTimeout(socket: Socket, timeoutMs: int) =
  var timeout: Timeval
  timeout.tv_sec = posix.Time(timeoutMs div 1000)
  timeout.tv_usec = Suseconds(timeoutMs mod 1000 * 1000)
  
  if setsockopt(socket.getFd(), SOL_SOCKET, SO_RCVTIMEO, 
                addr timeout, sizeof(timeout).Socklen) != 0:
    raise newException(OSError, "Failed to set receive timeout")
