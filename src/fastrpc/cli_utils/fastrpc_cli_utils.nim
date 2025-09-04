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

import ../server/protocol
import ../servertypes

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

var totalTime = 0'i64
var totalCalls = 0'i64

template timeBlock(n: string, opts: RpcOptions, blk: untyped): untyped =
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


var
  id: int = 1
  allTimes = newSeq[int64]()

template readResponse(): untyped = 
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
    let mb = client.recv(msgLen, timeout = -1)
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

template prettyPrintResults(response: untyped): untyped = 
  var resbuf = MsgBuffer.init(response.result.buf.data)
  mnode = resbuf.toJsonNode()
  if not opts.noprint and not opts.noresults:
    if opts.prettyPrint:
      print(colOrange, pretty(mnode))
    else:
      print(colOrange, $(mnode))

proc execRpc( client: Socket, i: int, call: var FastRpcRequest, opts: RpcOptions): JsonNode = 
  {.cast(gcsafe).}:
    call.id = id
    inc(id)

    var ss = MsgBuffer.init()
    ss.pack(call)
    let mcall = ss.data

    template parseReultsJson(response: untyped): untyped = 
      var resbuf = MsgBuffer.init(response.result.buf.data)
      resbuf.toJsonNode()

    timeBlock("call", opts):
      let msz = mcall.len().int16.toStrBe16()
      if not opts.quiet and not opts.noprint:
        print("[socket mcall ipaddr: " & repr(opts.ipAddr.ipaddr) & "]")
        print("[socket mcall bytes:len: " & repr(mcall.len()) & "]")
        print("[socket mcall bytes:lenprefix: " & repr msz & "]")
        print("[socket mcall bytes:data: " & repr(mcall[0..min(mcall.len()-1, 20)]) & "]")
      if opts.udp:
        client.sendTo($opts.ipAddr.ipaddr, opts.port, mcall)
      else:
        client.send( msz & mcall )

      var response = readResponse()

    var mnode: JsonNode

    if opts.subscribe:
      var resbuf = MsgBuffer.init(response.result.buf.data)
      mnode = resbuf.toJsonNode()
      if not opts.quiet and not opts.noprint:
        print colAquamarine, "[response:kind: ", repr(response.kind), "]"
      response = readResponse()

    while response.kind == Publish:
      mnode = response.parseReultsJson()
      response.prettyPrintResults()

      response = readResponse()

    if response.kind == Error:
      var resbuf = MsgBuffer.init(response.result.buf.data)
      var err: FastRpcError
      resbuf.setPosition(0)
      resbuf.unpack(err)
      if not opts.quiet and not opts.noprint:
        print(colRed, repr err)
    else:
      response.prettyPrintResults()

    if not opts.quiet and not opts.noprint:
      print colGreen, "[rpc done at " & $now() & "]"

    if opts.delay > 0:
      os.sleep(opts.delay)

    mnode

import nativesockets

proc runRpc(opts: RpcOptions, req: FastRpcRequest) = 
  {.cast(gcsafe).}:
    # for (f,v) in margs.pairs():
      # call[f] = v
    var call = req

    let domain = if opts.ipAddr.ipaddr.family == IpAddressFamily.IPv6: Domain.AF_INET6 else: Domain.AF_INET
    let protocol = if opts.udp: Protocol.IPPROTO_UDP else: Protocol.IPPROTO_TCP
    let sockType = if opts.udp: SOCK_DGRAM else: SOCK_STREAM
    print(colYellow, "[socket server: domain: ", $domain, " protocol: ", $protocol, "]")
    let client: Socket = newSocket(buffered=false, domain=domain, sockType=sockType, protocol=protocol, )

    # var aiList = getAddrInfo(opts.ipAddr.ipstring, opts.port, domain)
    # print(colMagenta, "aiList: ", repr aiList)
    # let sa = cast[ptr SockAddr_in6](aiList.ai_addr)
    # print(colMagenta, "aiList: ", repr sa)
    # print(colMagenta, "sockaddr: ", aiList.ai_addr.getAddrString())

    print(colYellow, "[connecting to server ip addr: ", $opts.ipAddr.ipstring, " port: ", $opts.port, " udp: ", $opts.udp, "]")
    if not opts.udp:
      client.connect(opts.ipAddr.ipstring, opts.port)
    else:
      setReceiveTimeout(client, 1000)

    print(colYellow, "[connected to server ip addr: ", $opts.ipAddr.ipstring,"]")
    print(colBlue, "[call: ", repr call, "]")

    for i in 1..opts.count:
      # try:
        discard client.execRpc(i, call, opts)
      # except Exception:
        # print(colRed, "[exception: ", getCurrentExceptionMsg() ,"]")

    var mb = newString(4096)
    while opts.keepalive:
      var address: IpAddress
      var port: Port
      var count = 0
      if opts.udp:
        count = client.recvFrom(mb, mb.len(),address, port)
      else:
        count = client.recv(mb, mb.len(), timeout = -1)

      mb.setLen(count)

      if mb != "":
        try:
          let res = mb.toJsonNode()
          print("subscription: ", $res)
        except Exception:
          print(colRed, "[exception: ", getCurrentExceptionMsg() ,"]")
    client.close()

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

  let margs = %* {"method": name, "params": % jargs }

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

  if not opts.dryRun:
    opts.runRpc(call)

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

  dispatchMulti([call])

when isMainModule:
  run_cli()