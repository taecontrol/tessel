import AppKit

/// Owns membership, arrival order and focus history. AX workers supply facts and
/// perform bounded app-specific writes; they never decide workspace policy.
@MainActor
final class Workspaces {
    private struct Entry {
        var observation: WindowObservation
        let pid: pid_t
        var workspace: Int?
        var recent: UInt64 = 0
    }
    private let store: SnapshotStore
    private let trusted: Bool
    private var configuration = Configuration()
    private var entries: [UInt32: Entry] = [:]
    private var arrival: [Int: [UInt32]] = [:]
    private var rails = Rails()
    private var railSizing = Set<UInt32>()
    private var railEnabled: Bool { configuration.experiments["rails"] == true }
    private var focused: UInt32?
    private var clock: UInt64 = 0
    private var closet: WindowCloset?
    private var unavailable: String?
    private var hotkeys: Hotkeys?
    private var closeted = Set<UInt32>()
    private var expectedFocus: UInt32?
    private var focusDecision: DispatchWorkItem?
    private var transition: UInt64 = 0
    private var knownApplications = Set<pid_t>()
    private var appFocus: [pid_t: UInt32] = [:]
    private var enablingFront: pid_t?
    private var initialApplications = Set<pid_t>()
    private var publishedStatus: WorkspaceStatus?
    private(set) var status = WorkspaceStatus()
    weak var catalog: WindowCatalog?
    var onChange: (() -> Void)?

    init(store: SnapshotStore, trusted: Bool, configuration: Configuration, simulateMissing: Bool, simulateFailedHide: Bool) {
        self.store = store
        self.trusted = trusted
        if trusted {
            do { closet = try WindowCloset(simulateMissing: simulateMissing, simulateFailedHide: simulateFailedHide) }
            catch let error as WindowCloset.Unavailable { unavailable = error.reason }
            catch { unavailable = "SkyLight window hiding is unavailable" }
        }
        configure(configuration)
    }

    func configure(_ next: Configuration) {
        let old = configuration
        configuration = next
        status.gaps = next.gaps
        status.keys = next.keys
        guard next.experiments["workspaces"] == true || railEnabled else { disable(reason: "experiment off"); return }
        guard trusted else { disable(reason: "Accessibility permission needed"); return }
        guard let closet, unavailable == nil else { disable(reason: unavailable ?? "SkyLight window hiding is unavailable"); return }
        rails.width = area.width
        rails.gap = next.gaps.outer
        status.layout = railEnabled ? "rails" : "stack"
        let layoutChanged = old.experiments["rails"] != next.experiments["rails"]
        if status.enabled && layoutChanged {
            if !railEnabled { catalog?.returnInside(ids: Set(entries.keys.filter { entries[$0]?.workspace != nil && entries[$0]?.observation.record.state != .fullscreen }), area: area) }
            rails = Rails(width: area.width, gap: next.gaps.outer)
            railSizing.removeAll()
            if railEnabled {
                for workspace in arrival.keys.sorted() {
                    for id in arrival[workspace] ?? [] where railTile(id) { addRailTile(id, initial: true) }
                }
                if let focused { rails.select(focused) }
            }
            installKeys()
            render(focusing: focused, relayout: true)
        }
        if !status.enabled {
            do { try closet.start() }
            catch let error as WindowCloset.Unavailable { disable(reason: error.reason); return }
            catch { disable(reason: "SkyLight could not create the hidden Space"); return }
            status.enabled = true
            status.reason = "experiment on"
            status.active = 1
            enablingFront = NSWorkspace.shared.frontmostApplication?.processIdentifier
            initialApplications = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
            for id in entries.keys.sorted() { assign(id, to: 1); if railEnabled && railTile(id) { addRailTile(id, initial: true) } }
            if let front = enablingFront, let current = appFocus[front], available(current) {
                rememberInitialFocus(current)
            }
            installKeys()
            if !entries.isEmpty { render(focusing: focused ?? preferred(in: 1), relayout: true) }
        } else {
            if old.keys != next.keys { installKeys() }
            if old.gaps != next.gaps {
                if railEnabled {
                    for id in entries.keys where rails.location(id) != nil {
                        if var size = rails.size(id) { size.width = min(size.width,area.width); size.height = area.height; rails.setSize(id,size) }
                        railSizing.insert(id)
                    }
                }
                render(focusing: focused, relayout: true)
            }
        }
        publish()
    }

