import std/[monotimes, os, logging, times]

import fastrpc/server/fastrpcserver
import fastrpc/server/rpcmethods

import json
import random



# Define RPC Server #
DefineRpcs(name=exampleRpcs):

  proc add(a: int, b: int): int {.rpc.} =
    result = 1 + a + b

  proc addAll(vals: seq[int]): int {.rpc.} =
    for val in vals:
      result = result + val

  proc multAll(x: int, vals: seq[int]): seq[int] {.rpc.} =
    result = newSeqOfCap[int](vals.len())
    for val in vals:
      result.add val * x

  proc echos(msg: string): string {.rpc.} =
    echo("echos: ", "hello ", msg)
    result = "hello: " & msg

  proc echorepeat(msg: string, count: int): string {.rpc.} =
    let rmsg = "hello " & msg
    for i in 0..count:
      echo("echos: ", rmsg)
      # discard context.sender(rmsg)
      discard rpcReply(rmsg)
      os.sleep(400)
    result = "k bye"

  proc simulatelongcall(cntMillis: int): Duration {.rpc.} =

    let t0 = getMonoTime()
    echo("simulatelongcall: ", )
    os.sleep(cntMillis)
    let t1 = getMonoTime()

    return t1-t0


  proc testerror(msg: string): string {.rpc.} =
    echo("test error: ", "what is your favorite color?")
    if msg != "Blue":
      raise newException(ValueError, "wrong answer!")
    result = "correct: " & msg

type
  TimerDataQ = InetEventQueue[seq[int64]]

  TimerOptions {.rpcOption.} = object
    delay: Duration
    count: int

DefineRpcTaskOptions[TimerOptions](name=timerOptionsRpcs):
  proc setDelay(opt: var TimerOptions, delay: Duration): bool {.rpcSetter.} =
    ## called by the socket server every time there's data
    ## on the queue argument given the `rpcEventSubscriber`.
    ## 
    if delay < initDuration(milliseconds=10_000):
      opt.delay = delay
      return true
    else:
      return false
  
  proc getDelay(option: var TimerOptions): int {.rpcGetter.} =
    ## called by the socket server every time there's data
    ## on the queue argument given the `rpcEventSubscriber`.
    ## 
    result = option.delay.inMilliseconds()
  

proc timeSerializer(queue: TimerDataQ): seq[int64] {.rpcSerializer.} =
  ## called by the socket server every time there's data
  ## on the queue argument given the `rpcEventSubscriber`.
  ## 
  # var tvals: seq[int64]
  if queue.tryRecv(result):
    let rs = rand(200)
    os.sleep(rs)
    echo "ts: ", result.len()

proc timeSampler*(queue: TimerDataQ, opts: TaskOption[TimerOptions]) {.rpcThread.} =
  ## Thread example that runs the as a time publisher. This is a reducer
  ## that gathers time samples and outputs arrays of timestamp samples.
  var data = opts.data

  while true:
    block: # logAllocStats(lvlExtraDebug):
      var tvals = newSeqOfCap[MonoTime](data.count)
      for i in 0..<data.count:
        var ts = getMonoTime()
        tvals.add ts
        #os.sleep(data.delay.int div (2*data.count))

      debug "timePublisher:", "ts:", tvals[0], "len:", tvals.len.repr
      debug "queue:len:", queue.chan.peek()

      # let newOpts = opts.getUpdatedOption()
      # if newOpts.isSome:
        # echo "setting new parameters: ", repr(newOpts)
        # data = newOpts.get()

      os.sleep(data.delay.inMilliseconds())
      var qvals = isolate tvals
      discard queue.trySend(qvals)

proc streamThread*(arg: ThreadArg[seq[int64], TimerOptions]) {.thread, nimcall.} = 
  os.sleep(5_000)
  echo "streamThread: ", repr(arg.opt.data)
  timeSampler(arg.queue, arg.opt)


when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_UDP),
    # newInetAddr("0.0.0.0", 5656, Protocol.IPPROTO_TCP),
    newInetAddr("::", 5555, Protocol.IPPROTO_UDP),
    # newInetAddr("::", 5555, Protocol.IPPROTO_TCP),
  ]

  echo "setup timer thread"
  var
    timer1q = TimerDataQ.init(10)
    timerOpt = TimerOptions(delay: 1_000.Millis, count: 10)

  var tchan: Chan[TimerOptions] = newChan[TimerOptions](1)
  var topt = TaskOption[TimerOptions](data: timerOpt, ch: tchan)
  var arg = ThreadArg[seq[int64],TimerOptions](queue: timer1q, opt: topt)
  var result: RpcStreamThread[seq[int64], TimerOptions]
  createThread[ThreadArg[seq[int64], TimerOptions]](result, streamThread, move arg)

  # os.sleep(5_000)

  echo "running fast rpc example"
  var router = newFastRpcRouter()

  # register the `exampleRpcs` with our RPC router
  router.registerRpcs(exampleRpcs)

  when defined(testDatastream):
    # register a `datastream` with our RPC router
    echo "register datastream"
    router.registerDataStream(
      "microspub",
      serializer=timeSerializer,
      reducer=timeSampler, 
      queue = timer1q,
      option = timerOpt,
      optionRpcs = timerOptionsRpcs,
    )

  when defined(testMulticast):
    let maddr = newClientHandle("ff12::1", 2048, -1.SocketHandle, net.IPPROTO_UDP)
    logInfo "app_net_rpc:", "multicast-addr:", repr maddr
    let mpub = router.subscribe("microspub", maddr, timeout = 0.Millis, source = "")
    logInfo "app_net_rpc:", "multicast-publish:", repr mpub

    # print out all our new rpc's!
    for rpc in router.procs.keys():
      echo "  rpc: ", rpc

  var frpcServer = newFastRpcServer(router, prefixMsgSize=true, threaded=false)
  startSocketServer(inetAddrs, frpcServer)
