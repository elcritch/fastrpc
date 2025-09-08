# FastRPC

FastRPC is a both a library and a RPC protocol specification written in portable Nim code. The RPC protocol uses MessagePack with goals to be portable, relatively lightweight, and fast as possible. The code can run on Zephyr or FreeRTOS/LwIP while also capable and tested to run on Linux (not other *nixs currently). 

Generally it's intended to support datagram transports, but an optional framing (see Notes below) mechanism can be used to work with stream based transports.

## FastRPC Protocol

The FastRPC protocol is based on a variant of [MessagePack-RPC](https://github.com/msgpack-rpc/msgpack-rpc/blob/master/spec.md) however it has several incompatible changes partially to simplify implementation on microcontrollers.

### MessagePack-RPC Protocol specification

The general protocol consists of `Request` messages and corresponding `Response` message(s). The server must send a `Response` message in reply to a request unless the request type indicates that no response is expected.

The protocol and server implementation generally assume that each packet can fit into the physical media's [MTU](https://en.wikipedia.org/wiki/Maximum_transmission_unit). On Ethernet this is generally 1500 bytes less the space used by the UDP (or TCP) packets. While WiFI [802.11 MTU](https://networkengineering.stackexchange.com/questions/32970/what-is-the-802-11-mtu) is 2304 bytes with various overheads depending on the security settings. The smallest use case is probably [CAN-FD](https://en.wikipedia.org/wiki/CAN_FD) which is 64 bytes (that's the large one). This can be configured.

#### `Request` Messages

The request message is a four element array as shown below, packed in MessagePack format.

```nim
  [reqType, msgId, procName, params]
```

The fields are:

1. `reqType: int8` request message type (current valid request values are `5,7,9,19`)
2. `msgId: int32` sequence number for client to track (async) responses
3. `procName: string` name of the procedure (method) to call
4. `params: array[MsgPackNodes]` an array of parameters of arbitrary MsgPack data. 

The supported types of requests are:
- `Request = 5`
- `Notify = 7`
- `Subscribe = 9`
- `SubscribeStop  = 11`
- `System = 19`

Note: `params` **must** be an array. Passing maps will return an error. The params in the array match the order of the arguments in a function call which is very fast to parse. Maps could be handled but would require handling out-of-order fields and strings which requires more overhead. 

#### `Response` Messages

Response messages are a three element array as shown below, packed in MsgPack format.

```nim
  [respType, msgId, result]
```

The fields are:

1. `respType: int8` response message type
2. `msgId: int32` sequence number for client to track responses, including async/streams
3. `result: MsgPackNodes` Arbitray packed MsgPack data


The supported types of responses are:
- `Response = 6`
- `Error = 8`
- `Publish = 10`
- `PublishDone = 12`

Note: the `result` field is used to store errors when the response type is `Error (8)`.

#### Basic Request Lifecycle

The client will send a `Request` packet to the server. When UDP is used the server will respond on the source UDP IP & Port. Stream transports return to the same stream.

The server will process the RPC proc and return a `Response` message, unless it encounters an error where the `Error` response type will be sent. It's up to the client to handle these as desired.

The `SystemRequest` is identical to `Request` except that is supports server specific *system* calls. By default this includes methods like `listall` that return all RPC methods handled by the server. API's like *reboot* should likely be a `SystemRequest`. The server may want to require extra security tokens for this case.


#### Protocol Semantics / Other Details

TCP packets and UDP packets are treated slightly differently. TCP streams can be used to send/recv larger data than the underlying framesize but is discouraged. Prefer to use `Publish` responses, which are valid to return from normal `Request`.


### Example

To call `add(int, int)` on a FastRPC server, you'd generate a `Request` message:

```nim
const Request = 5
var callId = 1
var msg = (Request, callId, "add", (1,2)) 
assert msg == (5, 1, "add", (1,2))
```

This would then be serialized using a MsgPack library:

```nim
var msgbinary = pack(msg)
assert msgbinary == "\148\5\1\163add\146\1\2"
assert msgbinary == "\x94\x05\x01\xA3add\x92\x01\x02" # hex format
```

The response message would be:
```nim
assert responseMsg == "\147\6\1\3"
var response = unpack(responseMsg)

assert response == [6, 1, 3]
assert response == [Response, 1, 3]

let answer = 3
assert answer == response[2]
```

When using a stream transport you'd need to prefix the message length:
```nim
var tcpMsgBinary = msgbinary.len().toBeInt16() & msgbinary
assert msgbinary == "\0\10" & "\148\5\1\163add\146\1\2"
assert msgbinary == "\0\10\148\5\1\163add\146\1\2"
```

### Subscriptions

TODO: these function but need work finish describing the API and how to use them

Subscription semantics have been added using the `Subscribe` and `Publish` request types described above. These requests work differently than the regular `Request` kinds. The request type needs to be `Subscribe` with the RPC name and any arguements for starting a subscription stream. The return type isn't a normal RPC response but a response from the server that returns a `subscription id` (`SubId` in the code) if the subscription succeeded. TODO: describe the data format for the `subscription id`.

Any responses from this subscription will use the `subscription id` instead of the original `msgid`. Multiple client's can subscribe to the _same_ stream in this way. It also works well with multicast stream data.

In the future clients can send `SubscribeStop` with RPC name and `subscription id` as the data to stop the stream. The server can also send a `PublishDone` response to indicate to the client that the stream is finished. This can be useful for long running RPC's that need to send lots of data back.


## Notes

### Alternative Packing

It would be possible to use this RPC Protocol with CBOR as the serialization protocol. Everything above would apply but instread using CBOR.

### Using Streams with Framing

When using TCP, Unix domain sockets, serial, or other stream based connections a simple framing scheme is used to delineate messages. Each message must be prefixed by a bye-length in big-endian order. This is copied from [Erlang port protocol](https://www.erlang.org/doc/tutorial/c_port.html) for similar reasons.

Note: The default prefix length is 2-byte for messages up to ~65k in length, however, MCUs generally don't gracefully handle packets larger than transport frame size (e.g. ~1400 bytes on ethernet).

In theory, websocket framing could be used but isn't.

This method of framing isn't optimal for noisy data streams such as serial connections, though using timeouts and resets it'd be possible to retry RPC calls over it. In this case you may want to investigate something like [SLIP](https://en.wikipedia.org/wiki/Serial_Line_Internet_Protocol) that provides a more resiliant packeting mechanism.

#### Stream (TCP) Framing Example

The stream response (TCP) message would be:
```nim
var tcpResponseMsg = "\0\4\147\6\1\3"
var responseLen = rcpResponseMsg[0..1] # get byte size prefix
var responseMsg = rcpResponseMsg[2..^1] # slice off byte size prefix
assert responseMsg == "\147\6\1\3"
```

Note that reading from a stream with BSD sockets requires using an idiom like: 
```nim
var pktLen = socket.read(2)
var msg = ""
while msg.len() < pktLen:
  msg.add socket.read(pktLen - msg.len())
```
