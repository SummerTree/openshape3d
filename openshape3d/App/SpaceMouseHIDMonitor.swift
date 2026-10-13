//
//  SpaceMouseHIDMonitor.swift
//  openshape3d
//
//  The Mac's SpaceMouse input (spec §7.5): IOKit HID delivers the device's
//  axis and button values to `SpaceMouseDriver`, and a display link ticks it
//  while the cap is moved. Works with or without 3Dconnexion's own driver
//  installed — the device is read directly, not seized. iPadOS gives apps
//  no access to the device, so this is the Mac's alone.
//

#if targetEnvironment(macCatalyst)
import Foundation
import IOKit.hid
import QuartzCore

@MainActor
final class SpaceMouseHIDMonitor {
    static let shared = SpaceMouseHIDMonitor()

    /// 3Dconnexion, and Logitech for the devices sold under its name.
    private static let vendorIDs = [0x256F, 0x046D]

    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice] = []
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    private var driver: SpaceMouseDriver { .shared }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Generic Desktop ▸ Multi-axis Controller — never the vendor's mice
        // or keyboards.
        let matching = Self.vendorIDs.map {
            [kIOHIDVendorIDKey: $0, kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x08] as NSDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<SpaceMouseHIDMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.attached(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<SpaceMouseHIDMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.removed(device) }
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let monitor = Unmanaged<SpaceMouseHIDMonitor>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let page = Int(IOHIDElementGetUsagePage(element))
            let usage = Int(IOHIDElementGetUsage(element))
            let integer = IOHIDValueGetIntegerValue(value)
            MainActor.assumeIsolated { monitor.received(page: page, usage: usage, value: integer) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    private func attached(_ device: IOHIDDevice) {
        devices.append(device)
        driver.deviceName = Self.name(of: device)
    }

    private func removed(_ device: IOHIDDevice) {
        devices.removeAll { $0 == device }
        driver.reset()
        driver.deviceName = devices.last.map(Self.name(of:))
        stopTicking()
    }

    private func received(page: Int, usage: Int, value: Int) {
        driver.receive(usagePage: page, usage: usage, value: value)
        if driver.isMoving { startTicking() } else { stopTicking() }
    }

    private static func name(of device: IOHIDDevice) -> String {
        IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "SpaceMouse"
    }

    // The cap reports only when it moves; held still it keeps the view
    // moving, so motion is integrated each frame rather than per report.

    private func startTicking() {
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopTicking() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        driver.tick(dt: now - lastTick)
        lastTick = now
        if !driver.isMoving { stopTicking() }
    }
}
#endif
