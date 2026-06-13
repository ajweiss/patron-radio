#!/bin/bash
# Simple MPRIS controller for Patron Radio debugging
DEST="org.mpris.MediaPlayer2.patronradio"
IFACE="org.mpris.MediaPlayer2.Player"
OBJ="/org/mpris/MediaPlayer2"
PROPS="org.freedesktop.DBus.Properties"

get() {
    dbus-send --print-reply --dest=$DEST $OBJ $PROPS.Get string:"$IFACE" string:"$1" 2>&1 | tail -1
}

set_prop() {
    dbus-send --print-reply --dest=$DEST $OBJ $PROPS.Set string:"$IFACE" string:"$1" "variant:$2" 2>&1 > /dev/null
}

call() {
    dbus-send --print-reply --dest=$DEST $OBJ "$IFACE.$1" 2>&1 > /dev/null
}

status() {
    echo "--- Status ---"
    echo "PlaybackStatus: $(get PlaybackStatus)"
    echo "Volume:         $(get Volume)"
    echo "Metadata title: $(dbus-send --print-reply --dest=$DEST $OBJ $PROPS.Get string:"$IFACE" string:"Metadata" 2>&1 | grep -A1 'xesam:title' | tail -1)"
    echo ""
}

case "${1:-help}" in
    status)
        status
        ;;
    play)
        echo "Calling Play..."
        call Play
        sleep 1
        status
        ;;
    pause)
        echo "Calling Pause..."
        call Pause
        sleep 1
        status
        ;;
    stop)
        echo "Calling Stop..."
        call Stop
        sleep 1
        status
        ;;
    next)
        echo "Calling Next..."
        call Next
        sleep 2
        status
        ;;
    prev)
        echo "Calling Previous..."
        call Previous
        sleep 2
        status
        ;;
    vol)
        if [ -z "$2" ]; then
            echo "Volume: $(get Volume)"
        else
            echo "Setting volume to $2..."
            set_prop Volume "double:$2"
            sleep 0.5
            echo "Volume: $(get Volume)"
        fi
        ;;
    cycle)
        echo "=== Cycle test: set vol 0.5, pause, play, check vol ==="
        echo ""
        echo "1. Setting volume to 0.5..."
        set_prop Volume "double:0.5"
        sleep 0.5
        status

        echo "2. Pausing..."
        call Pause
        sleep 1
        status

        echo "3. Playing..."
        call Play
        sleep 2
        status

        echo "4. Final volume check:"
        echo "Volume: $(get Volume)"
        ;;
    help|*)
        echo "Usage: $0 {status|play|pause|stop|next|prev|vol [0.0-1.0]|cycle}"
        echo ""
        echo "  status  - Show current state"
        echo "  play    - MPRIS Play"
        echo "  pause   - MPRIS Pause"
        echo "  stop    - MPRIS Stop"
        echo "  next    - Next station"
        echo "  prev    - Previous station"
        echo "  vol     - Get/set volume (0.0-1.0)"
        echo "  cycle   - Set vol to 0.5, pause, play, verify vol persists"
        ;;
esac
