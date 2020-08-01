import x11/xlib, x11/xutil, x11/x, x11/keysym
import threadpool, osproc, tables, sequtils, posix, strformat, os, sugar, options, strutils

var root : TWindow

proc handleBadWindow(display : PDisplay, ev : PXErrorEvent) : cint {.cdecl.} =
  # resourceID maps to the Window's XID
  # ev.resourceID
  echo "Bad window", ": ", ev.resourceid
  0

proc handleIOError(display : PDisplay) : cint {.cdecl.} =
  0

proc cstringToNim(cst : cstring) : Option[string] =
  var nst = newString(cst.len)
  if nst.len > 0:
    copyMem(addr(nst[0]), cst, cst.len)
    return some(nst)
  none(string)

template HandleKey(key : TKeySym, body : untyped) : untyped =
    block:
      if (XLookupKeySym(cast[PXKeyEvent](ev.xkey.addr), 0) == key.cuint):
        body

type
  WinPropKind = enum pkString, pkCardinal, pkAtom
  WinProp = ref object of RootObj
    name : string
    case kind: WinPropKind
      of pkString: strProp : string
      of pkCardinal: cardinalProp : seq[uint]
      of pkAtom: atomProps : seq[string]

type Window = ref object of RootObj
  x : cint
  y : cint
  width : cint
  height : cint
  win : TWindow
  screen : PScreen
  props : seq[WinProp]

proc unpackPropValue(typeFormat : int,
                     nItems : int,
                     buf : ptr cuchar) : seq[uint] =

  # See https://www.x.org/releases/current/doc/man/man3/XGetWindowProperty.3.xhtml

  var byte_stride : int

  case typeFormat
    of 8:
      byte_stride = (ptr cuchar).sizeof.int
    of 16:
      byte_stride = (ptr cshort).sizeof.int
    of 32:
      byte_stride = (ptr clong).sizeof.int
    else:
      return @[]

  for i in 0..(nItems - 1):
    let currentItem = cast[int](buf) + cast[int](i * byte_stride)

    case typeFormat
      of 8:
        result &= cast[ptr cuchar](currentItem)[].uint
      of 16:
        result &= cast[ptr cshort](currentItem)[].uint
      of 32:
        result &= cast[ptr clong](currentItem)[].uint
      else:
        continue

proc getPropertyValue(display : PDisplay, window : TWindow, property : TAtom) : Option[WinProp] =
  let longOffset : clong = 0.clong
  let longLength : clong = high(int) # max length of the data to be returned

  var actualType : TAtom
  var actualTypeFormat : cint
  var nItemsReturn : culong
  var bytesAfterReturn : culong
  var propValue : ptr cuchar

  var currentAtomName = display.XGetAtomName(property)
  var atomName = cstringToNim(currentAtomName)

  if atomName.isNone:
    quit(fmt"Could not allocate atomName for some reason")

  discard currentAtomName.XFree

  discard display.XGetWindowProperty(window,
                                     property,
                                     longOffset,
                                     longLength,
                                     false.cint,
                                     AnyPropertyType.TAtom,
                                     actualType.addr,
                                     actualTypeFormat.addr,
                                     nItemsReturn.addr,
                                     bytesAfterReturn.addr,
                                     propValue.addr)

  if actualTypeFormat == 0:
    # Invalid type
    return none(WinProp)

  let typeName = display.XGetAtomName(actualType)

  if typeName == "STRING":
    var propStrValue = cstringToNim(propValue)
    if propStrValue.isSome:
      result = some(WinProp(name: atomName.get, kind: pkString, strProp: propStrValue.get))
    else:
      result = none(WinProp)
  elif typeName == "CARDINAL":
    result = some(
              WinProp(
                name: atomName.get,
                kind: pkCardinal,
                cardinalProp: unpackPropValue(actualTypeFormat.int, nItemsReturn.int, propValue)
              )
            )
  elif typeName == "ATOM":
    var currentAtomName : cstring
    var atomPropNames : seq[string]

    for atom in unpackPropValue(actualTypeFormat.int, nItemsReturn.int, propValue):
      let atomPropNameCS = display.XGetAtomName(atom.culong)
      var atomPropName = cstringToNim(atomPropNameCS)
      if atomPropName.isSome:
        atomPropNames &= atomPropName.get

      discard atomPropNameCS.XFree

    result = some(
              WinProp(
                name: atomName.get,
                kind: pkAtom,
                atomProps: atomPropNames
              )
            )
  else:
    result = none(WinProp)

  discard propValue.XFree

  return

