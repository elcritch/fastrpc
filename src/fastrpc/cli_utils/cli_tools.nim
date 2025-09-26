import std/terminal
import std/colors

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
