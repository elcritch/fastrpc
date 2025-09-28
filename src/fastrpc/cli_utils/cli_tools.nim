import std/terminal
import std/colors
import std/times

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

var totalTime* = 0'i64
var totalCalls* = 0'i64

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