iterator getProperties(display : PDisplay, window : TWindow) : Option[WinProp] =
  # Get property names/values of a given window on a display
  var nPropsReturn : cint

  # pointer to a list of word32
  var atoms : PAtom = display.XListProperties(window, nPropsReturn.addr)
  var currentAtom : PAtom

  # Iterate over the list of atom names
  for i in 0..(nPropsReturn.int - 1):
    currentAtom = cast[PAtom](
      cast[int](atoms) + cast[int](i * currentAtom[].sizeof)
    )

    yield display.getPropertyValue(window, currentAtom[])

  discard atoms.XFree

proc getAttributes(display : PDisplay, window : PWindow) : Option[TXWindowAttributes] =
  var attrs : TXWindowAttributes
  if display.XGetWindowAttributes(window[], attrs.addr) == BadWindow:
    return none(TXWindowAttributes)
  return some(attrs)

proc changeEvMask(display : PDisplay, window : PWindow, eventMask : clong) =
  var attributes : TXSetWindowAttributes
  attributes.eventMask = eventMask
  discard display.XChangeWindowAttributes(window[], CWEventMask, attributes.addr)

iterator getChildren(display : PDisplay) : Window =
  var currentWindow : PWindow
  var rootReturn : TWindow
  var parentReturn : TWindow
  var childrenReturn : PWindow
  var nChildrenReturn : cuint

  discard XQueryTree(display,
                     root,
                     rootReturn.addr,
                     parentReturn.addr,
                     childrenReturn.addr,
                     nChildrenReturn.addr)


  for i in 0..(nChildrenReturn.int - 1):

    currentWindow = cast[PWindow](
      cast[int](childrenReturn) + cast[int](i * currentWindow.sizeof)
    )

    let attr : Option[TXWindowAttributes] = getAttributes(display, currentWindow)

    if attr.isNone:
      continue

    if attr.get.map_state == IsUnmapped or attr.get.map_state == IsUnviewable:
      continue

    if attr.get.override_redirect == 1:
      continue

    let props = map(toSeq(getProperties(display, currentWindow[])).filterIt(it.isSome), (p) => p.get)

    let win = Window(
      x: attr.get.x.cint,
      y: attr.get.y.cint,
      width: attr.get.width,
      height: attr.get.height,
      win: currentWindow[],
      screen: attr.get.screen,
      props: props
    )

    for prop in props:
      if prop.kind == pkCardinal:
        if prop.name.startsWith("_NET_WM_STRUT"):
          echo prop.name, ": ", prop.cardinalProp
        elif prop.name.startsWith("_NET_WM_OPAQUE"):
          echo prop.name, ": ", prop.cardinalProp
        else:
          echo prop.name, prop.kind
      if prop.kind == pkAtom:
        echo "Atoms = ", prop.atomProps

    yield win

  discard XFree(childrenReturn)

proc getDisplay : PDisplay =
  result = XOpenDisplay(nil)
  if result == nil:
    quit("Failed to open display")

proc grabMouse(display : PDisplay, button : int) =
  discard XGrabButton(display,
                      button.cuint,
                      Mod1Mask.cuint,
                      DefaultRootWindow(display),
                      1.cint,
                      ButtonPressMask or ButtonReleaseMask or PointerMotionMask,
                      GrabModeAsync,
                      GrabModeAsync,
                      None,
                      None)

proc grabKeyCombo(display : PDisplay,
                  key : TKeySym,
                  masks : seq[cuint] = @[]) =

  # The reason we have 4 XGrabKey calls here is that
  # the user might have num lock on
  # and we still want to be able to grab these key combos
  discard XGrabKey(display,
                   XKeySymToKeyCode(display, key).cint,
                   foldr(@[Mod1Mask.cuint] & masks, a or b),
                   DefaultRootWindow(display),
                   1.cint,
                   GrabModeAsync.cint,
                   GrabModeAsync.cint)
  discard XGrabKey(display,
                   XKeySymToKeyCode(display, key).cint,
                   foldr(@[Mod1Mask.cuint, Mod2Mask.cuint] & masks, a or b),
                   DefaultRootWindow(display),
                   1.cint,
                   GrabModeAsync.cint,
                   GrabModeAsync.cint)
  discard XGrabKey(display,
                   XKeySymToKeyCode(display, key).cint,
                   foldr(@[Mod1Mask.cuint, LockMask.cuint] & masks, a or b),
                   DefaultRootWindow(display),
                   1.cint,
                   GrabModeAsync.cint,
                   GrabModeAsync.cint)
  discard XGrabKey(display,
                   XKeySymToKeyCode(display, key).cint,
                   foldr(@[Mod1Mask.cuint, LockMask.cuint, Mod2Mask.cuint] & masks, a or b),
                   DefaultRootWindow(display),
                   1.cint,
                   GrabModeAsync.cint,
                   GrabModeAsync.cint)


