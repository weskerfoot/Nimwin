import x11/xlib, x11/xutil, x11/x, x11/keysym
import threadpool, osproc, tables

var root : TWindow

type Window = ref object of RootObj
  x : cint
  y : cint
  width : cint
  height : cint
  win : TWindow
  screen : PScreen

iterator getChildren(display : PDisplay, rootHeight : int, rootWidth : int) : Window =
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

    yield Window(
      x: attr.x.cint,
      y: attr.y.cint,
      width: attr.width,
      height: attr.height,
      win: currentWindow[],
      screen: attr.screen
    )

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

proc grabKeyCombo(display : PDisplay, key : TKeySym) =
  discard XGrabKey(display,
                   XKeySymToKeyCode(display, key).cint,
                   ControlMask.cuint or Mod1Mask.cuint,
                   DefaultRootWindow(display),
                   1.cint,
                   GrabModeAsync.cint,
                   GrabModeAsync.cint)
  discard XGrabKey(display,
                   XKeySymToKeyCode(display, key).cint,
                   ControlMask.cuint or Mod1Mask.cuint or Mod2Mask.cuint,
                   DefaultRootWindow(display),
                   1.cint,
                   GrabModeAsync.cint,
                   GrabModeAsync.cint)
  discard XGrabKey(display,
                   XKeySymToKeyCode(display, key).cint,
                   ControlMask.cuint or Mod1Mask.cuint or LockMask.cuint,
                   DefaultRootWindow(display),
                   1.cint,
                   GrabModeAsync.cint,
                   GrabModeAsync.cint)
  discard XGrabKey(display,
                   XKeySymToKeyCode(display, key).cint,
                   ControlMask.cuint or Mod1Mask.cuint or LockMask.cuint or Mod2Mask.cuint,
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
  # TODO track running processes and close ones that have finished
  startProcess("/usr/bin/xterm")

proc handleProcess(p : Process) =
  echo "Called handle process"
  echo p.processID
  discard p.waitForExit
  processChan.send(p.processID)

when isMainModule:
  var start : TXButtonEvent
  var ev : TXEvent
  var attr : TXWindowAttributes

  let display = getDisplay()

  root = DefaultRootWindow(display)

  display.grabKeyCombo(XK_T)
  display.grabKeyCombo(XK_Return)
  display.grabMouse(1)
  display.grabMouse(3)

  start.subWindow = None

  var openProcesses = initTable[int, Process]() # hashset of processes

  while true:
    let processExited = processChan.tryRecv()

    if processExited.dataAvailable:
      openProcesses.del(processExited.msg)

    # TODO refactor using XPending or XCB?
    discard XNextEvent(display, ev.addr)

    # subwindow is because we grabbed the root window
    # and we want events in its children

    # For spawning a terminal we also want events for the root window
    if (ev.theType == KeyPress):
      echo "Executing xterm"
      let p = startTerminal()
      openProcesses[p.processID] = p
      spawn handleProcess(p)

    # TODO have to actually check which keys were pressed, not assume they were the only ones we grabbed
    # since we're going to want to grab multiple combos soon
    #if (ev.theType == KeyPress) and (ev.xKey.subWindow != None):
      #discard XRaiseWindow(display, ev.xKey.subWindow)

    elif (ev.theType == ButtonPress) and (ev.xButton.subWindow != None):
      discard XGetWindowAttributes(display, ev.xButton.subWindow, attr.addr)
      start = ev.xButton

    elif (ev.theType == MotionNotify) and (start.subWindow != None):

      # Discard any following MotionNotify events
      # This avoids "movement lag"
      while display.XCheckTypedEvent(MotionNotify, ev.addr) != 0:
        continue

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
