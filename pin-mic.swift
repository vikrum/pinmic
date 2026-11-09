// pin-mic: keep the default input device's volume pinned at a level (default 100%).
// Listens for CoreAudio volume changes and immediately sets it back.
// Build: swiftc -O -o pin-mic pin-mic.swift    Run: ./pin-mic [percent]

import CoreAudio
import Foundation

let target: Float32 = {
    if CommandLine.arguments.count > 1, let p = Float32(CommandLine.arguments[1]) {
        return max(0, min(100, p)) / 100
    }
    return 1.0
}()

let fmt = DateFormatter()
fmt.dateFormat = "HH:mm:ss"
func log(_ s: String) { print("\(fmt.string(from: Date())) \(s)"); fflush(stdout) }

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

func pin(_ dev: AudioDeviceID, _ elements: [UInt32]) {
    for el in elements {
        var addr = volumeAddr(el)
        var cur: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &cur) == noErr else { continue }
        if abs(cur - target) > 0.001 {
            var v = target
            let st = AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &v)
            log(st == noErr
                ? "element \(el): \(Int(cur * 100))% -> \(Int(target * 100))%"
                : "element \(el): set failed (OSStatus \(st))")
        }
    }
}

final class Pinner {
    let queue = DispatchQueue(label: "pin-mic")
    var dev: AudioDeviceID = 0
    var elements: [UInt32] = []
    var block: AudioObjectPropertyListenerBlock?

    func attach() {
        detach()
        guard let d = defaultInputDevice() else { log("no default input device"); return }
        dev = d
        elements = settableElements(d)
        log("watching \(deviceName(d)) (elements \(elements))")
        guard !elements.isEmpty else { log("device has no settable input volume"); return }
        pin(dev, elements)
        let blk: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            pin(self.dev, self.elements)
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
}

let pinner = Pinner()
pinner.attach()

// Re-attach when the default input device changes (headset plugged in, etc.).
var defaultAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, pinner.queue) { _, _ in
    log("default input device changed")
    pinner.attach()
}

log("pinning input volume at \(Int(target * 100))% (ctrl-c to stop)")
dispatchMain()
