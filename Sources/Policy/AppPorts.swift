import Foundation

protocol WindowPublishing: AnyObject {
    @MainActor func update(pid: Int32, windows: [WindowRecord]?)
}

@MainActor
protocol HotkeyRegistration: AnyObject { func stop() }

@MainActor
protocol HotkeyInstalling {
    func install(keys: [String: String], perform: @escaping (WorkspaceCommand) -> Void) throws -> any HotkeyRegistration
}
