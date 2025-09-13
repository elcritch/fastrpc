
type
  CoapType* = enum
    Confirmable = 0
    NonConfirmable = 1
    Acknowledgement = 2
    Reset = 3

  CoapHeader* = object
    version*: uint8
    msgType*: CoapType
    tokenLength*: uint8
    code*: uint8
    messageId*: uint16
    token*: seq[byte]

  CoapOption* = object
    number*: uint16
    value*: seq[byte]

proc parseCoapHeader*(data: openArray[byte]): CoapHeader =
  ## Parses the CoAP header and token from ``data``.
  ## Raises ``ValueError`` when ``data`` is too short or the version is wrong.
  if data.len < 4:
    raise newException(ValueError, "data too short for CoAP header")
  let first = data[0]
  result.version = (first shr 6) and 0b11
  if result.version != 1:
    raise newException(ValueError, "unsupported CoAP version: " &
        $result.version)
  result.msgType = CoapType((first shr 4) and 0b11)
  result.tokenLength = first and 0b1111
  result.code = data[1]
  result.messageId = (uint16(data[2]) shl 8) or uint16(data[3])
  if result.tokenLength > 0:
    if result.tokenLength > 8:
      raise newException(ValueError,
          "invalid token length: " & $result.tokenLength)
    if data.len < 4 + int(result.tokenLength):
      raise newException(ValueError, "data too short for token")
    result.token = @data[4 ..< 4 + int(result.tokenLength)]
  else:
    result.token = @[]

proc parseCoapOptions*(data: openArray[byte]): (seq[CoapOption], seq[byte]) =
  ## Parses the sequence of CoAP options from ``data``.
  ## Returns the parsed options and any remaining payload bytes.
  var i = 0
  var current = 0
  var options: seq[CoapOption] = @[]
  while i < data.len:
    if data[i] == 0xff'u8:
      return (options, @data[i + 1 ..< data.len])
    let deltaNib = int(data[i] shr 4)
    let lenNib = int(data[i] and 0x0f)
    inc i
    if deltaNib == 15 or lenNib == 15:
      raise newException(ValueError, "invalid option header")
    var delta = deltaNib
    case deltaNib
    of 13:
      if i >= data.len:
        raise newException(ValueError, "data too short for option delta")
      delta = 13 + int(data[i])
      inc i
    of 14:
      if i + 1 >= data.len:
        raise newException(ValueError, "data too short for option delta")
      delta = 269 + (int(data[i]) shl 8) + int(data[i + 1])
      i += 2
    else:
      discard
    var length = lenNib
    case lenNib
    of 13:
      if i >= data.len:
        raise newException(ValueError, "data too short for option length")
      length = 13 + int(data[i])
      inc i
    of 14:
      if i + 1 >= data.len:
        raise newException(ValueError, "data too short for option length")
      length = 269 + (int(data[i]) shl 8) + int(data[i + 1])
      i += 2
    else:
      discard
    if i + length > data.len:
      raise newException(ValueError, "data too short for option value")
    current += delta
    let value = @data[i ..< i + length]
    i += length
    options.add CoapOption(number: uint16(current), value: value)
  (options, @[])