    private func installKeys() {
        hotkeys?.stop()
        hotkeys = nil
        do { hotkeys = try Hotkeys(keys: configuration.keys) { [weak self] in self?.perform($0) } }
        catch { disable(reason: "Could not register workspace hotkeys") }
    }

    func disable(reason: String) {
        transition += 1
        focusDecision?.cancel()
        catalog?.cancelPresentations()
        hotkeys?.stop()
        hotkeys = nil
        // Return only our managed windows. Fullscreen windows are never touched.
        if railEnabled || !rails.workspaces.isEmpty { catalog?.returnInside(ids: Set(entries.keys.filter { entries[$0]?.workspace != nil && entries[$0]?.observation.record.state != .fullscreen }), area: area) }
        rails = Rails()
        railSizing.removeAll()
        status.rail = nil
        status.railCount = 0
        closet?.stop(returning: entries.filter { $0.value.workspace != nil && $0.value.observation.record.state != .fullscreen }.map(\.key))
        closeted.removeAll()
        arrival.removeAll()
        focused = nil
        expectedFocus = nil
        for id in entries.keys { entries[id]?.workspace = nil }
        status.enabled = false
        status.reason = reason
        status.active = 1
        publish()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in self?.publish() }
    }

    func update(pid: pid_t, observations: [WindowObservation], focused rawFocus: UInt32?, frontmost: Bool, change: CatalogChange) {
        let incoming = Set(observations.map { $0.record.id })
        var replacements = Set<UInt32>()
        var hiddenReplacements = Set<UInt32>()
        // A native group's selected CG window changes without a new arrival.
        // Transfer policy state atomically before reconciling the new facts.
        for observation in observations {
            guard let previous = observation.replaces, !incoming.contains(previous),
                  entries[previous]?.pid == pid else { continue }
            if closeted.contains(previous) { hiddenReplacements.insert(observation.record.id) }
            replace(previous, with: observation.record.id)
            replacements.insert(observation.record.id)
        }
        // AX focuses the sheet itself; workspace selection, sends and expected
        // focus all belong to the window that owns it.
        let reportedFocus = rawFocus.map { id in
            let current = observations.first(where: { $0.replaces == id })?.record.id ?? id
            return observations.first(where: { $0.record.id == current })?.parent ?? current
        }
        let previous = entries.filter { $0.value.pid == pid }
        appFocus[pid] = reportedFocus
        let previousFocus = focused
        let lostCurrent = previousFocus.map { previous[$0] != nil && !incoming.contains($0) } ?? false
        var needsRender = false
        var closeSelection: UInt32?
        for id in previous.keys where !incoming.contains(id) {
            if previous[id]?.workspace == status.active && !closeted.contains(id) { needsRender = true }
            if id == previousFocus { closeSelection = rails.remove(id) }
            forget(id)
        }
        if observations.isEmpty { store.update(pid: pid, windows: []) }
        let firstSnapshot = knownApplications.insert(pid).inserted
        let onScreen = Self.onScreen()
        if let closet {
            let candidates = observations.filter {
                primary($0) && $0.parent == nil && availableState($0.record.state)
                    && (previous[$0.record.id].map { !availableState($0.observation.record.state) } ?? true)
            }.map { $0.record.id }
            closet.recover(candidates, offscreen: Set(candidates).subtracting(onScreen))
        }
        var newWindows: [UInt32] = []
        var restored: [UInt32] = []
        var changedTiling = false
        var newlyTiled = Set<UInt32>()
        var enteredFullscreen = false
        var resizedRail = false
        for observation in observations.sorted(by: { $0.record.id < $1.record.id }) {
            let id = observation.record.id
            let old = entries[id]
            entries[id] = Entry(observation: observation, pid: pid, workspace: old?.workspace, recent: old?.recent ?? 0)
            if observation.record.state == .fullscreen || !primary(observation) {
                if old?.workspace != nil {
                    detach(id)
                    closeted.remove(id)
                    needsRender = true
                    enteredFullscreen = enteredFullscreen || observation.record.state == .fullscreen
                }
                continue
            }
            guard status.enabled else { continue }
            if entries[id]?.workspace == nil {
                assign(id, to: observation.parent.flatMap { entries[$0]?.workspace } ?? status.active)
                newWindows.append(id)
                needsRender = true
            }
            if railEnabled {
                if railTile(id) {
                    if rails.location(id) == nil { addRailTile(id, initial: firstSnapshot && initialApplications.contains(pid) && old == nil, restoring: old != nil); needsRender = true }
                    else if let old, !railSizing.contains(id), abs(old.observation.frame.width-observation.frame.width) > 1,
                            var size = rails.size(id), abs(size.width-observation.frame.width) > 1 {
                        size.width = min(area.width,observation.frame.width)
                        rails.setSize(id,size)
                        resizedRail = true
                    }
                } else { rails.remove(id, suspending: true) }
            }
            if let old, [.minimized, .hidden, .fullscreen].contains(old.observation.record.state), available(id) {
                restored.append(id)
                needsRender = true
            }
            if let old, availableState(old.observation.record.state) != available(id) { needsRender = true }
            if let old, availableState(old.observation.record.state), available(id), old.observation.record.state != observation.record.state {
                changedTiling = true
                if observation.record.state == .tiled { newlyTiled.insert(id) }
            }
        }
        guard status.enabled else { publish(); return }
        if lostCurrent || previousFocus.map({ !available($0) }) == true {
            focusDecision?.cancel()
            expectedFocus = nil
            focused = closeSelection ?? mostRecent(in: status.active)
            needsRender = true
        }
        // Entering a native fullscreen Space is the user's operation. Keep the
        // remaining stack in its closet instead of bringing a sibling into it.
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? (frontmost ? pid : nil)
        let frontFocus = front.flatMap { appFocus[$0] }
        let nativeFullscreenOwnsFront = frontFocus.map { entries[$0]?.observation.record.state == .fullscreen }
            ?? entries.contains { $0.value.pid == front && $0.value.observation.record.state == .fullscreen && onScreen.contains($0.key) }
        if enteredFullscreen || nativeFullscreenOwnsFront && (pid == front || firstSnapshot || newWindows.isEmpty && restored.isEmpty) {
            focusDecision?.cancel()
            expectedFocus = nil
            publish()
            return
        }
        let restoredRoots = restored.filter { entries[$0]?.observation.parent == nil }
        let restoredFocus = reportedFocus.flatMap { restoredRoots.contains($0) ? $0 : nil }
            ?? restoredRoots.max { (entries[$0]?.recent ?? 0) < (entries[$1]?.recent ?? 0) }
        if let restored = restoredFocus {
            if let workspace = entries[restored]?.workspace { status.active = workspace }
            remember(restored)
            render(focusing: restored, relayout: false, layoutWindows: Set(restoredRoots))
        } else if let newest = newWindows.last(where: { available($0) && entries[$0]?.observation.parent == nil }) {
            // Initial enumeration preserves the app's actual focused window. Later
            // creations join the end of arrival order and become visible immediately.
            let initialEnumeration = firstSnapshot && (!railEnabled || initialApplications.contains(pid))
            let selection = initialEnumeration && frontmost ? reportedFocus.flatMap { available($0) ? $0 : nil } ?? newest : newest
            if initialEnumeration && !frontmost && pid != enablingFront, let current = focused, available(current) {
                render(focusing: current, relayout: false, layoutWindows: Set(newWindows))
            } else if initialEnumeration && !frontmost && pid != enablingFront && focused == nil {
                render(focusing: nil, relayout: false, activateDesktop: false, layoutWindows: Set(newWindows))
            } else {
                if initialEnumeration && frontmost { rememberInitialFocus(selection) }
                else { remember(selection) }
                render(focusing: selection, relayout: false, layoutWindows: Set(newWindows))
            }
        } else if needsRender || resizedRail {
            render(focusing: focused ?? preferred(in: status.active), relayout: false, layoutWindows: hiddenReplacements)
        } else if !replacements.isEmpty {
            if frontmost, front == pid, let reportedFocus, replacements.contains(reportedFocus), available(reportedFocus) {
                followExternalFocus(reportedFocus, layoutWindows: hiddenReplacements)
            } else if !hiddenReplacements.isEmpty {
                render(focusing: focused, relayout: false, takeFocus: false)
            }
        } else if changedTiling {
            // A classification change does not move focus. Reassert it only when
            // the app reports another window: a redundant raise of a native tab
            // can select it again over a tab the user has just chosen.
            let owner = focused.flatMap { entries[$0]?.pid }
            let stillFront = owner == NSWorkspace.shared.frontmostApplication?.processIdentifier
            let focusMoved = owner.flatMap { appFocus[$0] } != focused
            render(focusing: focused, relayout: false, takeFocus: stillFront && focusMoved, layoutWindows: newlyTiled)
        } else if frontmost, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let reportedFocus, available(reportedFocus), entries[reportedFocus]?.observation.parent == nil {
            if reportedFocus == expectedFocus { expectedFocus = nil }
            else if change == .activation || change == .restored {
                // Our activation can arrive after a newer keyboard selection.
                // Wait for its same-app presentation to acknowledge focus; a
                // different app's activation is still an external selection.
                let pendingHere = expectedFocus.flatMap { entries[$0]?.pid } == pid
                if change == .restored || !pendingHere { followExternalFocus(reportedFocus) }
            }
            else if change == .focus && reportedFocus != focused, expectedFocus == nil {
                // AppKit promotes a hidden sibling before reporting destruction of
                // the closing window. Let that bounded destruction snapshot win.
                focusDecision?.cancel()
                let token = transition
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.transition == token, self.available(reportedFocus),
                          self.appFocus[pid] == reportedFocus,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    self.followExternalFocus(reportedFocus)
                }
                focusDecision = item
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: item)
            }
        }
        publish()
    }

    func remove(pid: pid_t) {
        let removed = entries.filter { $0.value.pid == pid }
        let affectsVisible = removed.contains { $0.value.workspace == status.active && !closeted.contains($0.key) }
        for id in removed.keys { forget(id) }
        knownApplications.remove(pid)
        appFocus.removeValue(forKey: pid)
        store.update(pid: pid, windows: nil)
        if status.enabled && affectsVisible { render(focusing: preferred(in: status.active), relayout: false) }
        publish()
    }

    private func perform(_ command: WorkspaceCommand) {
        guard status.enabled else { return }
        focusDecision?.cancel()
        switch command {
        case .workspace(let number):
            guard number != status.active else { return }
            status.active = number
            render(focusing: preferred(in: number), relayout: false)
        case .send(let number):
            guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let actual = appFocus[front], let focused, let entry = entries[focused], entry.pid == front,
                  (entries[actual]?.observation.parent ?? actual) == focused, available(focused),
                  let workspace = entry.workspace, workspace != number else { return }
            rails.remove(focused)
            detach(focused)
            assign(focused, to: number)
            for id in entries.keys where entries[id]?.observation.parent == focused {
                detach(id)
                assign(id, to: number)
            }
            if railEnabled && railTile(focused) { addRailTile(focused) }
            status.active = number
            remember(focused)
            render(focusing: focused, relayout: false, layoutWindows: [focused])
        case .focus(let direction):
            guard railEnabled else { return }
            if entries[focused ?? 0]?.observation.record.state == .floats && rails.location(focused ?? 0) == nil {
                perform(direction == .left || direction == .up ? .previous : .next); return
            }
            let next = direction == .left || direction == .right
                ? rails.focusX(status.active,direction:direction == .left ? -1 : 1)
                : rails.focusY(status.active,direction:direction == .up ? -1 : 1)
            guard let next else { return }
            remember(next); render(focusing:next,relayout:false)
        case .move(let direction):
            guard railEnabled, let focused, rails.location(focused) != nil else { return }
            let moved = direction == .left || direction == .right
                ? rails.moveX(focused,direction:direction == .left ? -1 : 1)
                : rails.moveY(focused,direction:direction == .up ? -1 : 1)
            guard moved else { return }
            render(focusing:focused,relayout:false)
        case .next, .previous:
            if railEnabled, let focused, rails.location(focused) != nil {
                guard let next = rails.focusX(status.active,direction: { if case .next = command { return 1 }; return -1 }()) else { return }
                remember(next); render(focusing:next,relayout:false); publish(); return
            }
            let order = (arrival[status.active] ?? []).filter { available($0) && entries[$0]?.observation.parent == nil }
            guard !order.isEmpty else { return }
            let index = focused.flatMap { order.firstIndex(of: $0) } ?? 0
            let step = if case .next = command { 1 } else { -1 }
            let next = order[(index + step + order.count) % order.count]
            remember(next)
            render(focusing: next, relayout: false)
        }
        publish()
    }

    private func followExternalFocus(_ id: UInt32, layoutWindows: Set<UInt32> = []) {
        guard let workspace = entries[id]?.workspace else { return }
        // macOS can re-activate the already selected app when another process
        // exits. Its visible window has not been shown again or switched.
        guard id != focused || workspace != status.active || closeted.contains(id) || !layoutWindows.isEmpty else { return }
        status.active = workspace
        remember(id)
        render(focusing: id, relayout: false, layoutWindows: layoutWindows)
        publish()
    }

    private func render(focusing selection: UInt32?, relayout: Bool, activateDesktop: Bool = true, takeFocus: Bool = true,
                        layoutWindows: Set<UInt32> = []) {
        guard status.enabled, let closet else { return }
        if railEnabled { renderRails(focusing: selection, activateDesktop: activateDesktop, takeFocus: takeFocus); return }
        focusDecision?.cancel()
        transition += 1
        let token = transition
        expectedFocus = nil
        catalog?.cancelPresentations()
        if let selection, available(selection) { remember(selection) } else { focused = nil }
        let workspace = status.active
        let eligible = entries.keys.filter { entries[$0]?.workspace == workspace && available($0) }
        let tile = eligible.filter { entries[$0]?.observation.record.state == .tiled && entries[$0]?.observation.parent == nil }
            .max { ((entries[$0]?.recent ?? 0), $0) < ((entries[$1]?.recent ?? 0), $1) }
        var show = Set(eligible.filter { entries[$0]?.observation.record.state == .floats && entries[$0]?.observation.parent == nil })
        if let tile { show.insert(tile) }
        for id in entries.keys {
            if let parent = entries[id]?.observation.parent, show.contains(parent), available(id) { show.insert(id) }
        }
        let managed = Set(entries.keys.filter { entries[$0]?.workspace != nil && available($0) })
        let hide = managed.subtracting(show)
        let newlyHidden = hide.subtracting(closeted)
        let newlyShown = show.intersection(closeted).union(show.subtracting(Self.onScreen()))
        closet.hide(newlyHidden.filter { entries[$0]?.observation.parent == nil })
        closet.show(newlyShown.filter { entries[$0]?.observation.parent == nil })
        closeted.formUnion(hide)
        closeted.subtract(show)
        if let focused, entries[focused] != nil {
            if takeFocus { expectedFocus = focused }
            for id in show.sorted() where entries[id]?.observation.parent == nil {
                guard let candidate = entries[id] else { continue }
                let layout = relayout || layoutWindows.contains(id) || newlyShown.contains(id)
                let area = layout && (candidate.observation.record.state == .tiled || candidate.observation.record.reason == "cannot fill the screen") ? self.area : nil
                guard layout || takeFocus && id == focused else { continue }
                catalog?.present(pid: candidate.pid, id: id, area: area, focus: takeFocus && id == focused) { [weak self] in
                    guard let self, self.status.enabled, self.transition == token else { return }
                    if takeFocus && id == focused { self.expectedFocus = nil }
                    self.publish()
                }
            }
        } else if activateDesktop {
            // A plain activation focuses the desktop; reopening Finder can focus
            // a closeted window. Never use openApplication or activateAllWindows.
            activateFinderDesktop()
        }
        // Bridged moves are asynchronous. One bounded check validates the hide;
        // nothing is scheduled once the transition has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self, self.transition == token, self.status.enabled else { return }
            if !hide.intersection(Self.onScreen()).isEmpty {
                self.disable(reason: "SkyLight could not hide a window")
            } else { self.publish() }
        }
    }

    private func activateFinderDesktop() {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        guard LaunchOptions.fixtureOnly else { finder.activate(); return }
        // A busy Finder, or one answering its first AX client, can miss a
        // short timeout. That is not evidence of an ordinary window: retry
        // failed reads off the main thread, and let only this render activate.
        let pid = finder.processIdentifier
        let token = transition
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var safe: Bool?
            for _ in 0..<3 where safe == nil { safe = Self.finderListsOnlyItsDesktop(pid) }
            guard safe == true else { return }
            DispatchQueue.main.async {
                guard let self, self.status.enabled, self.transition == token, self.focused == nil,
                      let finder = NSRunningApplication(processIdentifier: pid),
                      finder.bundleIdentifier == "com.apple.finder" else { return }
                finder.activate()
            }
        }
    }

    /// Finder includes its desktop scroll area in AXWindows. Permit only that
    /// known non-window element; ordinary or unknown entries return false and
    /// failed reads return nil, so neither activates an unmanaged Finder window.
    private nonisolated static func finderListsOnlyItsDesktop(_ pid: pid_t) -> Bool? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for window in windows {
            AXUIElementSetMessagingTimeout(window, 0.05)
            var role: CFTypeRef?, subrole: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success else { return nil }
            guard role as? String == kAXScrollAreaRole else { return false }
            switch AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) {
            case .noValue, .attributeUnsupported: continue
            case .success: return false
            default: return nil
            }
        }
        return true
    }

    private func replace(_ previous: UInt32, with id: UInt32) {
        if entries[id] != nil { forget(id) }
        guard let entry = entries.removeValue(forKey: previous) else { return }
        entries[id] = entry
        if let workspace = entry.workspace, let index = arrival[workspace]?.firstIndex(of: previous) {
            arrival[workspace]?[index] = id
        }
        rails.replace(previous,with:id)
        if railSizing.remove(previous) != nil { railSizing.insert(id) }
        if focused == previous { focused = id }
        if expectedFocus == previous { expectedFocus = id }
        // Hide intent follows membership and focus history. A new CG window
        // still needs its own move; do not inherit the old ID's completed move.
        closeted.remove(previous)
    }

    private func assign(_ id: UInt32, to workspace: Int) {
        guard let entry = entries[id], entry.observation.record.state != .fullscreen, primary(entry.observation) else { return }
        entries[id]?.workspace = workspace
        if !(arrival[workspace] ?? []).contains(id) { arrival[workspace, default: []].append(id) }
    }

    private func detach(_ id: UInt32) {
        rails.remove(id)
        railSizing.remove(id)
        if let workspace = entries[id]?.workspace { arrival[workspace]?.removeAll { $0 == id } }
        entries[id]?.workspace = nil
    }

    private func forget(_ id: UInt32) {
        rails.forget(id)
        detach(id)
        entries.removeValue(forKey: id)
        closeted.remove(id)
    }

    private func rememberInitialFocus(_ id: UInt32) {
        // A focused dialog leaves its existing tile underneath. At startup no
        // focus history exists yet, so seed it from the visible stacking order.
        if entries[id]?.observation.record.state == .floats, let workspace = entries[id]?.workspace,
           let tile = Self.onScreenOrder().first(where: {
               entries[$0]?.workspace == workspace && entries[$0]?.observation.record.state == .tiled
                   && entries[$0]?.observation.parent == nil
           }) {
            remember(tile)
        }
        remember(id)
    }

    private func remember(_ id: UInt32) {
        clock += 1
        entries[id]?.recent = clock
        focused = id
        if railEnabled { rails.select(id) }
    }

    private func preferred(in workspace: Int) -> UInt32? {
        if railEnabled, let id = rails.remembered(workspace), available(id) { return id }
        return mostRecent(in: workspace)
    }

    private func mostRecent(in workspace: Int) -> UInt32? {
        entries.keys.filter { entries[$0]?.workspace == workspace && entries[$0]?.observation.parent == nil && available($0) }
            .max { ((entries[$0]?.recent ?? 0), $0) < ((entries[$1]?.recent ?? 0), $1) }
    }

    private func availableState(_ state: WindowState) -> Bool { state == .tiled || state == .floats }
    private func available(_ id: UInt32) -> Bool { entries[id].map { availableState($0.observation.record.state) } ?? false }

    private func primary(_ observation: WindowObservation) -> Bool {
        if railEnabled && (rails.location(observation.record.id) != nil || entries[observation.record.id]?.workspace != nil) { return true }
        guard let screen = NSScreen.screens.first else { return false }
        return CGRect(x: screen.frame.minX, y: 0, width: screen.frame.width, height: screen.frame.height)
            .contains(CGPoint(x: observation.frame.midX, y: observation.frame.midY))
    }

    private var area: CGRect {
        guard let screen = NSScreen.screens.first else { return .zero }
        let frame = screen.visibleFrame
        let gap = configuration.gaps.outer
        let width = max(1, frame.width - 2 * gap), height = max(1, frame.height - 2 * gap)
        return CGRect(x: frame.midX - width / 2, y: screen.frame.height - frame.midY - height / 2,
                      width: width, height: height)
    }

    private static func onScreen() -> Set<UInt32> { Set(onScreenOrder()) }

    private static func onScreenOrder() -> [UInt32] {
        // Only IDs survive this query. Drain Objective-C bridge temporaries
        // without waiting for AppKit's next input event on the main thread.
        autoreleasepool {
            (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        }
    }

    private func publish() {
        if railEnabled && status.enabled {
            let ws = rails.workspaces[status.active]
            status.railCount = ws?.rails.count ?? 0
            status.rail = status.railCount > 0 ? (ws?.current ?? 0)+1 : nil
        }
        let visible = Self.onScreen()
        var rows: [pid_t: [WindowRecord]] = [:]
        for (id, entry) in entries {
            var row = entry.observation.record
            row.workspace = status.enabled ? entry.workspace : nil
            row.visible = visible.contains(id)
            if railEnabled && status.enabled, let p = rails.location(id) {
                row.rail = p.rail+1; row.slot = p.slot+1
                row.state = .tiled
                if let size = rails.size(id), size.height < area.height-2 { row.reason = "maximum height; aligned to top" }
                else if row.reason == "cannot fill the screen" { row.reason = "standard window" }
            }
            rows[entry.pid, default: []].append(row)
        }
        for (pid, windows) in rows { store.update(pid: pid, windows: windows) }
        if status != publishedStatus {
            publishedStatus = status
            onChange?()
        }
    }

    private func railTile(_ id: UInt32) -> Bool {
        guard let e = entries[id], e.workspace != nil, e.observation.parent == nil, available(id) else { return false }
        return e.observation.record.state == .tiled || e.observation.record.reason == "cannot fill the screen"
    }

    private func addRailTile(_ id: UInt32, initial: Bool = false, restoring: Bool = false) {
        guard let entry = entries[id], let workspace = entry.workspace else { return }
        let tile = Rails.Tile(id:id,size:CGSize(width:min(area.width,entry.observation.frame.width),height:area.height))
        if initial { rails.appendInitial(tile,workspace:workspace) }
        else { rails.insert(tile,workspace:workspace,restoring:restoring) }
        railSizing.insert(id)
    }

    private func renderRails(focusing selection: UInt32?, activateDesktop: Bool, takeFocus: Bool) {
        guard status.enabled, let closet else { return }
        focusDecision?.cancel()
        transition += 1
        let token = transition
        expectedFocus = nil
        catalog?.cancelPresentations()
        if let selection, available(selection) { remember(selection) } else { focused = nil }
        let frames = rails.frames(status.active,area:area)
        let screen = NSScreen.screens.first!
        let bounds = CGRect(x:screen.frame.minX,y:0,width:screen.frame.width,height:screen.frame.height)
        var show = Set(frames.filter { $0.value.intersects(bounds) }.keys)
        show.formUnion(entries.keys.filter {
            entries[$0]?.workspace == status.active && available($0) && entries[$0]?.observation.parent == nil && rails.location($0) == nil
        })
        for id in entries.keys {
            if let parent = entries[id]?.observation.parent, show.contains(parent), available(id) { show.insert(id) }
        }
        let managed = Set(entries.keys.filter { entries[$0]?.workspace != nil && available($0) })
        let hide = managed.subtracting(show)
        closet.hide(hide.subtracting(closeted).filter { entries[$0]?.observation.parent == nil })
        closet.show(show.intersection(closeted).union(show.subtracting(Self.onScreen())).filter { entries[$0]?.observation.parent == nil })
        closeted.formUnion(hide); closeted.subtract(show)
        if let focused, takeFocus { expectedFocus = focused }
        // Focus first, then neighbors in spatial order; each app keeps its own
        // queue and timeout. Scrolls write only positions, never AXSize.
        let ordered = show.union(railSizing).sorted {
            if $0 == focused { return true }; if $1 == focused { return false }
            return (frames[$0]?.minX ?? 0,$0) < (frames[$1]?.minX ?? 0,$1)
        }
        for id in ordered where entries[id]?.observation.parent == nil {
            guard let candidate = entries[id] else { continue }
            let visible = show.contains(id)
            let target = visible ? frames[id] : rails.size(id).map { CGRect(origin:area.origin,size:$0) }
            let resize = railSizing.contains(id)
            guard target != nil || takeFocus && id == focused else { continue }
            catalog?.presentRail(pid:candidate.pid,id:id,frame:target,position:visible,resize:resize,focus:takeFocus && id == focused) { [weak self] accepted in
                guard let self, self.status.enabled, self.railEnabled else { return }
                if resize, let accepted {
                    self.railSizing.remove(id)
                    let previous = self.rails.size(id)
                    self.rails.setSize(id,accepted.size)
                    if let previous, abs(previous.width-accepted.width)>1 {
                        self.render(focusing:self.focused,relayout:false,takeFocus:false)
                    }
                }
                if self.transition == token && id == focused { self.expectedFocus = nil }
                self.publish()
            }
        }
        if focused == nil && activateDesktop { activateFinderDesktop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self, self.transition == token, self.status.enabled else { return }
            if !hide.intersection(Self.onScreen()).isEmpty { self.disable(reason:"SkyLight could not hide a window") }
            else { self.publish() }
        }
    }

}
