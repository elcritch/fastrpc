import tables
import ../utils/msgbuffer
import ../utils/inettypes
import ../utils/inetqueues
import stack_strings

export tables, inettypes, inetqueues, msgbuffer, stack_strings

const MaxRpcMethodNameLength* {.intdefine: "fastrpc.maxMethodNameLength".} = 32

when defined(fastRpcStackStrings):
  type
    RpcMethodName* = StackString[MaxRpcMethodNameLength]
else:
  type
    RpcMethodName* = string

type
  FastErrorCodes* = enum
    # Error messages
    FAST_PARSE_ERROR = -27
    INVALID_REQUEST = -26
    METHOD_NOT_FOUND = -25
    INVALID_PARAMS = -24
    INTERNAL_ERROR = -23
    SERVER_ERROR = -22

  FastRpcParamsBuffer* = object
    ## implementation specific -- handles data buffer
    buf*: MsgBuffer 


type
  FastRpcType* {.size: sizeof(uint8).} = enum
    # Fast RPC Types
    Request       = 5
    Response      = 6
    Notify        = 7
    Error         = 8
    Subscribe     = 9
    Publish       = 10
    SubscribeStop = 11
    PublishDone   = 12
    SystemRequest = 19
    Unsupported   = 23
    # rtpMax = 23 # numbers less than this store in single mpack/cbor byte

  FastRpcId* = int

  FastRpcRequest* = object
    kind*: FastRpcType
    id*: FastRpcId
    procName*: RpcMethodName
    params*: FastRpcParamsBuffer # - we handle params below

  FastRpcResponse* = object
    kind*: FastRpcType
    id*: int
    result*: FastRpcParamsBuffer # - we handle params below

  FastRpcError* = ref object
    code*: FastErrorCodes
    msg*: string
    trace*: seq[(string, string, int)]

proc toMethodName*(s: string): RpcMethodName =
  when defined(fastRpcStackStrings):
    result = s.toStackString(MaxRpcMethodNameLength)
  else:
    result = s

proc toString*(s: RpcMethodName): string =
  when defined(fastRpcStackStrings):
    result = stack_strings.toString(s)
  else:
    result = s
