import Foundation

// Raw trackpad frames come from the private MultitouchSupport framework, resolved at runtime.
private let multitouch = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)

private typealias MTDevice = UnsafeMutableRawPointer
private typealias ContactCallback = @convention(c) (MTDevice?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
private typealias RegisterFn = @convention(c) (MTDevice, ContactCallback) -> Void
private typealias StartFn = @convention(c) (MTDevice, Int32) -> Int32
private typealias StopFn = @convention(c) (MTDevice) -> Void

private func multitouchSymbol<T>(_ name: String, as type: T.Type) -> T {
    guard let pointer = dlsym(multitouch, name) else {
        fatalError("space-overview: MultitouchSupport symbol \(name) not found on this macOS version")
    }
    return unsafeBitCast(pointer, to: type)
}

// Layout of one MTTouch record: 96 bytes; state at byte 20, normalized y (0 = bottom edge) at byte 36.
private let touchStride = 96
private let stateOffset = 20
private let normalizedYOffset = 36
private let touchingStates: ClosedRange<Int32> = 3...4  // make-touch, touching
private let swipeThreshold: Float = 0.12  // fraction of trackpad height

// The C callback cannot capture context, so gesture state lives at file scope.
private var gestureStartY: Float?
private var gestureFingers = 0  // finger count being measured
private var firedFingers = 0    // largest finger count that already fired since the last full lift
private var onSwipe: (_ fingers: Int, _ up: Bool) -> Void = { _, _ in }

private let handleFrame: ContactCallback = { _, touches, count, _, _ in
    guard let touches else { return 0 }
    var touchingCount = 0
    var ySum: Float = 0
    for i in 0..<Int(count) {
        let touch = touches + i * touchStride
        guard touchingStates.contains(touch.load(fromByteOffset: stateOffset, as: Int32.self)) else { continue }
        touchingCount += 1
        ySum += touch.load(fromByteOffset: normalizedYOffset, as: Float.self)
    }

    if touchingCount == 0 {
        gestureStartY = nil
        gestureFingers = 0
        firedFingers = 0
        return 0
    }
    // Only three- and four-finger swipes count, and only more fingers than already fired: fingers
    // landing 3-then-4 can still open the overview, but lifting 4-then-3 cannot fire a second time.
    guard touchingCount == 3 || touchingCount == 4, touchingCount > firedFingers else {
        gestureStartY = nil
        gestureFingers = 0
        return 0
    }

    let y = ySum / Float(touchingCount)
    // A finger joining or leaving restarts the measurement, so 4-3-4 cannot add up to a false swipe.
    guard touchingCount == gestureFingers, let startY = gestureStartY else {
        gestureFingers = touchingCount
        gestureStartY = y
        return 0
    }
    if abs(y - startY) > swipeThreshold {
        firedFingers = touchingCount
        let fingers = touchingCount, up = y > startY
        DispatchQueue.main.async { onSwipe(fingers, up) }
    }
    return 0
}

enum Gesture {
    private static let createList = multitouchSymbol("MTDeviceCreateList", as: CreateListFn.self)
    private static let register = multitouchSymbol("MTRegisterContactFrameCallback", as: RegisterFn.self)
    private static let unregister = multitouchSymbol("MTUnregisterContactFrameCallback", as: RegisterFn.self)
    private static let start = multitouchSymbol("MTDeviceStart", as: StartFn.self)
    private static let stop = multitouchSymbol("MTDeviceStop", as: StopFn.self)

    /// Retained so the device references stay valid while callbacks are registered.
    private static var devices: [AnyObject] = []

    /// Calls back on the main thread once per three- or four-finger vertical swipe.
    static func listen(_ handler: @escaping (_ fingers: Int, _ up: Bool) -> Void) {
        onSwipe = handler
        restart()
    }

    /// Re-attaches to every trackpad; also needed after sleep, which silently ends the callbacks.
    static func restart() {
        for device in devices {
            let ref = Unmanaged.passUnretained(device).toOpaque()
            unregister(ref, handleFrame)
            stop(ref)
        }
        devices = (createList()?.takeRetainedValue() as? [AnyObject]) ?? []
        if devices.isEmpty { fputs("space-overview: no multitouch devices found\n", stderr) }
        for device in devices {
            let ref = Unmanaged.passUnretained(device).toOpaque()
            register(ref, handleFrame)
            _ = start(ref, 0)
        }
    }

    static var deviceCount: Int { devices.count }
}
