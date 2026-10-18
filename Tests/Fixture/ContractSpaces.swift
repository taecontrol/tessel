import AppKit
import Darwin
import ObjectiveC

/// The observer resolves native operations independently of the app adapter.
@MainActor
final class FixtureSpaces {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Active = @convention(c) (Int32) -> UInt64
    private typealias Memberships = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private let connection: Connection
    private let getActive: Active
    private let getMemberships: Memberships
    private let createType: AnyClass
    private let moveType: AnyClass
    private let destroyType: AnyClass
    private let perform = NSSelectorFromString("performWithWMBridgeDelegate")
    private(set) var closet: UInt64 = 0
    var active: UInt64 { getActive(connection()) }

    init() throws {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL),
              let connection = dlsym(library, "SLSMainConnectionID"), let active = dlsym(library, "SLSGetActiveSpace"),
              let memberships = dlsym(library, "SLSCopySpacesForWindows"),
              let create = NSClassFromString("SLSBridgedSpaceCreateOperation"),
              let move = NSClassFromString("SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation"),
              let destroy = NSClassFromString("SLSBridgedSpaceDestroyOperation") else { throw FixtureContractError("native Space operations unavailable") }
        self.connection = unsafeBitCast(connection, to: Connection.self)
        getActive = unsafeBitCast(active, to: Active.self)
        getMemberships = unsafeBitCast(memberships, to: Memberships.self)
        createType = create; moveType = move; destroyType = destroy
        let methods: [(AnyClass, String)] = [(create, "initWithOptions:values:"), (move, "initWithSpaceID:windows:options:"), (destroy, "initWithSpaceID:")]
        for method in methods {
            let type: AnyClass = method.0, name = method.1
            guard class_getInstanceMethod(type, NSSelectorFromString(name)) != nil,
                  class_getInstanceMethod(type, perform) != nil else { throw FixtureContractError("native Space methods unavailable") }
        }
    }

    func start() throws {
        guard closet == 0 else { return }
        let selector = NSSelectorFromString("initWithOptions:values:")
        typealias Initialize = @convention(c) (AnyObject, Selector, UInt64, NSDictionary) -> Unmanaged<AnyObject>?
        let initialize = unsafeBitCast(class_getMethodImplementation(createType, selector), to: Initialize.self)
        guard let operation = initialize(allocate(createType), selector, 1, [:])?.takeRetainedValue() as? NSObject,
              let result = operation.perform(perform)?.takeUnretainedValue() as? NSObject,
              result.responds(to: NSSelectorFromString("spaceID")) else { throw FixtureContractError("native closet creation failed") }
        let getter = NSSelectorFromString("spaceID")
        typealias Identifier = @convention(c) (AnyObject, Selector) -> UInt64
        closet = unsafeBitCast(result.method(for: getter), to: Identifier.self)(result, getter)
        guard closet != 0 else { throw FixtureContractError("native closet has no identifier") }
    }

    func memberships(_ window: UInt32, mask: UInt32) -> [UInt64] {
        let spaces = getMemberships(connection(), mask, [NSNumber(value: window)] as CFArray)?.takeRetainedValue()
        return (spaces as? [NSNumber] ?? []).map(\.uint64Value)
    }

    func move(_ windows: [UInt32], to space: UInt64) {
        guard !windows.isEmpty, space != 0 else { return }
        let selector = NSSelectorFromString("initWithSpaceID:windows:options:")
        typealias Initialize = @convention(c) (AnyObject, Selector, UInt64, NSArray, UInt64) -> Unmanaged<AnyObject>?
        let initialize = unsafeBitCast(class_getMethodImplementation(moveType, selector), to: Initialize.self)
        let operation = initialize(allocate(moveType), selector, space, windows.map(NSNumber.init(value:)) as NSArray, 7)?.takeRetainedValue() as? NSObject
        _ = operation?.perform(perform)
    }

    func stop(returning windows: [UInt32]) {
        move(windows, to: active)
        guard closet != 0 else { return }
        let selector = NSSelectorFromString("initWithSpaceID:")
        typealias Initialize = @convention(c) (AnyObject, Selector, UInt64) -> Unmanaged<AnyObject>?
        let initialize = unsafeBitCast(class_getMethodImplementation(destroyType, selector), to: Initialize.self)
        let operation = initialize(allocate(destroyType), selector, closet)?.takeRetainedValue() as? NSObject
        _ = operation?.perform(perform)
        closet = 0
    }

    private func allocate(_ type: AnyClass) -> AnyObject {
        let selector = NSSelectorFromString("alloc")
        typealias Allocate = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        return unsafeBitCast(class_getMethodImplementation(object_getClass(type), selector), to: Allocate.self)(type, selector).takeUnretainedValue()
    }
}
