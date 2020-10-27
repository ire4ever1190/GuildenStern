import guildenserver

import selectors, net, nativesockets, os, httpcore, posix

when compileOption("threads"): import threadpool


proc process(gs: ptr GuildenServer, fd: posix.SocketHandle, data: ptr SocketData) {.gcsafe, raises: [].} =
  if gs.serverstate == Shuttingdown: return
  if data.handlertype == InvalidHandling: return
  data.socket = fd
  handleRead(gs, data)
  if gs.selector.contains(fd):
    try:
      gs.selector.updateHandle(fd, {Event.Read})
    except:
      echo "updateHandle error: " & getCurrentExceptionMsg()
  else:
    closeFd(gs, fd)


template handleAccept(theport: uint16) =
  var porthandler = 0
  while gs.porthandlers[porthandler].port != theport.int: porthandler += 1
  let fd = fd.accept()[0]
  if fd == osInvalidSocket: return
  if gs.selector.contains(fd):
    #return
    echo "oli jo"
    if not gs.selector.setData(fd, SocketData(port: gs.porthandlers[porthandler].port.uint16, handlertype: gs.porthandlers[porthandler].handlertype)): return
  else:
    gs.selector.registerHandle(fd, {Event.Read}, SocketData(port: gs.porthandlers[porthandler].port.uint16, handlertype: gs.porthandlers[porthandler].handlertype))
  var tv = (RcvTimeOut,0)
  if setsockopt(fd, cint(SOL_SOCKET), cint(RcvTimeOut), addr(tv), SockLen(sizeof(tv))) < 0'i32:
    gs.selector.unregister(fd)
    raise newException(CatchableError, osErrorMsg(event.errorCode))


template handleEvent() =
  if data.handlertype == ServerHandling:
    try:
      handleAccept(data.port)
    except:
      if osLastError().int != 2 and osLastError().int != 9: echo "connect error: " & getCurrentExceptionMsg()
    continue

  if not gs.multithreading: process(unsafeAddr gs, fd, data)
  else:
    try: gs.selector.updateHandle(fd, {})
    except:
      echo "updateHandle error: " & getCurrentExceptionMsg()
      continue
    when compileOption("threads"): spawn process(unsafeAddr gs, fd, data)
  

proc eventLoop(gs: GuildenServer) {.gcsafe, raises: [].} =
  var eventbuffer: array[1, ReadyKey]
  while true:
    try:
      var ret: int
      try:
        {.push assertions: on.} # otherwise selectInto panics?
        ret = gs.selector.selectInto(-1, eventbuffer)
        {.pop.}
      except: discard    
      if gs.serverstate == Shuttingdown: break
      if ret != 1 or eventbuffer[0].events.len == 0:
        sleep(0) 
        continue
      
      let event = eventbuffer[0]
      if Event.Signal in event.events: break
      if Event.Timer in event.events:
        assert(false, "not implemented")
        ##{.gcsafe.}: gs.timerHandler()
        continue
      let fd = posix.SocketHandle(event.fd)
      var data: ptr SocketData        
      try:
        {.push warning[ProveInit]: off.}
        data = addr(gs.selector.getData(fd))
        {.pop.}
        if data == nil: continue
      except:
        echo "selector.getData error: " & getCurrentExceptionMsg()
        break

      if Event.Error in event.events:
        if data.handlertype == ServerHandling: echo "server error: " & osErrorMsg(event.errorCode)
        else:
          if event.errorCode.cint != ECONNRESET: echo "socket error: " & osErrorMsg(event.errorCode)
          closeFd(unsafeAddr gs, fd)
        continue

      if Event.Read notin event.events:
        try:
          if gs.selector.contains(fd): gs.selector.unregister(fd)
          nativesockets.close(fd)
        except: discard
        finally: continue
      handleEvent()
    except: continue
  gs.serverstate = ShuttingDown


proc serve*(gs: GuildenServer, multithreaded = true) {.gcsafe, nimcall.} =
  gs.multithreading = multithreaded
  if multithreaded:
    doAssert(compileOption("threads"))
    doAssert(defined(threadsafe), "Selectors module requires compiling with -d:threadsafe")
  gs.selector = newSelector[SocketData]()
  {.gcsafe.}:
    for i in 0 ..< gs.portcount:
      let server = newSocket()
      server.setSockOpt(OptReuseAddr, true)
      server.setSockOpt(OptReusePort, true)
      try:
        server.bindAddr(net.Port(gs.porthandlers[i].port), "")
      except:
        echo "Could not open port ", gs.porthandlers[i].port
        raise
      gs.selector.registerHandle(server.getFd(), {Event.Read}, SocketData(port: gs.porthandlers[i].port.uint16, handlertype: ServerHandling))
      server.listen()
  
  discard gs.selector.registerSignal(SIGINT, SocketData(handlertype: SignalHandling))
  {.gcsafe.}: signal(SIG_PIPE, SIG_IGN)
  
  gs.serverstate = Normal
  eventLoop(gs)
  echo ""      
  {.gcsafe.}:
    if gs.shutdownHandler != nil: gs.shutdownHandler()
  quit(0)