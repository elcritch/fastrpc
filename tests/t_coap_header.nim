import std/unittest

import fastrpc/coap/protocol

suite "CoAP header parsing":
  test "parse simple header":
    let data = [
      0x41'u8,          # Ver=1, Type=0 (Confirmable), TKL=1
      0x01'u8,          # Code 0.01 (GET)
      0x00'u8, 0x10'u8, # Message ID 16
      0xff'u8           # Token
    ]
    let h = parseCoapHeader(data)
    check h.version == 1
    check h.msgType == Confirmable
    check h.tokenLength == 1
    check h.code == 1
    check h.messageId == 16
    check h.token.len == 1 and h.token[0] == 0xff'u8
  test "reject invalid token length":
    let data = [
      0x4f'u8, # Ver=1, Type=0, TKL=15 (invalid)
      0x01'u8,
      0x00'u8, 0x10'u8
    ]
    expect ValueError:
      discard parseCoapHeader(data)

  test "parse options sequence":
    let data = [
      0x41'u8,                                      # Ver=1, Type=0 (Confirmable), TKL=1
      0x01'u8,                                      # Code 0.01 (GET)
      0x12'u8, 0x34'u8,                             # Message ID 0x1234
      0x0a'u8,                                      # Token
      0xb4'u8,                                      # Delta=11, Len=4
      0x74'u8, 0x65'u8, 0x6d'u8, 0x70'u8,           # "temp"
      0xd1'u8,                                      # Delta=13, Len=1
      0x03'u8,                                      # Extended delta value 3 (option number 27)
      0x00'u8,                                      # Value
      0xff'u8,                                      # Payload marker
      0x50'u8, 0x41'u8, 0x59'u8                     # Payload "PAY"
    ]
    let h = parseCoapHeader(data)
    let start = 4 + int(h.tokenLength)
    let (options, payload) = parseCoapOptions(data[start .. ^1])
    check options.len == 2
    check options[0].number == 11 and options[0].value == @[0x74'u8, 0x65'u8,
        0x6d'u8, 0x70'u8]
    check options[1].number == 27 and options[1].value == @[0x00'u8]
    check payload == @[0x50'u8, 0x41'u8, 0x59'u8]
