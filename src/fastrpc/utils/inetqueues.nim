
import std/isolation
import std/selectors
import threading/smartptrs
import threading/channels

import ./msgbuffer
import ./inettypes

export isolation
export msgbuffer, inettypes
export channels, smartptrs
export selectors

type
  QMsgBuffer* = UniquePtr[MsgBuffer]
    ## Wrapper around a MsgBuffer to ensure the underlying
    ## data string remains isolated
    ## Note: this works but the MsgBuffer type
    ## should be redone to make this better.

  InetQueueItem*[T] = ref object
    ## Queue item to allow passing data and an network address
    ## as an atomic pointer so it's thread safe. 
    ## 
    ## This helps reduce bookkeeping for keeping around
    ## things like UDP addresses.
    cid*: InetClientHandle
    data*: T

  InetMsgQueueItem* = InetQueueItem[QMsgBuffer]
    ## default queue item variant for passing around msg buffers


type
  InetEventQueue*[T] = ref object
    ## Queue that uses a channel for passing data with
    ## the a SelectEvent in order to notify a `std/selector`
    ## based system of new data.
    evt*: SelectEvent # eventfds
    chan*: Chan[T]

  InetMsgQueue* = InetEventQueue[InetMsgQueueItem]
    ## default network event queue using QMsgBuffer's 
    ## for passing buffer data around. 
  
proc newQMsgBuffer*(size: int): QMsgBuffer =
  result = newUniquePtr(MsgBuffer.init(size))

proc newQMsgBuffer*(data: sink string, pos: int = 0): QMsgBuffer =
  result = newUniquePtr(MsgBuffer.init(data))

proc newQMsgBuffer*(mbuf: sink MsgBuffer): QMsgBuffer =
  result = newQMsgBuffer(mbuf.data, mbuf.getPosition())

proc newInetQueueItem*[T](cid: InetClientHandle, data: sink T): InetQueueItem[T] =
  new(result)
  result.cid = cid
  result.data = move data

proc init*[T](x: typedesc[InetQueueItem[T]], cid: InetClientHandle, data: sink T): InetQueueItem[T] =
  result = newInetQueueItem[T](cid, data)

proc init*(x: typedesc[InetMsgQueueItem], cid: InetClientHandle, data: sink QMsgBuffer): InetMsgQueueItem =
  result = newInetQueueItem[QMsgBuffer](cid, data)

proc newInetEventQueue*[T](size: int): InetEventQueue[T] =
  new(result)
  result.evt = newSelectEvent()
  result.chan = newChan[T](size)

proc init*[T](x: typedesc[InetEventQueue[T]], size: int): InetEventQueue[T] =
  result = newInetEventQueue[T](size)

proc init*(x: typedesc[InetMsgQueue], size: int): InetMsgQueue =
  result = newInetEventQueue[InetMsgQueueItem](size)

proc getEvent*[T](q: InetEventQueue[T]): SelectEvent =
  result = q.evt

proc send*[T](rq: InetEventQueue[T], item: sink Isolated[T], trigger=true) =
  rq.chan.send(item)
  if trigger:
    rq.evt.trigger()

proc trigger*[T](rq: InetEventQueue[T]) =
  rq.evt.trigger()

template send*[T](rq: InetEventQueue[T], item: T, trigger=true) =
  send(rq, isolate(item), trigger)

proc trySend*[T](rq: InetEventQueue[T], item: var Isolated[T], trigger=true): bool =
  let res: bool = channels.trySend(rq.chan, move item)
  if res and trigger:
    try:
      rq.evt.trigger()
    except CatchableError:
      return false
  res

template trySend*[T](rq: InetEventQueue[T], item: T, trigger=true): bool =
  var isoItem = isolate(item)
  rq.trySend(isoItem, trigger)

proc recv*[T](rq: InetEventQueue[T]): T =
  channels.recv(rq.chan, result)

template tryRecv*[T](rq: InetEventQueue, item: var T): bool =
  rq.chan.tryRecv(item)

## InetMsgQueue alias pre-defines
## 

proc sendMsg*(rq: InetMsgQueue, cid: InetClientHandle, data: sink QMsgBuffer) =
  var item = isolate InetMsgQueueItem.init(cid, data)
  send(rq, item)

template trySendMsg*(rq: InetMsgQueue, cid: InetClientHandle, data: var QMsgBuffer): bool =
  var item = isolate InetMsgQueueItem.init(cid, data)
  trySend(rq, item)

proc recvMsg*(rq: InetMsgQueue): InetMsgQueueItem =
  result = recv(rq)

template tryRecvMsg*(rq: InetEventQueue, item: var InetMsgQueueItem): bool =
  tryRecv(rq, item)
