
import std/streams

type
  CoapType* = enum
    Confirmable = 0
    NonConfirmable = 1
    Acknowledgement = 2
    Reset = 3

  CoapHeader* = object
    version*: uint8
    msgType*: CoapType
    code*: uint8
    messageId*: uint16
    token*: seq[byte]

  CoapOption* = object
    number*: uint16
    value*: seq[byte]

proc readByte(stream: Stream, err: string): byte =
  var buf: array[1, byte]
  if stream.readData(addr buf[0], 1) != 1:
    raise newException(ValueError, err)
  buf[0]

proc readExact(stream: Stream, count: int, err: string): seq[byte] =
  result = newSeq[byte](count)
  if count == 0:
    return
  let read = stream.readData(addr result[0], count)
  if read != count:
    raise newException(ValueError, err)

proc readRemaining(stream: Stream): seq[byte] =
  result = newSeq[byte]()
  while true:
    var buffer: array[256, byte]
    let bytesRead = stream.readData(addr buffer[0], buffer.len)
    if bytesRead <= 0:
      break
    result.setLen(result.len + bytesRead)
    result[(result.len - bytesRead) ..< result.len] = buffer[0 ..< bytesRead]

proc parseCoapHeader*(stream: Stream): CoapHeader =
  ## Parses the CoAP header and token from ``stream``.
  ## Raises ``ValueError`` when the stream has insufficient data or the version is wrong.
  var header: array[4, byte]
  if stream.readData(addr header[0], header.len) != header.len:
    raise newException(ValueError, "data too short for CoAP header")
  result.version = (header[0] shr 6) and 0b11
  if result.version != 1:
    raise newException(ValueError, "unsupported CoAP version: " & $result.version)
  result.msgType = CoapType((header[0] shr 4) and 0b11)
  result.code = header[1]
  result.messageId = (uint16(header[2]) shl 8) or uint16(header[3])
  let tokenLength = header[0] and 0b1111
  if tokenLength > 0:
    if tokenLength > 8:
      raise newException(ValueError,
          "invalid token length: " & $tokenLength)
    result.token = readExact(stream, int(tokenLength),
        "data too short for token")
  else:
    result.token = @[]

proc parseCoapOptions*(stream: Stream): (seq[CoapOption], seq[byte]) =
  ## Parses the sequence of CoAP options from ``stream``.
  ## Returns the parsed options and any remaining payload bytes.
  var current = 0
  var options: seq[CoapOption] = @[]
  while not stream.atEnd:
    let header = readByte(stream, "data too short for option header")
    if header == 0xff'u8:
      return (options, readRemaining(stream))
    let deltaNib = int(header shr 4)
    let lenNib = int(header and 0x0f)
    if deltaNib == 15 or lenNib == 15:
      raise newException(ValueError, "invalid option header")
    var delta = deltaNib
    case deltaNib
    of 13:
      delta = 13 + int(readByte(stream, "data too short for option delta"))
    of 14:
      let msb = readByte(stream, "data too short for option delta")
      let lsb = readByte(stream, "data too short for option delta")
      delta = 269 + (int(msb) shl 8) + int(lsb)
    else:
      discard
    var length = lenNib
    case lenNib
    of 13:
      length = 13 + int(readByte(stream, "data too short for option length"))
    of 14:
      let msb = readByte(stream, "data too short for option length")
      let lsb = readByte(stream, "data too short for option length")
      length = 269 + (int(msb) shl 8) + int(lsb)
    else:
      discard
    let value = readExact(stream, length, "data too short for option value")
    current += delta
    options.add CoapOption(number: uint16(current), value: value)
  (options, @[])
