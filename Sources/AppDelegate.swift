// PinMic: status-bar app that keeps the default input device's volume pinned
// at a level (default 100%). Listens for CoreAudio volume changes and immediately
// sets it back. Same behavior as pin-mic.swift, plus a menu bar icon that flips
// to the recycle symbol for 1.5s whenever the volume gets re-pinned.
//
// Build: ./build.sh    Run: open build/PinMic.app  (or build/PinMic.app/Contents/MacOS/PinMic [percent])

import AppKit
import CoreAudio

// MARK: - Config & logging

let target: Float32 = {
    if CommandLine.arguments.count > 1, let p = Float32(CommandLine.arguments[1]) {
        return max(0, min(100, p)) / 100
    }
    return 1.0
}()

let fmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()
func log(_ s: String) { print("\(fmt.string(from: Date())) \(s)"); fflush(stdout) }

// MARK: - CoreAudio helpers (unchanged from pin-mic.swift)

func defaultInputDevice() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    return (st == noErr && dev != 0) ? dev : nil
}

func deviceName(_ dev: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let st = withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0)
    }
    return st == noErr ? (name as String) : "device \(dev)"
}

func volumeAddr(_ element: UInt32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: element)
}

// Element 0 is the main/master control; 1...n are per-channel controls.
// Some devices only expose one or the other, so collect every settable one.
func settableElements(_ dev: AudioDeviceID) -> [UInt32] {
    (0...16).compactMap { el -> UInt32? in
        var addr = volumeAddr(UInt32(el))
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(dev, &addr),
              AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr,
              settable.boolValue else { return nil }
        return UInt32(el)
    }
}

/// Returns true if any element was actually readjusted.
@discardableResult
func pin(_ dev: AudioDeviceID, _ elements: [UInt32]) -> Bool {
    var adjusted = false
    for el in elements {
        var addr = volumeAddr(el)
        var cur: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &cur) == noErr else { continue }
        if abs(cur - target) > 0.001 {
            var v = target
            let st = AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &v)
            if st == noErr {
                adjusted = true
                log("element \(el): \(Int(cur * 100))% -> \(Int(target * 100))%")
            } else {
                log("element \(el): set failed (OSStatus \(st))")
            }
        }
    }
    return adjusted
}

// MARK: - Pinner

final class Pinner {
    let queue = DispatchQueue(label: "pin-mic")
    var dev: AudioDeviceID = 0
    var elements: [UInt32] = []
    var block: AudioObjectPropertyListenerBlock?
    var deviceLabel = "no input device"
    /// Called (on the pinner queue) whenever a volume was readjusted.
    var onPinned: (() -> Void)?
    /// Called (on the pinner queue) whenever the watched device changes.
    var onDeviceChanged: (() -> Void)?

    func attach() {
        detach()
        guard let d = defaultInputDevice() else {
            deviceLabel = "no input device"
            log("no default input device")
            onDeviceChanged?()
            return
        }
        dev = d
        elements = settableElements(d)
        deviceLabel = deviceName(d)
        log("watching \(deviceLabel) (elements \(elements))")
        onDeviceChanged?()
        guard !elements.isEmpty else { log("device has no settable input volume"); return }
        if pin(dev, elements) { onPinned?() }
        let blk: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            if pin(self.dev, self.elements) { self.onPinned?() }
        }
        block = blk
        for el in elements {
            var addr = volumeAddr(el)
            AudioObjectAddPropertyListenerBlock(dev, &addr, queue, blk)
        }
    }

    func detach() {
        guard dev != 0, let blk = block else { return }
        for el in elements {
            var addr = volumeAddr(el)
            AudioObjectRemovePropertyListenerBlock(dev, &addr, queue, blk)
        }
        dev = 0; elements = []; block = nil
    }

    func watchDefaultDevice() {
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, queue) { [weak self] _, _ in
            log("default input device changed")
            self?.attach()
        }
    }
}

// MARK: - App

// Manual entry point — required for swiftc single-file compilation (no @main).
let app = NSApplication.shared
// Set activation policy BEFORE run() so the status item appears reliably.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let pinner = Pinner()
    private var revertWork: DispatchWorkItem?
    private var deviceItem: NSMenuItem!
    private var lastPinItem: NSMenuItem!
    private var pinCount = 0

    private static let defaultSymbol = "mic.fill"
    private static let pinnedSymbol = "arrow.3.trianglepath"   // recycle ♻
    private static let flashDuration: TimeInterval = 1.5

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(pinned: false)
        statusItem.menu = buildMenu()

        pinner.onPinned = { [weak self] in
            DispatchQueue.main.async { self?.flashPinned() }
        }
        pinner.onDeviceChanged = { [weak self] in
            DispatchQueue.main.async { self?.refreshMenu() }
        }
        pinner.attach()
        pinner.watchDefaultDevice()
        log("pinning input volume at \(Int(target * 100))%")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        deviceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        deviceItem.isEnabled = false
        menu.addItem(deviceItem)
        lastPinItem = NSMenuItem(title: "No adjustments yet", action: nil, keyEquivalent: "")
        lastPinItem.isEnabled = false
        menu.addItem(lastPinItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PinMic",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        refreshMenu()
        return menu
    }

    private func refreshMenu() {
        deviceItem.title = "Pinning \(pinner.deviceLabel) at \(Int(target * 100))%"
    }

    /// Swap to the recycle icon, then back to the mic after 1.5s. Rapid re-pins
    /// extend the flash rather than cutting it short.
    private func flashPinned() {
        pinCount += 1
        lastPinItem.title = "Last re-pinned \(fmt.string(from: Date())) (\(pinCount)×)"
        setIcon(pinned: true)
        revertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setIcon(pinned: false) }
        revertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashDuration, execute: work)
    }

    private func setIcon(pinned: Bool) {
        let name = pinned ? Self.pinnedSymbol : Self.defaultSymbol
        let desc = pinned ? "Mic volume re-pinned" : "Mic volume pinned"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: desc) {
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.title = ""
        } else {
            // Fallback if SF Symbols unavailable
            statusItem.button?.image = nil
            statusItem.button?.title = pinned ? "♻" : "🎤"
        }
        statusItem.button?.toolTip = desc
    }

    func applicationWillTerminate(_ notification: Notification) {
        pinner.detach()
    }
}
