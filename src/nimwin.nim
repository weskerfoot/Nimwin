import x11/xlib, x11/xutil, x11/x, x11/keysym
import threadpool, osproc

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

proc grabKeys(display : PDisplay) =
  discard XGrabKey(display,
                   XKeySymToKeyCode(display, XK_T).cint,
                   ControlMask.cuint or Mod1Mask.cuint,
                   DefaultRootWindow(display),
                   1.cint,
                   GrabModeAsync.cint,
                   GrabModeAsync.cint)
  discard XGrabKey(display,
                   XKeySymToKeyCode(display, XK_T).cint,
                   ControlMask.cuint or Mod1Mask.cuint or Mod2Mask.cuint,
                   DefaultRootWindow(display),
                   1.cint,
                   GrabModeAsync.cint,
                   GrabModeAsync.cint)
  discard XGrabKey(display,
                   XKeySymToKeyCode(display, XK_T).cint,
                   ControlMask.cuint or Mod1Mask.cuint or LockMask.cuint,
                   DefaultRootWindow(display),
                   1.cint,
                   GrabModeAsync.cint,
                   GrabModeAsync.cint)
  discard XGrabKey(display,
                   XKeySymToKeyCode(display, XK_T).cint,
                   ControlMask.cuint or Mod1Mask.cuint or LockMask.cuint or Mod2Mask.cuint,
                   DefaultRootWindow(display),
                   1.cint,
                   GrabModeAsync.cint,
                   GrabModeAsync.cint)


when isMainModule:
  var start : TXButtonEvent
  var ev : TXEvent
  var attr : TXWindowAttributes

  let display = getDisplay()

  display.grabKeys
  display.grabMouse(1)
  display.grabMouse(3)

  start.subWindow = None

  while true:
    # TODO refactor using XPending or XCB?
    discard XNextEvent(display, ev.addr)

    # subwindow is because we grabbed the root window
    # and we want events in its children

    # For spawning a terminal we also want events for the root window
    if (ev.theType == KeyPress):
      echo "Executing xterm"
      discard spawn "xterm".execProcess

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
      while display.XCheckTypedEvent(MotionNotify, ev.addr) != 0: continue

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
