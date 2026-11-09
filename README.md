# pinmic
Mac Toolbar App to pin sound input volume

Menu bar app that keeps the default input device's volume pinned (default 100%).
Whenever something nudges the mic volume, PinMic sets it back and flashes the
recycle icon in the menu bar for 1.5s.

- `Sources/AppDelegate.swift` — the status-bar app
- `pin-mic.swift` — the original headless CLI/daemon version

## Build & run

    ./build.sh
    open build/PinMic.app

To pin at a different level, run the binary directly with a percent:

    build/PinMic.app/Contents/MacOS/PinMic 80
