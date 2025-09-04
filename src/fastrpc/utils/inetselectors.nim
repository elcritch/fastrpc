import std/selectors
from os import OSErrorCode

import inetqueues
import logging
import tables

export inetqueues

## Selector setup for ease of use with user events and timers
## 

type
  EventSelector* = object
    raw*: Selector[InetEvent]

  InetEvent* = object
    case kind: selectors.Event
    of Event.Timer:
      timeout: int
      oneshot: bool
      timerfd: int
    of Event.User:
      se: SelectEvent
    of Event.Signal:
      sig: int
    of Event.Error:
      errfd: int
      errorCode*: OSErrorCode
    else:
      discard

proc `==`*(a: InetEvent; b: InetEvent): bool =
  if a.kind == b.kind:
    case a.kind
    of Event.Timer:
      return a.timeout == b.timeout and a.oneshot == b.oneshot and a.timerfd == b.timerfd
    of Event.User:
      return a.se == b.se
    of Event.Signal:
      return a.sig == b.sig
    of Event.Error:
      return a.errfd == b.errfd and a.errorCode == b.errorCode
    else:
      true
  else:
    return false

proc newEventSelector*(): EventSelector =
  # Setup and run a new SocketServer.
  result = EventSelector(raw: newSelector[InetEvent]())

proc registerEvent*(selector: EventSelector, event: SelectEvent): InetEvent {.discardable.} =
  result = InetEvent(kind: Event.User, se: event)
  selector.raw.registerEvent(event, result)

proc registerQueue*[T](selector: EventSelector, queue: InetEventQueue[T]): InetEvent {.discardable.} =
  result = selector.registerEvent(queue.evt)

when defined(linux):
  proc registerTimer*(selector: EventSelector, timeout: int, oneshot: bool): InetEvent {.discardable.} =
    let fd = selector.raw.registerTimer(timeout, oneshot, InetEvent())
    result = InetEvent(kind: Event.Timer, timeout: timeout, oneshot: oneshot, timerfd: fd)
    if not selector.raw.setData(fd, result):
      # todo: is this the ideal behavior?
      selector.raw.unregister(fd)
      raise newException(AssertionDefect, "failed to register timer properly")

template withEvent*(events: Table[InetEvent, ReadyKey], event: InetEvent, asKey: untyped, code: untyped) =
  ## helper function just to check for a given event and return it's key
  var `asKey` {.inject.}: ReadyKey
  if events.pop(event, `asKey`):
    `code`


template loop*(selector: EventSelector, timeout: Millis, events: Table[InetEvent, ReadyKey], code: untyped)  =
  while true:
    events.clear()
    let keys: seq[ReadyKey] = selector.raw.select(timeout.int)
    # logDebug "[selector]::", "keys:", repr(keys)
    for key in keys:
      if Event.Error in key.events or key.errorCode.int != 0:
        let errItem = InetEvent(kind: Event.Error, errfd: key.fd, errorCode: key.errorCode)
        events[errItem] = key
      else:
        let item: InetEvent = selector.raw.getData(key.fd)
        events[item] = key
    `code`

template loopEvents*(
    selector: Selector[Event],
    timeout: Millis,
    userHandler: proc (selector: Selector[Event], key: ReadyKey) = nil,
    readHandler: proc (selector: Selector[Event], key: ReadyKey) = nil,
) =
  while true:
    var keys {.inject.}: seq[ReadyKey] = selector.select(timeout.int)
    logDebug "[selector]::", "keys:", repr(keys)
    `code`
  
    for key in keys:
      logDebug "[selector]::", "key:", repr(key)
      if Event.Read in key.events:
        if not readHandler.isNil: readHandler(selector, key)
      if Event.User in key.events:
        if not userHandler.isNil: readHandler(selector, key)
      if Event.Write in key.events:
        if not writeHandler.isNil: readHandler(selector, key)

