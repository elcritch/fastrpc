
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
