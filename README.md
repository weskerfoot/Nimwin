## Nimwin

### What is this?
A very simple X11 window manager written in Nim, and inspired by TinyWM and XMonad.

### How to build it?
Install nim and nimble and run `nimble build`. You must have XLib development headers on your system (and obviously an X server).

### How to run it?
#### Xephyr
* Install [Xephyr](https://en.wikipedia.org/wiki/Xephyr)
* Make sure you have a running X server
Then run these commands to launch Xephyr. 
```
Xephyr -ac -screen 1280x1024 -br -reset -terminate 2> /dev/null :1 &
env DISPLAY=:1 ./nimwin
```

#### xinit
Put `exec /path/to/nimwin` in your `~/.xinitrc`

### How to launch a window?
If you want to run xterm, for example, just set `NIMWIN_LAUNCHER` to a launcher (e.g. `dmenu`), and then type `Alt + p` to invoke it.

### How to move windows

`alt + right` click allows you to resize, `alt + left click` allows you to move, `ctrl + alt + return` opens an xterm, and `alt + tab` cycles through windows, changing the focus each time. `alt + t` makes a window full-screen.