# When spawning a new process:
#   Create an entry in a table or set with the PID
#   Create a thread that simple waits for it to exit
#   Send a message via channel to the main thread when it's done waiting for it to exit
#   Check for events on the current iteration, close the process, remove it from the set of open processes

# Used to signal when a process has exited
# Obviously only used for processes nimwin manages
var processChan : Channel[int]

processChan.open(0)

proc startTerminal() : Process =
  let terminal_path = getEnv("NIMWIN_TERMINAL", "/usr/bin/urxvt")
  startProcess(terminal_path, "", ["-e", "tmux"])

proc launcher() : Process =
  let launcher_path = getEnv("NIMWIN_LAUNCHER", "/usr/bin/dmenu_run")
  startProcess(launcher_path)

proc handleProcess(p : Process) =
  discard p.waitForExit
  processChan.send(p.processID)

proc calculateStruts(display : PDisplay) : tuple[top: uint, bottom: uint]=
  for win in getChildren(display):
    for prop in win.props:
      if prop.kind == pkCardinal and prop.name.startsWith("_NET_WM_STRUT"):
        result.top = max(result.top, prop.cardinalProp[2])
        result.bottom = max(result.bottom, prop.cardinalProp[3])


proc shouldTrackWindow(window : Window) : bool =
  let ignored = @["_NET_WM_STRUT_PARTIAL", "_NET_WM_STRUT"]
  if window.props.anyIt(it.name.in(ignored)):
    return false

  for prop in window.props:
    if prop.kind == pkAtom:
      for atomValue in prop.atomProps:
        if atomValue == "_NET_WM_STATE_STICKY":
          return false
  return true

proc getWMProtocols(window : Window) : Option[seq[string]] =
  for prop in window.props:
    if prop.kind == pkAtom and prop.name == "WM_PROTOCOLS":
      return some(prop.atomProps)
  none(seq[string])

proc deleteWindow(display : PDisplay, window : Window) =
  let protocols = window.getWMProtocols

  if protocols.isSome and ("WM_DELETE_WINDOW" in protocols.get):
    var deleteEvent : TXEvent

    deleteEvent.xclient.theType = ClientMessage
    deleteEvent.xclient.window = window.win
    deleteEvent.xclient.messageType = display.XInternAtom("WM_PROTOCOLS".cstring, true.TBool)
    deleteEvent.xclient.format = 32
    deleteEvent.xclient.data.l[0] = display.XInternAtom("WM_DELETE_WINDOW".cstring, false.TBool).clong
    deleteEvent.xclient.data.l[1] = CurrentTime

    discard display.XSendEvent(window.win, false.TBool, NoEventMask, deleteEvent.addr)
  else:
    discard display.XDestroyWindow(window.win)

