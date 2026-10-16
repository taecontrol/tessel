import Carbon

@MainActor
final class Hotkeys {
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var commands: [UInt32: WorkspaceCommand] = [:]
    private let perform: (WorkspaceCommand) -> Void

    init(keys: [String: String], perform: @escaping (WorkspaceCommand) -> Void) throws {
        self.perform = perform
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let keys = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
                guard let command = keys.commands[identifier.id] else { return OSStatus(eventNotHandledErr) }
                keys.perform(command)
                return noErr
            }
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { throw Failure() }
        for (index, binding) in keys.sorted(by: { $0.key < $1.key }).enumerated() {
            guard let command = WorkspaceCommand(binding.value), let chord = KeyChord(binding.key) else { continue }
            var flags: UInt32 = 0
            for (name, value) in [("alt", optionKey), ("shift", shiftKey), ("ctrl", controlKey), ("cmd", cmdKey)]
                where chord.modifiers.contains(name) { flags |= UInt32(value) }
            let id = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(chord.code, flags, EventHotKeyID(signature: 0x74657373, id: id),
                                             GetApplicationEventTarget(), 0, &reference)
            guard result == noErr, let reference else { stop(); throw Failure() }
            references.append(reference)
            commands[id] = command
        }
    }

    struct Failure: Error {}

    func stop() {
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        commands.removeAll()
    }
}
