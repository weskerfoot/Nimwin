import x11/xlib, x11/xutil, x11/x, x11/keysym
import threadpool, osproc, tables, sequtils, posix, strformat, os, sugar, options

var root : TWindow

proc handleBadWindow(display : PDisplay, ev : PXErrorEvent) : cint {.cdecl.} =
  # resourceID maps to the Window's XID
  # ev.resourceID
  0

proc handleIOError(display : PDisplay) : cint {.cdecl.} =
  0


template HandleKey(key : TKeySym, body : untyped) : untyped =
    block:
      if (XLookupKeySym(cast[PXKeyEvent](ev.xkey.addr), 0) == key.cuint):
        body

type Window = ref object of RootObj
  x : cint
  y : cint
  width : cint
  height : cint
  win : TWindow
  screen : PScreen

type
  WinPropKind = enum pkString, pkCardinal
  WinProp = ref object of RootObj
    case kind: WinPropKind
      of pkString: strProp : cstring
      of pkCardinal: cardinalProp : seq[uint]

proc unpackCardinal(typeFormat : int,
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

  echo "byte_stride = ", byte_stride

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
  var nitemsReturn : culong
  var bytesAfterReturn : culong
  var propValue : ptr cuchar

  discard display.XGetWindowProperty(window,
                                     property,
                                     longOffset,
                                     longLength,
                                     false.TBool,
                                     AnyPropertyType.TAtom,
                                     actualType.addr,
                                     actualTypeFormat.addr,
                                     nitemsReturn.addr,
                                     bytesAfterReturn.addr,
                                     propValue.addr)

  let typeName = display.XGetAtomName(actualType)

  if typeName == "STRING":
    result = some(WinProp(kind: pkString, strProp: cast[cstring](propValue)))
  elif typeName == "CARDINAL":
    result = some(
              WinProp(
                kind: pkCardinal,
                cardinalProp: unpackCardinal(actualTypeFormat.int, nitemsReturn.int, propValue)
              )
            )
  else:
    result = none(WinProp)

  discard propValue.XFree

  return

iterator getProperties(display : PDisplay, window : TWindow) : string =
  # Get property names/values of a given window on a display
  var nPropsReturn : cint

  # pointer to a list of word32
  var atoms : PAtom = display.XListProperties(window, nPropsReturn.addr)
  var currentAtom : PAtom
  var currentAtomName : cstring

  # Iterate over the list of atom names
  for i in 0..(nPropsReturn.int - 1):
    currentAtom = cast[PAtom](
      cast[int](atoms) + cast[int](i * currentAtom[].sizeof)
    )

    let propValue = display.getPropertyValue(window, currentAtom[])

    if propValue.isSome:
      if propValue.get.kind == pkCardinal:
        echo propValue.get.cardinalProp

    currentAtomName = display.XGetAtomName(currentAtom[])
    var atomName = newString(currentAtomName.len)

    copyMem(addr(atomName[0]), currentAtomName, currentAtomName.len)

    discard currentAtomName.XFree

    yield atomName

  discard atoms.XFree

proc getAttributes(display : PDisplay, window : PWindow) : Option[TXWindowAttributes] =
  var attrs : TXWindowAttributes
  if display.XGetWindowAttributes(window[], attrs.addr) == BadWindow:
    return none(TXWindowAttributes)
  return some(attrs)

iterator getChildren(display : PDisplay, logFile : File) : Window =
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

    let win = Window(
      x: attr.get.x.cint,
      y: attr.get.y.cint,
      width: attr.get.width,
      height: attr.get.height,
      win: currentWindow[],
      screen: attr.get.screen
    )

    let ignored = @["_NET_WM_STRUT_PARTIAL", "_NET_WM_STRUT"]

    if toSeq(getProperties(display, win.win)).anyIt(it.in(ignored)):
      continue

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
  startProcess(terminal_path)

proc launcher() : Process =
  let launcher_path = getEnv("NIMWIN_LAUNCHER", "/usr/bin/dmenu_run")
  startProcess(launcher_path)

proc handleProcess(p : Process) =
  discard p.waitForExit
  processChan.send(p.processID)

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

  display.grabKeyCombo(XK_Return, @[ShiftMask.cuint])
  display.grabKeyCombo(XK_T, @[ShiftMask.cuint])
  display.grabKeyCombo(XK_Tab) # Cycle through windows
  display.grabKeyCombo(XK_Q) # Restart window manager
  display.grabKeyCombo(XK_P) # Launcher
  display.grabKeyCombo(XK_F) # Full screen
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
        let windowStack = toSeq(getChildren(display, logFile))
        if windowStack.len > 0:
          discard display.XDestroyWindow(windowStack[^1].win)

      HandleKey(XK_Tab):
        if ev.xKey.subWindow != None:
          # Cycle through subwindows of the root window
          #discard XCirculateSubwindows(display, root, RaiseLowest)
          #discard display.XFlush()

          let windowStack = toSeq(getChildren(display, logFile))

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

      HandleKey(XK_F):
        if ev.xKey.subWindow != None:
          let rootAttrs = getAttributes(display, root.addr)

          if rootAttrs.isSome:
            # TODO get height of struts and offset this from that
            let screenHeight = rootAttrs.get.height
            let screenWidth = rootAttrs.get.width

            discard XMoveResizeWindow(display,
                                      ev.xKey.subWindow,
                                      0, 0,
                                      screenWidth.cuint, screenHeight.cuint)


    elif (ev.theType == ButtonPress) and (ev.xButton.subWindow != None):
      discard XGetWindowAttributes(display, ev.xButton.subWindow, attr.addr)
      start = ev.xButton

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
