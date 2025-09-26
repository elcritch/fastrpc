import json, tables, strutils, options
import strformat
import net
import times
import stats
import sequtils
import sugar

import cligen
from cligen/argcvt import ArgcvtParams, argKeys         # Little helpers

import msgpack4nim
import msgpack4nim/msgpack2json

import ../server/protocol
import ../servertypes

import ./fw_utils
import ./cli_tools
import ./rpc_utils

proc shouldLog(opts: RpcOptions): bool =
  not opts.quiet and not opts.noprint

proc logRequestDetails(opts: RpcOptions, result: RpcCallResult) =
  if not shouldLog(opts):
    return

  print("[socket mcall ipaddr: " & repr(opts.ipAddr.ipaddr) & "]")
  print("[socket mcall bytes:len: " & repr(result.payload.len()) & "]")

  if not opts.udp:
    print("[socket mcall bytes:lenprefix: " & repr(result.lengthPrefix) & "]")

  let preview =
    if result.payload.len == 0:
      ""
    else:
      result.payload[0 .. min(result.payload.high, 20)]
  print("[socket mcall bytes:data: " & repr(preview) & "]")

proc logResponseEntry(opts: RpcOptions, entry: RpcResponseEntry) =
  if not shouldLog(opts):
    return

  if opts.udp:
    print(colGray, "[udp socket data: " & repr(entry.raw) & "]")
    print(colGray, "[udp read bytes: ", $entry.raw.len(), "]")
  else:
    print(colGray, "[read bytes: ", $entry.raw.len(), "]")
    print(colGray, "[read: " & repr(entry.raw) & "]")

  print(colAquamarine, "[response:kind: ", repr(entry.response.kind), "]")
  print(colAquamarine, "[read response: ", repr(entry.response), "]")

  if entry.error.isSome:
    print(colRed, repr(entry.error.get()))
    return

  if entry.kind == rrAck or opts.noresults:
    return

  if entry.json.isSome:
    let node = entry.json.get()
    if opts.prettyPrint:
      print(colOrange, pretty(node))
    else:
      print(colOrange, $(node))
  else:
    print(colOrange, "[response payload unavailable]")

proc logCallTiming(opts: RpcOptions, durationMicros: int64) =
  if not shouldLog(opts):
    return

  let millis = durationMicros.float / 1_000.0
  print(colGray, fmt("[took: {millis:.3f} millis]"))

proc logRpcCompletion(opts: RpcOptions) =
  if not shouldLog(opts):
    return
  print(colGreen, "[rpc done at " & $now() & "]")

proc logKeepAlive(opts: RpcOptions, message: KeepAliveMessage) =
  if not shouldLog(opts):
    return

  if message.json.isSome:
    print("subscription: ", $message.json.get())
  elif message.parseError.isSome:
    print(colRed, "[exception: ", message.parseError.get(), "]")
