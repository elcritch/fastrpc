
import strutils
import system
import os
import tables

import macros

type
  Level* = enum ## \
    ## Enumeration of logging levels.
    ##
    ## Debug messages represent the lowest logging level, and fatal error
    ## messages represent the highest logging level. ``lvlAll`` can be used
    ## to enable all messages, while ``lvlNone`` can be used to disable all
    ## messages.
    ##
    ## Typical usage for each logging level, from lowest to highest, is
    ## described below:
    ##
    ## * **Debug** - debugging information helpful only to developers
    ## * **Info** - anything associated with normal operation and without
    ##   any particular importance
    ## * **Notice** - more important information that users should be
    ##   notified about
    ## * **Warn** - impending problems that require some attention
    ## * **Error** - error conditions that the application can recover from
    ## * **Fatal** - fatal errors that prevent the application from continuing
    ##
    ## It is completely up to the application how to utilize each level.
    ##
    ## Individual loggers have a ``levelThreshold`` field that filters out
    ## any messages with a level lower than the threshold. There is also
    ## a global filter that applies to all log messages, and it can be changed
    ## using the `setLogFilter proc<#setLogFilter,Level>`_.
    lvlAll,     ## All levels active
    lvlTrace,   ## Debug level and above are active
    lvlDebug,   ## Debug level and above are active
    lvlInfo,    ## Info level and above are active
    lvlNotice,  ## Notice level and above are active
    lvlWarn,    ## Warn level and above are active
    lvlError,   ## Error level and above are active
    lvlNone    ## No levels active; nothing is logged


const
  McuUtilsLoggingLevel* {.strdefine.} = "lvlInfo"
  McuUtilsLoggingModuleLevels* {.strdefine.} = "exampleMcuUtilModule=lvlInfo"

var McuUtilsLevel {.compileTime.} = parseEnum[Level](McuUtilsLoggingLevel)

var McuUtilsModuleLevels {.compileTime.}: Table[string, Level] =
  block:
    let lvls = McuUtilsLoggingModuleLevels.split(",")
    var tbl = initTable[string, Level]()
    for lvs in lvls:
      let lv = lvs.split("=")
      assert lv.len() == 2
      tbl[lv[0]] = parseEnum[Level](lv[1])
    tbl


template initLogging*(args: varargs[untyped]) = 
  discard args

macro logImpl(level: static[Level]; msg: string, args: varargs[string, `$`]): untyped =
  let lvl: int = level.ord()
  result = nnkStmtList.newTree()
  let li = args.lineInfoObj()
  var (dir, name, ext) = li.filename.splitFile()
  let modLvl = McuUtilsModuleLevels.getOrDefault(name, lvlNone).ord()
  if lvl >= ord(McuUtilsLevel) or lvl >= ord(modLvl):
    for i in countdown(args.len(), 0, 1):
      args.insert(i, newStrLitNode(" "))
    args.insert(0, msg)
    result.add newCall("echo", args[0..^1])

macro setLogLevel*(level: static[Level]) =
  McuUtilsLevel = level

template log*(level: static[Level], msg: string, args: varargs[string, `$`]) =
  logImpl(level, msg, args) 

template logRunExtra*(level: static[Level], code, normal: untyped): untyped =
  when level.ord() >= ord(McuUtilsLevel):
    code
  else:
    normal

template debug*(msg: string, args: varargs[string, `$`]) = logImpl(lvlDebug, msg, args) 
template trace*(msg: string, args: varargs[string, `$`]) = logImpl(lvlTrace, msg, args) 
template error*(msg: string, args: varargs[string, `$`]) = logImpl(lvlError, msg, args) 
template info*(msg: string, args: varargs[string, `$`]) = logImpl(lvlInfo, msg, args) 
template warn*(msg: string, args: varargs[string, `$`]) = logImpl(lvlWarn, msg, args) 
template notice*(msg: string, args: varargs[string, `$`]) = logImpl(lvlNotice, msg, args) 

template logException*(ex: ref Exception, modName: string, lvl: static[Level]) =
  # Log an exception stacktrace piecemeal in order to avoid 
  # large memory usage for big stack traces. These can be upwards
  # of 4kB which can quickly become problematic on small HEAPs
  logImpl(lvl, "[", modName, "]: exception message: ", ex.msg)
  let stes = getStackTraceEntries(ex)
  for ste in stes:
    logImpl(lvl, "[", modName, "]: exception: ", $ste)

when isMainModule:
  var a = 10

  setLogLevel(lvlDebug)
  logDebug("a: there's bug's?", "never!")
  logWarn("a: warn there's bug's?", "value:", a)

  setLogLevel(lvlInfo)
  logDebug("b: there's bug's?", "never!")
  logInfo("b: info there's bug's?", "value:", a)
  logWarn("b: warn there's bug's?", "value:", a)

