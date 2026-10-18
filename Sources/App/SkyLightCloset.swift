import AppKit
import Darwin
import ObjectiveC

/// The experiment's only SkyLight boundary. No private Space identifiers escape
/// it, no native Space is switched, and no persistent recovery state is written.
@MainActor
final class SkyLightCloset: ClosetPort {
    typealias Unavailable = ClosetUnavailable
    private typealias Connection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias Spaces = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private let connection: Connection
    private let getActiveSpace: ActiveSpace
    private let spaces: Spaces
    private let createClass: AnyClass
    private let moveClass: AnyClass
    private let destroyClass: AnyClass
    private let simulateFailedHide: Bool
    private var closet: UInt64?
    private static let perform = NSSelectorFromString("performWithWMBridgeDelegate")

    init(simulateMissing: Bool, simulateFailedHide: Bool) throws {
        guard !simulateMissing,
              let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL),
              let connection = dlsym(library, "SLSMainConnectionID"),
              let activeSpace = dlsym(library, "SLSGetActiveSpace"),
              let spaces = dlsym(library, "SLSCopySpacesForWindows"),
              let createClass = NSClassFromString("SLSBridgedSpaceCreateOperation"),
              let moveClass = NSClassFromString("SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation"),
              let destroyClass = NSClassFromString("SLSBridgedSpaceDestroyOperation") else {
            throw Unavailable(reason: "SkyLight window hiding is unavailable")
        }
        let operations: [(AnyClass, String)] = [(createClass, "initWithOptions:values:"), (moveClass, "initWithSpaceID:windows:options:"),
                                               (destroyClass, "initWithSpaceID:")]
        for operation in operations {
            let type: AnyClass = operation.0
            guard class_getInstanceMethod(type, NSSelectorFromString(operation.1)) != nil,
                  class_getInstanceMethod(type, Self.perform) != nil else {
                throw Unavailable(reason: "SkyLight window hiding methods are unavailable")
            }
        }
        self.connection = unsafeBitCast(connection, to: Connection.self)
        self.getActiveSpace = unsafeBitCast(activeSpace, to: ActiveSpace.self)
        self.spaces = unsafeBitCast(spaces, to: Spaces.self)
        self.createClass = createClass
        self.moveClass = moveClass
        self.destroyClass = destroyClass
        self.simulateFailedHide = simulateFailedHide
        // Keep SkyLight loaded for the lifetime of outstanding asynchronous ops.
    }

    func start() throws {
        guard closet == nil else { return }
        let selector = NSSelectorFromString("initWithOptions:values:")
        typealias Initialize = @convention(c) (AnyObject, Selector, UInt64, NSDictionary) -> Unmanaged<AnyObject>?
        let initialize = unsafeBitCast(class_getMethodImplementation(createClass, selector), to: Initialize.self)
        guard let operation = initialize(allocate(createClass), selector, 1, [:])?.takeRetainedValue() as? NSObject,
              let result = operation.perform(Self.perform)?.takeUnretainedValue() as? NSObject,
              result.responds(to: NSSelectorFromString("spaceID")) else {
            throw Unavailable(reason: "SkyLight could not create the hidden Space")
        }
        typealias Identifier = @convention(c) (AnyObject, Selector) -> UInt64
        let getter = NSSelectorFromString("spaceID")
        let identifier = unsafeBitCast(result.method(for: getter), to: Identifier.self)(result, getter)
        guard identifier != 0 else { throw Unavailable(reason: "SkyLight returned an invalid hidden Space") }
        closet = identifier
    }

    func hide(_ windows: [UInt32]) {
        guard !simulateFailedHide, let closet else { return }
        move(windows, to: closet)
    }

    func show(_ windows: [UInt32]) { move(windows, to: getActiveSpace(connection())) }

    func activeSpace() -> SpaceToken { SpaceToken(adapterValue: getActiveSpace(connection())) }
    var closetSpace: SpaceToken { SpaceToken(adapterValue: closet ?? 0) }

    func stop(returning windows: [UInt32]) {
        show(windows)
        if let closet { destroy(closet) }
        closet = nil
    }

    func memberships(_ window: UInt32, scope: SpaceScope) -> [SpaceToken] {
        let mask: UInt32 = scope == .ordinary ? 7 : 0xF
        let result = spaces(connection(), mask, [NSNumber(value: window)] as CFArray)?.takeRetainedValue()
        return (result as? [NSNumber] ?? []).map { SpaceToken(adapterValue: $0.uint64Value) }
    }

    private func move(_ windows: [UInt32], to space: UInt64) {
        guard !windows.isEmpty, space != 0 else { return }
        let selector = NSSelectorFromString("initWithSpaceID:windows:options:")
        typealias Initialize = @convention(c) (AnyObject, Selector, UInt64, NSArray, UInt64) -> Unmanaged<AnyObject>?
        let initialize = unsafeBitCast(class_getMethodImplementation(moveClass, selector), to: Initialize.self)
        let operation = initialize(allocate(moveClass), selector, space, windows.map(NSNumber.init(value:)) as NSArray, 7)?.takeRetainedValue() as? NSObject
        _ = operation?.perform(Self.perform)
    }

    private func destroy(_ space: UInt64) {
        let selector = NSSelectorFromString("initWithSpaceID:")
        typealias Initialize = @convention(c) (AnyObject, Selector, UInt64) -> Unmanaged<AnyObject>?
        let initialize = unsafeBitCast(class_getMethodImplementation(destroyClass, selector), to: Initialize.self)
        let operation = initialize(allocate(destroyClass), selector, space)?.takeRetainedValue() as? NSObject
        _ = operation?.perform(Self.perform)
    }

    private func allocate(_ type: AnyClass) -> AnyObject {
        let selector = NSSelectorFromString("alloc")
        typealias Allocate = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        // init consumes alloc's +1; its caller adopts the returned object.
        return unsafeBitCast(class_getMethodImplementation(object_getClass(type), selector), to: Allocate.self)(type, selector).takeUnretainedValue()
    }
}
