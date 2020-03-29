#! /usr/bin/env bash

pkill -f Xephyr

Xephyr -ac -screen 1280x1024 -br -reset -terminate :1 &
sleep 5

env DISPLAY=:1 ./nimwin &
xterm -display :1 &