proc call(ip: RpcIpAddress,
          cmdargs: seq[string],
          port=Port(5656),
          udp=true,
          dry_run=false,
          quiet=false,
          silent=false,
          noresults=false,
          pretty=false,
          count=1,
          delay=0,
          showstats=false,
          system=false,
          subscribe=false,
          keepalive=false,
          rawJsonArgs="") =

  var opts = RpcOptions(nextId: 1,
                        count: count,
                        delay: delay,
                        jsonArg: rawJsonArgs,
                        ipAddr: ip,
                        port: port,
                        udp: udp,
                        noresults: noresults,
                        prettyPrint: pretty,
                        quiet: quiet,
                        noprint: silent,
                        system: system,
                        subscribe: subscribe,
                        dryRun: dry_run,
                        showstats: showstats,
                        keepalive: keepalive,
                        receiveTimeoutMs: DefaultUdpTimeoutMs)

  ## Some API call
  let
    name = cmdargs[0]
    args = cmdargs[1..^1]
    # cmdargs = @[name, rawJsonArgs]
    pargs = collect(newSeq):
      for ca in args:
        parseJson(ca)
    jargs = if rawJsonArgs == "": %pargs else: rawJsonArgs.parseJson() 
  
  echo fmt("rpc call: name: '{name}' args: '{args}' ip:{repr ip} ")
  # echo fmt("rpc params:pargs: {repr pargs}")
  echo fmt("rpc params:jargs: {repr jargs}")
  echo fmt("rpc params: {$jargs}")

  var ss = MsgBuffer.init()
  ss.write jargs.fromJsonNode()
  # ss.pack(jargs)
  let kind = if opts.system: SystemRequest
             elif opts.subscribe: Subscribe
             else: Request
  var call = FastRpcRequest(kind: kind,
                            id: 1,
                            procName: name,
                            params: FastRpcParamsBuffer(buf: ss))

  print(colYellow, "CALL:", repr call)
  var sc = MsgBuffer.init()
  sc.pack(call)
  let mcall = sc.data
  print(colYellow, "MCALL:", repr mcall)

  if opts.dryRun:
    return

  let domain =
    if opts.ipAddr.ipaddr.family == IpAddressFamily.IPv6:
      Domain.AF_INET6
    else:
      Domain.AF_INET
  let protocol =
    if opts.udp:
      Protocol.IPPROTO_UDP
    else:
      Protocol.IPPROTO_TCP

  if shouldLog(opts):
    print(colYellow, "[socket server: domain: ", $domain, " protocol: ", $protocol, "]")
    print(colYellow, "[connecting to server ip addr: ", $opts.ipAddr.ipstring,
          " port: ", $opts.port, " udp: ", $opts.udp, "]")

  var client: Socket
  var clientOpen = false
  var durationsMicros = newSeq[int64]()

  try:
    client = openRpcSocket(opts)
    clientOpen = true

    if shouldLog(opts):
      print(colYellow, "[connected to server ip addr: ", $opts.ipAddr.ipstring, "]")
      print(colBlue, "[call: ", repr(call), "]")

    for _ in 0..<opts.count:
      let result = execRpc(client, call, opts)
      durationsMicros.add(result.durationMicros)

      logRequestDetails(opts, result)
      for entry in result.responses:
        logResponseEntry(opts, entry)
      logCallTiming(opts, result.durationMicros)
      logRpcCompletion(opts)

    if opts.keepalive:
      while opts.keepalive:
        let keepAliveOpt = recvKeepAlive(client, opts)
        if keepAliveOpt.isNone:
          continue
        logKeepAlive(opts, keepAliveOpt.get())
  finally:
    if clientOpen:
      client.close()

  print("\n")

  if opts.showstats and durationsMicros.len > 0:
    let totalMicros = durationsMicros.foldl(a + b, 0'i64)
    let totalMillis = totalMicros.float / 1_000.0
    let totalCalls = durationsMicros.len
    let avgMillis = totalMillis / float(totalCalls)

    print(colMagenta, "[total time: ", $totalMillis, " millis]")
    print(colMagenta, "[total count: ", $totalCalls, " No]")
    print(colMagenta, "[avg time: ", $avgMillis, " millis]")

    var ss: RunningStat
    ss.push(durationsMicros.mapIt(float(it) / 1_000.0))

    var maxMicros = durationsMicros[0]
    for value in durationsMicros:
      if value > maxMicros:
        maxMicros = value

    print(colMagenta, "[mean time: ", $ss.mean(), " millis]")
    print(colMagenta, "[max time: ", $(maxMicros.float / 1_000.0), " millis]")
    print(colMagenta, "[variance time: ", $ss.variance(), " millis]")
    print(colMagenta, "[standardDeviation time: ", $ss.standardDeviation(), " millis]")

proc flash(ip: RpcIpAddress,
           firmware: string,
           port=Port(5555),
           force=false,
           pretty=false,
           quiet=false,
           silent=false,
           waitAfterRebootMs=DefaultWaitAfterRebootMs) =

  if waitAfterRebootMs < 0:
    raise newException(ValueError, "waitAfterRebootMs must be >= 0")

  let flashOpts = FlashOptions(firmwarePath: firmware,
                               ipAddress: ip.ipstring,
                               port: port,
                               forceUpload: force,
                               prettyPrint: pretty,
                               quiet: quiet,
                               silent: silent,
                               waitAfterRebootMs: Natural(waitAfterRebootMs))

  try:
    let result = flashFirmware(flashOpts)
    if not silent:
      print(colGreen, fmt("flash completed: uploaded {result.uploadedBytes} bytes"))
  except CatchableError as err:
    if not silent:
      print(colRed, "flash failed: ", err.msg)
    quit(1)

proc run_cli*() =
  proc argParse(dst: var RpcIpAddress, dfl: RpcIpAddress, a: var ArgcvtParams): bool =
    try:
      let res = a.val.split('%')[0].parseIpAddress()
      dst = RpcIpAddress(ipstring: a.val, ipaddr: res)
    except CatchableError:
      return false
    return true

  proc argHelp(dfl: RpcIpAddress; a: var ArgcvtParams): seq[string] =
    argHelp($(dfl.ipstring), a)

  proc argParse(dst: var Port, dfl: Port, a: var ArgcvtParams): bool =
    try:
      dst = Port(a.val.parseInt())
    except CatchableError:
      return false
    return true
  proc argHelp(dfl: Port; a: var ArgcvtParams): seq[string] =
    argHelp($(dfl), a)

  dispatchMulti([call], [flash])

when isMainModule:
  run_cli()
