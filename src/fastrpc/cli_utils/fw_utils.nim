import json, strutils
import net, os, streams
import times

import msgpack4nim/msgpack2json

import std/sha1

import ./cli_tools

const
  DefaultWaitAfterRebootMs* = 15_000
  BuffSz* = 512

type
  FlashOptions* = object
    firmwarePath*: string
    ipAddress*: string
    port*: Port
    forceUpload*: bool
    prettyPrint*: bool
    quiet*: bool
    silent*: bool
    waitAfterRebootMs*: Natural

  FlashResult* = object
    uploadedBytes*: int
    verifyResponse*: JsonNode

proc validateFirmwareFile(path: string) =
  if not path.endsWith(".bin"):
    raise newException(ValueError, "Firmware file must end with `.bin`.")
  if not path.fileExists():
    raise newException(IOError, "Firmware file does not exist: " & path)

proc execRpc(client: Socket,
             requestId: var int,
             call: JsonNode,
             opts: FlashOptions,
             silence=false): JsonNode =
  {.cast(gcsafe).}:
    var rpcCall = call
    rpcCall["id"] = %* requestId
    rpcCall["jsonrpc"] = %* "2.0"
    inc(requestId)

    let payload =
      when defined(TcpJsonRpcServer):
        $rpcCall
      else:
        rpcCall.fromJsonNode()

    var msgLenBytes: string
    var msg = ""

    timeBlock("call", opts):
      if opts.quiet or silence:
        client.send(payload)
      else:
        if not opts.silent:
          print(colYellow, "[sending payload of size ", $(payload.len()), "]")
        client.send(payload)
      msgLenBytes = client.recv(4)
      if msgLenBytes.len() == 0:
        return
      var msgLen: int32 = 0
      for i in countdown(3, 0):
        msgLen = (msgLen shl 8) or int32(msgLenBytes[i])
      while msg.len() < msgLen:
        let remaining = msgLen - msg.len()
        let readLen = if remaining < 4 * 1024: remaining else: 4 * 1024
        let part = client.recv(readLen)
        msg.add(part)

    if not (opts.quiet or silence):
      if not opts.silent:
        print(colGray, "[recv bytes: ", $msg.len(), "]")

    let mnode =
      when defined(TcpJsonRpcServer):
        msg
      else:
        msg.toJsonNode()

    if not (opts.quiet or silence):
      if not opts.silent:
        print(colBlue, "[response: ", $(mnode), "]")

    if mnode.hasKey("result") and mnode["result"].kind == JString:
      let res = mnode["result"].getStr()
      try:
        discard res.toJsonNode()
      except CatchableError:
        discard

    if not (opts.quiet or silence):
      if not opts.silent:
        print(colGreen, "[rpc done at ", $now(), "]")

    mnode

proc runFirmwareRpc(opts: FlashOptions,
                    fwStrm: Stream,
                    requestId: var int): FlashResult =
  var client = newSocket(buffered=false)
  try:
    client.connect(opts.ipAddress, opts.port)
    if not opts.silent:
      print(colYellow, "[connected to ", opts.ipAddress, ":", $opts.port, "]")

    if not opts.silent:
      print(colBlue, "Uploaded Firmware header...")
    let hdrChunk = fwStrm.readStr(BuffSz)
    let hdrSha1 = $secureHash(hdrChunk)
    let hdrCall: JsonNode = %* {"method": "firmware-begin", "params": [hdrChunk, hdrSha1]}

    if not opts.quiet and not opts.silent:
      print(colBlue, "hdr chunk len: ", $hdrChunk.len(), " sha1: ", hdrSha1)
    let hdrResNode = client.execRpc(requestId, hdrCall, opts)

    if not opts.quiet and not opts.silent:
      print(colBlue, "WARNING: chunk_len result: ", $hdrResNode)

    let res = to(hdrResNode["result"], seq[string])
    if res.len() == 0 or res[0] != "ok":
      if opts.forceUpload:
        if not opts.silent:
          print(colYellow, "Warning: uploading firmware despite version mismatch: ",
                if res.len() > 1: res[1] else: "unknown")
      else:
        raise newException(ValueError,
          "Firmware version mismatch: " & (if res.len() > 1: res[1] else: "unknown"))

    while not fwStrm.atEnd():
      let chunk = fwStrm.readStr(BuffSz)
      let chunkSha1 = $secureHash(chunk)
      if not opts.quiet and not opts.silent:
        print(colBlue, "Uploading bytes: ", $chunk.len())
      let chunkCall: JsonNode = %* {"method": "firmware-chunk", "params": [chunk, chunkSha1, requestId]}
      let chunkResNode = client.execRpc(requestId, chunkCall, opts, silence=true)
      let chunkRes = to(chunkResNode["result"], int)
      if not opts.silent:
        print(colYellow, "Uploaded bytes: ", $chunkRes)

    let finishCall: JsonNode = %* {"method": "firmware-finish", "params": ["0"]}
    let finishResNode = client.execRpc(requestId, finishCall, opts)
    let finishRes = to(finishResNode["result"], int)
    result.uploadedBytes = finishRes
    if not opts.silent:
      print(colYellow, "Uploaded total bytes: ", $finishRes)

    if not opts.silent:
      print(colRed, "Rebooting device...")
    try:
      discard client.execRpc(requestId, %* {"method": "espReboot", "params": []}, opts)
    except CatchableError:
      if not opts.quiet and not opts.silent:
        print(colYellow, "Expected timeout during reboot.")
  finally:
    client.close()

  if opts.waitAfterRebootMs > 0:
    sleep(opts.waitAfterRebootMs.int)

  client = newSocket(buffered=false)
  try:
    client.connect(opts.ipAddress, opts.port)
    if not opts.silent:
      print(colYellow, "[reconnected to ", opts.ipAddress, ":", $opts.port, "]")

    let verifyCall: JsonNode = %* {"method": "firmware-verify", "params": []}
    result.verifyResponse = client.execRpc(requestId, verifyCall, opts)
    if opts.prettyPrint:
      if not opts.silent:
        print(colBlue, pretty(result.verifyResponse))
    else:
      if not opts.silent:
        print(colBlue, $(result.verifyResponse))
  finally:
    client.close()

proc flashFirmware*(opts: FlashOptions): FlashResult =
  if opts.ipAddress.len == 0:
    raise newException(ValueError, "Missing target IP address.")
  validateFirmwareFile(opts.firmwarePath)

  var fwStrm = newFileStream(opts.firmwarePath, fmRead)
  if fwStrm.isNil:
    raise newException(IOError, "Failed to open firmware file: " & opts.firmwarePath)

  if not opts.silent:
    print("Checking firmware file: ", opts.firmwarePath)

  var requestId = 0
  try:
    result = runFirmwareRpc(opts, fwStrm, requestId)
  finally:
    fwStrm.close()