when isMainModule:
  discard "~/.nimwin".expandTilde.existsOrCreateDir

  var logFile : File = expandTilde("~/.nimwin/nimwin_log").open(fmWrite)
  logFile.writeLine("Starting Nimwin")

  var start : TXButtonEvent
  var ev : TXEvent
  var attr : TXWindowAttributes

  let display = getDisplay()
  let displayNum = display.DisplayString

  logFile.writeLine(fmt"Opened display {displayNum}")

  root = DefaultRootWindow(display)

  display.changeEvMask(root.addr, SubstructureNotifyMask or StructureNotifyMask)

  display.grabKeyCombo(XK_Return, @[ShiftMask.cuint])
  display.grabKeyCombo(XK_T, @[ShiftMask.cuint])
  display.grabKeyCombo(XK_Tab) # Cycle through windows
  display.grabKeyCombo(XK_Q) # Restart window manager
  display.grabKeyCombo(XK_P) # Launcher
  display.grabKeyCombo(XK_T) # Full screen
  display.grabKeyCombo(XK_C, @[ShiftMask.cuint]) # CLose a window
  display.grabMouse(1)
  display.grabMouse(3)

  start.subWindow = None

  var openProcesses = initTable[int, Process]() # hashset of processes

  discard XSetErrorHandler(handleBadWindow)
  discard XSetIOErrorHandler(handleIOError)

  while true:
    let processExited = processChan.tryRecv()

    if processExited.dataAvailable:
      openProcesses[processExited.msg].close
      openProcesses.del(processExited.msg)

    # TODO refactor using XPending or XCB?
    discard XNextEvent(display, ev.addr)

    # The reason we look at the subwindow is because we grabbed the root window
    # and we want events in its children
    # For spawning, e.g. a terminal we also want events for the root window

    if ev.theType == KeyPress:
      HandleKey(XK_Return):
        let p = startTerminal()
        openProcesses[p.processID] = p
        spawn handleProcess(p)

      HandleKey(XK_C):
        let windowStack = toSeq(getChildren(display))
        if windowStack.len > 0:
          display.deleteWindow(windowStack[^1])

      HandleKey(XK_Tab):
        if ev.xKey.subWindow != None:
          # Cycle through subwindows of the root window
          #discard XCirculateSubwindows(display, root, RaiseLowest)
          #discard display.XFlush()

          let windowStack = filter(toSeq(getChildren(display)), shouldTrackWindow)

          if windowStack.len > 0:
            discard display.XSetInputFocus(windowStack[0].win, RevertToPointerRoot, CurrentTime)
            discard display.XRaiseWindow(windowStack[0].win)

      HandleKey(XK_P):
        let p = launcher()
        openProcesses[p.processID] = p
        spawn handleProcess(p)

      HandleKey(XK_Q):
        let currentPath = getAppDir()

        if fmt"{currentPath}/nimwin".existsFile:
          logFile.writeLine("Trying to restart Nimwin")
          logFile.writeLine(fmt"Restarting: executing {currentPath}/nimwin on display={displayNum}")
          logFile.flushFile

          discard display.XCloseDisplay

          let restartResult = execvp(fmt"{currentPath}/nimwin".cstring, nil)

          if restartResult == -1:
            quit("Failed to restart Nimwin")

      HandleKey(XK_T):

        # Get all of the struts with offsets from the top
        # Get all of the struts with offsets from the bottomm
        # and the left and the right
        #
        # then subtract the max of the offsets from the top from the screenHeight
        #
        if ev.xKey.subWindow != None:
          let rootAttrs = getAttributes(display, root.addr)

          if rootAttrs.isSome:
            let struts = display.calculateStruts
            let screenHeight = rootAttrs.get.height
            let screenWidth = rootAttrs.get.width

            let winAttrs : Option[TXWindowAttributes] = getAttributes(display, ev.xKey.subWindow.addr)

            let borderWidth = winAttrs.get.borderWidth.cuint

            discard XMoveResizeWindow(display,
                                      ev.xKey.subWindow,
                                      struts.bottom.cint, struts.top.cint,
                                      screenWidth.cuint, screenHeight.cuint - struts.top.cuint - struts.bottom.cuint)


    elif (ev.theType == ButtonPress) and (ev.xButton.subWindow != None):
      discard XGetWindowAttributes(display, ev.xButton.subWindow, attr.addr)
      start = ev.xButton

    elif (ev.theType == MapNotify) and (ev.xmap.override_redirect == 0):
      var ignore = false

      let rootAttrs = getAttributes(display, root.addr)
      if rootAttrs.isSome:
        let struts = display.calculateStruts
        let screenHeight = rootAttrs.get.height
        let screenWidth = rootAttrs.get.width

        let winAttrs : Option[TXWindowAttributes] = getAttributes(display, ev.xcreatewindow.window.addr)

        if winAttrs.isSome and winAttrs.get.override_redirect == 0:
          for prop in getProperties(display, ev.xmap.window):
            if prop.isSome and prop.get.kind == pkCardinal:
              if prop.get.name.startsWith("_NET_WM_STRUT"):
                # Ignore struts
                ignore = true
                break
            if prop.isSome and prop.get.kind == pkAtom:
              for atomValue in prop.get.atomProps:
                if atomValue == "_NET_WM_STATE_STICKY":
                  ignore = true
                  break
            
          if not ignore:
            discard XMoveResizeWindow(display,
                                      ev.xmap.window,
                                      struts.bottom.cint, struts.top.cint,
                                      screenWidth.cuint, screenHeight.cuint - struts.top.cuint - struts.bottom.cuint)

            discard display.XSetInputFocus(ev.xmap.window, RevertToPointerRoot, CurrentTime)

    elif (ev.theType == MotionNotify) and (start.subWindow != None):

      # Discard any following MotionNotify events
      # This avoids "movement lag"
      while display.XCheckTypedEvent(MotionNotify, ev.addr) != 0:
        continue
      discard display.XFlush()

      var xDiff : int = ev.xButton.xRoot - start.xRoot
      var yDiff : int = ev.xButton.yRoot - start.yRoot

      discard XMoveResizeWindow(display,
                                start.subWindow,
                                attr.x + (if start.button == 1: xDiff else: 0).cint,
                                attr.y + (if start.button == 1: yDiff else: 0).cint,
                                max(1, attr.width + (if start.button == 3: xDiff else: 0)).cuint,
                                max(1, attr.height + (if start.button == 3: yDiff else: 0)).cuint)

    elif ev.theType == ButtonRelease:
      start.subWindow = None

    else:
      continue
