import x11/xlib, x11/xutil, x11/x, x11/keysym
import threadpool, osproc, tables, sequtils, posix, strformat, os, sugar

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

iterator getProperties(display : PDisplay, window : TWindow) : string =
  # Get properties of a given window on a display
  var nPropsReturn : cint

  # pointer to a list of word32
  var atoms : PAtom = display.XListProperties(window, nPropsReturn.addr)
  var currentAtom : PAtom
  var currentAtomName : cstring

  # Iterate over the list of atom names
  for i in 0..(nPropsReturn.int - 1):
    currentAtom = cast[PAtom](
      cast[uint](atoms) + cast[uint](i * currentAtom[].sizeof)
    )

    currentAtomName = display.XGetAtomName(currentAtom[])
    var atomName = newString(currentAtomName.len)

    copyMem(addr(atomName[0]), currentAtomName, currentAtomName.len)

    discard currentAtomName.XFree

    yield atomName

  discard atoms.XFree


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
    var attr : TXWindowAttributes

    currentWindow = cast[PWindow](
      cast[uint](childrenReturn) + cast[uint](i * currentWindow[].sizeof)
    )

    if display.XGetWindowAttributes(currentWindow[], attr.addr) == BadWindow:
      continue

    if attr.map_state == IsUnmapped or attr.map_state == IsUnviewable:
      continue

    if attr.override_redirect == 1:
      continue

    let win = Window(
      x: attr.x.cint,
      y: attr.y.cint,
      width: attr.width,
      height: attr.height,
      win: currentWindow[],
      screen: attr.screen
    )

    let ignored = @["_NET_WM_STRUT_PARTIAL", "_NET_WM_STRUT"]

    if any(toSeq(getProperties(display, win.win)), (p) => p.in(ignored)):
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
  startProcess("/usr/bin/xterm")

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
  display.grabKeyCombo(XK_Tab)
  display.grabKeyCombo(XK_Q)
  display.grabKeyCombo(XK_P)
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
