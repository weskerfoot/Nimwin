import x11/xlib, x11/xutil, x11/x, x11/keysym
import threadpool, osproc

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


proc startTerminal() =
  # TODO track running processes and close ones that have finished
  discard startProcess("/usr/bin/xterm")

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

  while true:
    # TODO refactor using XPending or XCB?
    discard XNextEvent(display, ev.addr)

    # subwindow is because we grabbed the root window
    # and we want events in its children

    echo $ev.xkey
    echo $XK_T
    # For spawning a terminal we also want events for the root window
    if (ev.theType == KeyPress):
      echo "Executing xterm"
      startTerminal()

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
