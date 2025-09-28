
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

  CoapMessage* = object
    header*: CoapHeader
    options*: seq[CoapOption]
    payload*: Stream

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

proc parseCoapHeader*(stream: Stream): CoapHeader {.raises: [ValueError, IOError, OSError].} =
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

proc parseCoapOptions*(stream: Stream): seq[CoapOption] {.raises: [ValueError, IOError, OSError].} =
  ## Parses the sequence of CoAP options from ``stream``.
  ## Returns the parsed options and any remaining payload bytes.
  var current = 0
  var options: seq[CoapOption] = @[]
  while not stream.atEnd:
    let header = readByte(stream, "data too short for option header")
    if header == 0xff'u8:
      return options
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
  options

proc parseCoap*(stream: sink Stream): CoapMessage {.raises: [ValueError, IOError, OSError].} =
  ## Parses the CoAP message from ``stream``.
  ## Raises ``ValueError`` when the stream has insufficient data.
  result.header = parseCoapHeader(stream)
  result.options = parseCoapOptions(stream)
  result.payload = move stream

proc payload*(message: CoapMessage): seq[byte] =
  result = message.payload.readRemaining()

proc writeByte(stream: Stream, b: byte) =
  var buf: array[1, byte]
  buf[0] = b
  streams.writeData(stream, addr buf[0], 1)

proc writeBytes(stream: Stream, data: openArray[byte]) =
  if data.len == 0: return
  streams.writeData(stream, unsafeAddr data[0], data.len)

proc serializeCoapHeader*(stream: Stream, header: CoapHeader) {.raises: [ValueError, IOError, OSError].} =
  ## Serializes the CoAP header (including token) to stream.
  if header.token.len > 8:
    raise newException(ValueError, "invalid token length: " & $header.token.len)
  let ver = uint8(header.version and 0b11)
  let typ = uint8(header.msgType) and 0b11
  let tkl = uint8(header.token.len) and 0b1111
  let b0 = (ver shl 6) or (typ shl 4) or tkl
  var hb: array[4, byte]
  hb[0] = b0
  hb[1] = header.code
  hb[2] = uint8((header.messageId shr 8) and 0xff)
  hb[3] = uint8(header.messageId and 0xff)
  streams.writeData(stream, addr hb[0], hb.len)
  if header.token.len > 0:
    streams.writeData(stream, addr header.token[0], header.token.len)

proc encodeExtended(value: int, nibble: var uint8, extra: var seq[byte]) {.raises: [ValueError].} =
  ## Encodes a CoAP option delta/length extended value.
  if value < 0:
    raise newException(ValueError, "negative value not allowed")
  if value <= 12:
    nibble = uint8(value)
  elif value <= 268:
    nibble = 13'u8
    extra.add uint8(value - 13)
  elif value <= 65804: # 269 + 0xffff - conservative upper bound
    nibble = 14'u8
    let v = value - 269
    extra.add uint8((v shr 8) and 0xff)
    extra.add uint8(v and 0xff)
  else:
    raise newException(ValueError, "value too large: " & $value)

proc serializeCoapOptions*(stream: Stream, options: seq[CoapOption]) {.raises: [ValueError, IOError, OSError].} =
  ## Serializes CoAP options to stream. Options must be in ascending order by number.
  var lastNum = 0
  for opt in options:
    let num = int(opt.number)
    if num < lastNum:
      raise newException(ValueError, "options must be in ascending order")
    let deltaVal = num - lastNum
    let lenVal = opt.value.len
    var deltaNib: uint8 = 0
    var lenNib: uint8 = 0
    var extra: seq[byte] = @[]
    encodeExtended(deltaVal, deltaNib, extra)
    var extraLen: seq[byte] = @[]
    encodeExtended(lenVal, lenNib, extraLen)
    let h = (deltaNib shl 4) or (lenNib and 0x0f)
    stream.writeByte(h)
    if extra.len > 0:
      streams.writeData(stream, addr extra[0], extra.len)
    if extraLen.len > 0:
      streams.writeData(stream, addr extraLen[0], extraLen.len)
    if opt.value.len > 0:
      streams.writeData(stream, addr opt.value[0], opt.value.len)
    lastNum = num

proc serializeCoap*(stream: Stream, message: CoapMessage) {.raises: [ValueError, IOError, OSError].} =
  ## Serializes a full CoAP message (header, options, payload) to stream.
  stream.serializeCoapHeader(message.header)
  stream.serializeCoapOptions(message.options)
  let pl = message.payload.readRemaining()
  if pl.len > 0:
    stream.writeByte(0xff'u8)
    streams.writeData(stream, addr pl[0], pl.len)
