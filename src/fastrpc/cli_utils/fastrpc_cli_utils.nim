import json, tables, strutils, macros, options
import strformat
import net, os
import times
import stats
import sequtils
import locks
import sugar
import terminal 
import colors
import posix

import cligen
from cligen/argcvt import ArgcvtParams, argKeys         # Little helpers

import msgpack4nim
import msgpack4nim/msgpack2json

import ./fw_utils
import ./rpc_utils
import ./cli_tools

import ../server/protocol
import ../servertypes
import ../client/clients as frpcc except call

type 
  RpcIpAddress = object
    ipstring: string
    ipaddr: IpAddress

  RpcOptions = object
    id: int
    showstats: bool
    keepalive: bool
    count: int
    delay: int
    jsonArg: string
    ipAddr: RpcIpAddress
    port: Port
    udp: bool
    noresults: bool
    prettyPrint: bool
    quiet: bool
    system: bool
    subscribe: bool
    dryRun: bool
    noprint: bool



var
  id: int = 1
  allTimes = newSeq[int64]()

## pretty printing is handled inline in runRpc now

import nativesockets

proc runRpc(opts: RpcOptions, mname: string, jargs: JsonNode) =

    print(colYellow, "[connecting to server ip addr: ", $opts.ipAddr.ipstring, " port: ", $opts.port, " udp: ", $opts.udp, "]")
    var cli: frpcc.FastRpcClient
    cli = frpcc.newFastRpcClient(opts.ipAddr.ipaddr, opts.port, opts.udp)
    cli.setReceiveTimeout(1000)

    print(colYellow, "[connected to server ip addr: ", $opts.ipAddr.ipstring, "]")

    for i in 1..opts.count:
      timeBlock("call", opts):
        try:
          if opts.subscribe:
            let subid = frpcc.subscribe(cli, mname, jargs)
            if not opts.quiet and not opts.noprint:
              print colAquamarine, "[subscribe ack: id=", $subid, "]"

            # After ack, read publishes until final message (Response/Error)
            while true:
              let ropt = frpcc.recv(cli)
              if ropt.isNone:
                break
              let resp = ropt.get()
              case resp.kind
              of Publish:
                var pb = MsgBuffer.init(resp.result.buf.data)
                let j = pb.toJsonNode()
                if not opts.noprint and not opts.noresults:
                  if opts.prettyPrint: print(colOrange, pretty(j))
                  else: print(colOrange, $(j))
              of Response:
                var rb = MsgBuffer.init(resp.result.buf.data)
                let j = rb.toJsonNode()
                if not opts.noprint and not opts.noresults:
                  if opts.prettyPrint: print(colOrange, pretty(j))
                  else: print(colOrange, $(j))
                break
              of Error:
                let eopt = decodeError(resp)
                if not opts.quiet and not opts.noprint:
                  if eopt.isSome:
                    print(colRed, repr eopt.get())
                  else:
                    print(colRed, "rpc error")
                break
              else:
                break
          else:
            let res = frpcc.callJson(cli, mname, jargs, system = opts.system)
            if not opts.noprint and not opts.noresults:
              if opts.prettyPrint: print(colOrange, pretty(res))
              else: print(colOrange, $(res))
        except frpcc.RpcTimeoutError as terr:
          if not opts.quiet and not opts.noprint:
            print(colRed, "timeout: ", terr.msg)
        except frpcc.RpcCallError as cerr:
          if not opts.quiet and not opts.noprint:
            print(colRed, "rpc error: ", cerr.detail)
        except CatchableError as err:
          if not opts.quiet and not opts.noprint:
            print(colRed, "error: ", err.msg)

      if opts.delay > 0:
        os.sleep(opts.delay)

    # Keepalive loop to print any remaining publish messages
    while opts.keepalive:
      let popt = frpcc.recvPublishJson(cli, if opts.udp: 1000 else: -1)
      if popt.isSome:
        let (sid, j) = popt.get()
        if not opts.noprint and not opts.noresults:
          if opts.prettyPrint: print(colOrange, pretty(j))
          else: print(colOrange, $(j))

    print("\n")

    if opts.showstats:
      print(colMagenta, "[total time: " & $(totalTime.float() / 1e3) & " millis]")
      print(colMagenta, "[total count: " & $(totalCalls) & " No]")
      print(colMagenta, "[avg time: " & $(float(totalTime.float()/1e3)/(1.0 * float(totalCalls))) & " millis]")

      var ss: RunningStat ## Must be "var"
      ss.push(allTimes.mapIt(float(it)/1000.0))

      print(colMagenta, "[mean time: " & $(ss.mean()) & " millis]")
      print(colMagenta, "[max time: " & $(allTimes.max().float()/1_000.0) & " millis]")
      print(colMagenta, "[variance time: " & $(ss.variance()) & " millis]")
      print(colMagenta, "[standardDeviation time: " & $(ss.standardDeviation()) & " millis]")

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

  var opts = RpcOptions(count: count,
                        delay: delay,
                        ipAddr: ip,
                        port: port,
                        quiet: quiet,
                        noprint: silent,
                        noresults: noresults,
                        dryRun: dry_run,
                        showstats: showstats,
                        prettyPrint: pretty,
                        system: system,
                        subscribe: subscribe,
                        udp: udp,
                        keepalive: keepalive)

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

  if not opts.dryRun:
    opts.runRpc(name, jargs)

proc flash(ip: RpcIpAddress,
           firmware: string,
           port=Port(5555),
           udp=true,
           force=false,
           pretty=false,
           quiet=false,
           silent=false,
           waitAfterRebootMs=DefaultWaitAfterRebootMs) =

  if waitAfterRebootMs < 0:
    raise newException(ValueError, "waitAfterRebootMs must be >= 0")

  let flashOpts = FlashOptions(firmwarePath: firmware,
                               ipAddress: ip.ipstring,
                               udp: udp,
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
