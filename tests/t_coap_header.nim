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
