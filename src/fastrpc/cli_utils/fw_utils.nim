import json, strutils
import net, os, streams
import times

import msgpack4nim/msgpack2json

import std/sha1

import ./cli_tools
import ../client/clients as frpcc

const
  DefaultWaitAfterRebootMs* = 15_000
  BuffSz* = 512

type
  FlashOptions* = object
    firmwarePath*: string
    ipAddress*: string
    udp*: bool
    port*: Port
    forceUpload*: bool
    prettyPrint*: bool
    quiet*: bool
    silent*: bool
    noprint*: bool
    waitAfterRebootMs*: Natural

  FlashResult* = object
    uploadedBytes*: int
    verifyResponse*: JsonNode

proc validateFirmwareFile(path: string) =
  if not path.endsWith(".bin"):
    raise newException(ValueError, "Firmware file must end with `.bin`.")
  if not path.fileExists():
    raise newException(IOError, "Firmware file does not exist: " & path)

proc execRpcJson(cli: var frpcc.FastRpcClient,
                 mname: string,
                 params: JsonNode,
                 opts: FlashOptions,
                 silence=false): JsonNode =
  ## Execute an RPC via FastRpcClient and return the result as JsonNode.
  var mnode: JsonNode
  timeBlock("call", opts):
    if not (opts.quiet or silence) and not opts.silent:
      print(colYellow, "[sending payload of size ", $(params.len), "]")
    mnode = frpcc.callJson(cli, mname, params)

  if not (opts.quiet or silence) and not opts.silent:
    print(colBlue, "[response: ", $(mnode), "]")
    print(colGreen, "[rpc done at ", $now(), "]")
  mnode

proc runFirmwareRpc(opts: FlashOptions,
                    fwStrm: Stream,
                    requestId: var int): FlashResult =
  ## Connect via FastRpcClient (TCP), then perform firmware RPCs.
  if not opts.silent:
    print(colYellow, "[connecting to ", opts.ipAddress, ":", $opts.port, "]")
  var cli = frpcc.newFastRpcClient(opts.ipAddress.parseIpAddress(), opts.port, opts.udp)
  cli.setReceiveTimeout(1000)
  if not opts.silent:
    print(colYellow, "[connected to ", opts.ipAddress, ":", $opts.port, "]")

  if not opts.silent:
    print(colBlue, "Uploaded Firmware header...")
  let hdrChunk = fwStrm.readStr(BuffSz)
  let hdrSha1 = $secureHash(hdrChunk)
  let hdrArgs: JsonNode = %* [hdrChunk, hdrSha1]

  if not opts.quiet and not opts.silent:
    print(colBlue, "hdr chunk len: ", $hdrChunk.len(), " sha1: ", hdrSha1)
  let hdrResNode = execRpcJson(cli, "firmware-begin", hdrArgs, opts)

  if not opts.quiet and not opts.silent:
    print(colBlue, "WARNING: chunk_len result: ", $(hdrResNode))

  let res = to(hdrResNode, seq[string])
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
    let chunkArgs: JsonNode = %* [chunk, chunkSha1, requestId]
    let chunkResNode = execRpcJson(cli, "firmware-chunk", chunkArgs, opts, silence=true)
    let chunkRes = to(chunkResNode, int)
    inc requestId
    if not opts.silent:
      print(colYellow, "Uploaded bytes: ", $chunkRes)

  let finishArgs: JsonNode = %* ["0"]
  let finishResNode = execRpcJson(cli, "firmware-finish", finishArgs, opts)
  let finishRes = to(finishResNode, int)
  result.uploadedBytes = finishRes
  if not opts.silent:
    print(colYellow, "Uploaded total bytes: ", $finishRes)

  if not opts.silent:
    print(colRed, "Rebooting device...")
  try:
    discard execRpcJson(cli, "espReboot", %* [], opts)
  except CatchableError:
    if not opts.quiet and not opts.silent:
      print(colYellow, "Expected timeout during reboot.")

  if opts.waitAfterRebootMs > 0:
    sleep(opts.waitAfterRebootMs.int)

  var cliPost = frpcc.newFastRpcClient(opts.ipAddress.parseIpAddress(), opts.port, opts.udp)
  if not opts.silent:
    print(colYellow, "[reconnected to ", opts.ipAddress, ":", $opts.port, "]")
  result.verifyResponse = execRpcJson(cliPost, "firmware-verify", %* [], opts)
  if opts.prettyPrint:
    if not opts.silent:
      print(colBlue, pretty(result.verifyResponse))
  else:
    if not opts.silent:
      print(colBlue, $(result.verifyResponse))

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
