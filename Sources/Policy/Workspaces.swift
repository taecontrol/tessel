import Foundation
import CoreGraphics
#if SWIFT_PACKAGE
import Ports
#endif

/// Owns membership, arrival order and focus history. AX workers supply facts and
/// perform bounded app-specific writes; they never decide workspace policy.
@MainActor
final class Workspaces {
    private struct Entry {
        var observation: WindowObservation
        let pid: Int32
        var workspace: Int?
        var recent: UInt64 = 0
    }
    private let store: any WindowPublishing
    private let applications: any ApplicationPort
    private let ax: any AccessibilityPort
    private let screens: any ScreenPort
    private let windowOrder: any WindowOrderPort
    private let scheduler: any SchedulingPort
    private let hotkeyInstaller: any HotkeyInstalling
    private let motionPreferences: (any MotionPreferencePort)?
    private var motionObservation: (any MotionPreferenceObservation)?
    private var pointerObservation: (any MotionPreferenceObservation)?
    private var movingCarousel = false
    private var interruptedSizing = Set<UInt32>()
    private let animator: CarouselAnimator?
    private var cardDirection: Int?
    private var wall: CGPoint?
    private let fixtureOnly: Bool
    private let trusted: Bool
    private var configuration = Configuration()
    private var entries: [UInt32: Entry] = [:]
    private var arrival: [Int: [UInt32]] = [:]
    private var carousel = Carousel()
    private var carouselSizing = Set<UInt32>()
    private var carouselSizes: [UInt32: CGSize] = [:]
    private struct CarouselPresentation {
        var workspace: Int
        var rail: UInt64?
        var railIndex: Int
        var frames: [UInt32: CGRect]
        var pending: Set<UInt32>
    }
    private var carouselPresentation: CarouselPresentation?
    private var carouselEnabled: Bool { configuration.experiments["carousel"] == true }
    private var focused: UInt32?
    private var clock: UInt64 = 0
    private var closet: WindowCloset?
    private var unavailable: String?
    private var hotkeys: (any HotkeyRegistration)?
    private var closeted = Set<UInt32>()
    private var expectedFocus: UInt32?
    private var focusDecision: (any ScheduledWork)?
    private var transition: UInt64 = 0
    private var knownApplications = Set<Int32>()
    private var appFocus: [Int32: UInt32] = [:]
    private var enablingFront: Int32?
    private var initialApplications = Set<Int32>()
    private var publishedStatus: WorkspaceStatus?
    private(set) var status = WorkspaceStatus()
    weak var catalog: WindowCatalog?
    var onChange: (() -> Void)?

    init(store: any WindowPublishing, trusted: Bool, configuration: Configuration,
         applications: any ApplicationPort, ax: any AccessibilityPort, screens: any ScreenPort,
         windowOrder: any WindowOrderPort, scheduler: any SchedulingPort, hotkeys: any HotkeyInstalling,
         fixtureOnly: Bool = false, motionPreferences: (any MotionPreferencePort)? = nil,
         displayFrames: (any DisplayFramePort)? = nil, pointerActivity: (any PointerActivityPort)? = nil,
         makeCloset: () throws -> any ClosetPort) {
        self.store = store
        self.trusted = trusted
        self.applications = applications
        self.ax = ax
        self.screens = screens
        self.windowOrder = windowOrder
        self.scheduler = scheduler
        self.hotkeyInstaller = hotkeys
        self.fixtureOnly = fixtureOnly
        self.motionPreferences = motionPreferences
        self.animator = displayFrames.map { CarouselAnimator(display: $0) }
        motionObservation = motionPreferences?.observe { [weak self] _ in self?.publish() }
        pointerObservation = pointerActivity?.observePress { [weak self] in self?.interruptCarousel() }
        if trusted {
            do { closet = WindowCloset(mechanics: try makeCloset()) }
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
        guard next.experiments["workspaces"] == true || carouselEnabled else { disable(reason: "experiment off"); return }
        guard trusted else { disable(reason: "Accessibility permission needed"); return }
        guard let closet, unavailable == nil else { disable(reason: unavailable ?? "SkyLight window hiding is unavailable"); return }
        carousel.width = area.width
        carousel.gap = next.gaps.outer
        status.layout = carouselEnabled ? "carousel" : "stack"
        let layoutChanged = old.experiments["carousel"] != next.experiments["carousel"]
        if status.enabled && layoutChanged {
            animator?.cancel()
            movingCarousel = false
            catalog?.endMotion()
            if !carouselEnabled { catalog?.returnInside(ids: Set(entries.keys.filter { entries[$0]?.workspace != nil && entries[$0]?.observation.record.state != .fullscreen }), area: area) }
            carousel = Carousel(width: area.width, gap: next.gaps.outer)
            carouselSizing.removeAll()
            carouselSizes.removeAll()
            carouselPresentation = nil
            if carouselEnabled {
                for workspace in arrival.keys.sorted() {
                    for id in arrival[workspace] ?? [] where railTile(id) { addCarouselTile(id, initial: true) }
                }
                if let focused { carousel.select(focused) }
            }
            installKeys()
            // A layout change retains the native selection. Its notification
            // can still be queued behind an app's current AX read.
            render(focusing: focused, relayout: true, takeFocus: false)
        }
        if !status.enabled {
            do { try closet.start() }
            catch let error as WindowCloset.Unavailable { disable(reason: error.reason); return }
            catch { disable(reason: "SkyLight could not create the hidden Space"); return }
            status.enabled = true
            status.reason = "experiment on"
            status.active = 1
            enablingFront = applications.frontmostPID
            initialApplications = Set(applications.runningApplications.map(\.pid))
            for id in entries.keys.sorted() { assign(id, to: 1); if carouselEnabled && railTile(id) { addCarouselTile(id, initial: true) } }
            // The front app already shows its focused window. Its last read
            // can predate a newer native selection; raising it would take
            // focus back, so render without a focus request. A fresh report
            // then selects whichever window really has focus.
            var nativeFocus: UInt32?
            if let front = enablingFront, let current = appFocus[front], available(current) {
                rememberInitialFocus(current)
                nativeFocus = current
            }
            installKeys()
            if !entries.isEmpty { render(focusing: focused ?? preferred(in: 1), relayout: true, takeFocus: nativeFocus == nil) }
        } else {
            if old.keys != next.keys { installKeys() }
            if old.gaps != next.gaps {
                if carouselEnabled {
                    carousel.resizeArea(height: area.height)
                    carouselSizing.formUnion(entries.keys.filter { carousel.location($0) != nil })
                }
                render(focusing: focused, relayout: true, takeFocus: false)
            }
        }
        publish()
    }

    private func installKeys() {
        hotkeys?.stop()
        hotkeys = nil
        let keys = configuration.keys.filter { binding in
            guard !carouselEnabled, let command = WorkspaceCommand(binding.value) else { return true }
            switch command { case .focus, .move, .cycleWidth: return false; default: return true }
        }
        do { hotkeys = try hotkeyInstaller.install(keys: keys) { [weak self] in self?.perform($0) } }
        catch { disable(reason: "Could not register workspace hotkeys") }
    }

    func disable(reason: String) {
        animator?.cancel()
        movingCarousel = false
        catalog?.endMotion()
        transition += 1
        focusDecision?.cancel()
        catalog?.cancelPresentations()
        hotkeys?.stop()
        hotkeys = nil
        // Return only our managed windows. Fullscreen windows are never touched.
        if carouselEnabled || !carousel.workspaces.isEmpty { catalog?.returnInside(ids: Set(entries.keys.filter { entries[$0]?.workspace != nil && entries[$0]?.observation.record.state != .fullscreen }), area: area) }
        carousel = Carousel()
        carouselSizing.removeAll()
        carouselSizes.removeAll()
        carouselPresentation = nil
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
        scheduler.main.after(milliseconds: 30) { [weak self] in self?.publish() }
    }

    func update(pid: Int32, observations: [WindowObservation], focused rawFocus: UInt32?, frontmost: Bool, change: CatalogChange) {
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
            if id == previousFocus { closeSelection = carousel.remove(id) }
            forget(id)
        }
        if observations.isEmpty { store.update(pid: pid, windows: []) }
        let firstSnapshot = knownApplications.insert(pid).inserted
        let onScreen = onScreen()
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
            if carouselEnabled {
                if railTile(id) {
                    if carousel.location(id) == nil { addCarouselTile(id, initial: firstSnapshot && initialApplications.contains(pid) && old == nil, restoring: old != nil); needsRender = true }
                    else if let old, !carouselSizing.contains(id), !closeted.contains(id),
                            abs(old.observation.frame.width-observation.frame.width) > 1 {
                        carousel.adoptWidth(id, observation.frame.width)
                        carouselSizes[id] = observation.frame.size
                        resizedRail = true
                    }
                } else { carousel.remove(id, suspending: true) }
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
        let interruptedHere = interruptedSizing.intersection(incoming)
        carouselSizing.subtract(interruptedHere)
        interruptedSizing.subtract(interruptedHere)
        guard status.enabled else { publish(); return }
        if lostCurrent || previousFocus.map({ !available($0) }) == true {
            focusDecision?.cancel()
            expectedFocus = nil
            // A coalesced destruction snapshot can also remove the neighbor
            // captured while the focused window was detached.
            focused = closeSelection.flatMap { available($0) ? $0 : nil }
                ?? (lostCurrent && carouselEnabled ? carousel.remembered(status.active) : nil)
                ?? mostRecent(in: status.active)
            needsRender = true
        }
        // Entering a native fullscreen Space is the user's operation. Keep the
        // remaining stack in its closet instead of bringing a sibling into it.
        let front = applications.frontmostPID ?? (frontmost ? pid : nil)
        let frontFocus = front.flatMap { appFocus[$0] }
        let nativeFullscreenOwnsFront = frontFocus.map { entries[$0]?.observation.record.state == .fullscreen }
            ?? entries.contains { $0.value.pid == front && $0.value.observation.record.state == .fullscreen && onScreen.contains($0.key) }
        if enteredFullscreen || nativeFullscreenOwnsFront && (pid == front || firstSnapshot || newWindows.isEmpty && restored.isEmpty) {
            if movingCarousel { interruptCarousel() }
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
            let initialEnumeration = firstSnapshot && (!carouselEnabled || initialApplications.contains(pid))
            let selection = initialEnumeration && frontmost ? reportedFocus.flatMap { available($0) ? $0 : nil } ?? newest : newest
            if initialEnumeration && !frontmost && pid != enablingFront, let current = focused, available(current) {
                // Discovery redraws cancel pending writes, but must finish a
                // keyboard selection already requested before this snapshot.
                render(focusing: current, relayout: false, takeFocus: expectedFocus == current, layoutWindows: Set(newWindows))
            } else if initialEnumeration && !frontmost && pid != enablingFront && focused == nil {
                render(focusing: nil, relayout: false, activateDesktop: false, layoutWindows: Set(newWindows))
            } else {
                if initialEnumeration && frontmost { rememberInitialFocus(selection) }
                else { remember(selection) }
                // Startup discovers a native selection; it does not request
                // one. This read can already predate a newer user selection.
                render(focusing: selection, relayout: false, takeFocus: !initialEnumeration, layoutWindows: Set(newWindows))
            }
        } else if needsRender || resizedRail {
            // A hidden app's first snapshot can precede the front app's.
            // Discovering it must not activate Finder or an older selection.
            let selection = focused ?? preferred(in: status.active)
            render(focusing: selection, relayout: false, takeFocus: !firstSnapshot || selection != nil && expectedFocus == selection,
                   layoutWindows: hiddenReplacements)
        } else if !replacements.isEmpty {
            if let focused, replacements.contains(focused), carouselPresentation?.pending.contains(focused) == true {
                // The old native root rejected this current presentation. Its
                // successor owns the unfinished position and focus intent.
                render(focusing: focused, relayout: false)
            } else if frontmost, front == pid, let reportedFocus, replacements.contains(reportedFocus), available(reportedFocus) {
                followExternalFocus(reportedFocus, layoutWindows: hiddenReplacements)
            } else if !hiddenReplacements.isEmpty {
                render(focusing: focused, relayout: false, takeFocus: false)
            }
        } else if changedTiling {
            // A classification change does not move focus. Reassert it only when
            // the app reports another window: a redundant raise of a native tab
            // can select it again over a tab the user has just chosen.
            let owner = focused.flatMap { entries[$0]?.pid }
            let stillFront = owner == applications.frontmostPID
            let focusMoved = owner.flatMap { appFocus[$0] } != focused
            render(focusing: focused, relayout: false, takeFocus: stillFront && focusMoved, layoutWindows: newlyTiled)
        } else if frontmost, applications.frontmostPID == pid,
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
                let item = scheduler.main.after(milliseconds: 50) { [weak self] in
                    guard let self, self.transition == token, self.available(reportedFocus),
                          self.appFocus[pid] == reportedFocus,
                          self.applications.frontmostPID == pid else { return }
                    self.followExternalFocus(reportedFocus)
                }
                focusDecision = item
            }
        }
        publish()
    }

    func remove(pid: Int32) {
        let removed = entries.filter { $0.value.pid == pid }
        let affectsVisible = removed.contains { $0.value.workspace == status.active && !closeted.contains($0.key) }
        let lostRailFocus = carouselEnabled && focused.map { removed[$0] != nil && carousel.location($0) != nil } == true
        for id in removed.keys { forget(id) }
        knownApplications.remove(pid)
        appFocus.removeValue(forKey: pid)
        store.update(pid: pid, windows: nil)
        if status.enabled && affectsVisible {
            // App termination closes its tiles just like a destruction snapshot;
            // a floating MRU must not override the surviving rail's selection.
            let selection = lostRailFocus ? carousel.remembered(status.active) ?? mostRecent(in: status.active) : preferred(in: status.active)
            render(focusing: selection, relayout: false)
        }
        publish()
    }

    private func perform(_ command: WorkspaceCommand) {
        guard status.enabled else { return }
        focusDecision?.cancel()
        switch command {
        case .workspace(let number):
            guard number != status.active else { return }
            status.active = number
            render(focusing: preferred(in: number), relayout: false, instant: true)
        case .send(let number):
            guard let front = applications.frontmostPID,
                  let actual = appFocus[front], let focused, let entry = entries[focused], entry.pid == front,
                  (entries[actual]?.observation.parent ?? actual) == focused, available(focused),
                  let workspace = entry.workspace, workspace != number else { return }
            let tile = carousel.tile(focused)
            carousel.remove(focused)
            detach(focused)
            assign(focused, to: number)
            for id in entries.keys where entries[id]?.observation.parent == focused {
                detach(id)
                assign(id, to: number)
            }
            if carouselEnabled && railTile(focused) {
                if let tile { carousel.insert(tile, workspace: number) }
                else { addCarouselTile(focused) }
            }
            status.active = number
            remember(focused)
            render(focusing: focused, relayout: false, layoutWindows: [focused], instant: true)
        case .focus(let direction):
            guard carouselEnabled else { return }
            if entries[focused ?? 0]?.observation.record.state == .floats && carousel.location(focused ?? 0) == nil {
                perform(direction == .left || direction == .up ? .previous : .next); return
            }
            let next = direction == .left || direction == .right
                ? carousel.focusX(status.active,direction:direction == .left ? -1 : 1)
                : carousel.focusY(status.active,direction:direction == .up ? -1 : 1)
            guard let next else { bounce(direction); return }
            if direction == .up || direction == .down { cardDirection = direction == .up ? -1 : 1 }
            remember(next); render(focusing:next,relayout:false)
        case .cycleWidth:
            guard carouselEnabled, let focused, carousel.location(focused) != nil else { return }
            carousel.cycleWidth(focused)
            render(focusing: focused, relayout: false)
        case .move(let direction):
            guard carouselEnabled, let focused, carousel.location(focused) != nil else { return }
            let moved = direction == .left || direction == .right
                ? carousel.moveX(focused,direction:direction == .left ? -1 : 1)
                : carousel.moveY(focused,direction:direction == .up ? -1 : 1)
            guard moved else { bounce(direction); return }
            if direction == .up || direction == .down { cardDirection = direction == .up ? -1 : 1 }
            // A successful reorder restores logical geometry after a mouse move,
            // even if the resulting target frames match the previous layout.
            render(focusing:focused,relayout:false)
        case .next, .previous:
            if carouselEnabled, let focused, carousel.location(focused) != nil {
                guard let next = carousel.focusX(status.active,direction: { if case .next = command { return 1 }; return -1 }()) else {
                    if case .next = command { bounce(.right) } else { bounce(.left) }; return
                }
                remember(next); render(focusing:next,relayout:false); publish(); return
            }
            let order = (arrival[status.active] ?? []).filter { available($0) && entries[$0]?.observation.parent == nil }
            guard !order.isEmpty else { return }
            let index = focused.flatMap { order.firstIndex(of: $0) } ?? 0
            let step = if case .next = command { 1 } else { -1 }
            if carouselEnabled && !order.indices.contains(index + step) { return }
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
        // Window destruction can precede process exit and its notification.
        // Preserve the dying rail owner so removal selects its adjacent rail.
        if carouselEnabled, let focused, let owner = entries[focused]?.pid,
           let pid = entries[id]?.pid, owner != pid {
            guard applications.isAlive(owner) else { return }
            catalog?.windowIsGone(pid: owner, id: focused) { [weak self] gone in
                guard let self, !gone, self.status.enabled,
                      self.focused == focused, self.available(id), self.appFocus[pid] == id,
                      self.applications.frontmostPID == pid else { return }
                self.selectExternalFocus(id, layoutWindows: layoutWindows)
            }
            return
        }
        selectExternalFocus(id, layoutWindows: layoutWindows)
    }

    private func selectExternalFocus(_ id: UInt32, layoutWindows: Set<UInt32>) {
        guard let workspace = entries[id]?.workspace else { return }
        status.active = workspace
        remember(id)
        // The native operation already selected this window. A queued raise
        // can otherwise interrupt a minimize that begins after this snapshot.
        render(focusing: id, relayout: false, takeFocus: false, layoutWindows: layoutWindows)
        publish()
    }

    private func render(focusing selection: UInt32?, relayout: Bool, activateDesktop: Bool = true, takeFocus: Bool = true,
                        layoutWindows: Set<UInt32> = [], instant: Bool = false) {
        guard status.enabled, let closet else { return }
        if carouselEnabled { renderCarousel(focusing: selection, activateDesktop: activateDesktop, takeFocus: takeFocus, instant: instant); return }
        focusDecision?.cancel()
        transition += 1
        let token = transition
        expectedFocus = nil
        catalog?.cancelPresentations(invalidatingFocus: takeFocus)
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
        let newlyShown = show.intersection(closeted).union(show.subtracting(onScreen()))
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
        } else if activateDesktop && takeFocus {
            // A plain activation focuses the desktop; reopening Finder can focus
            // a closeted window. Never use openApplication or activateAllWindows.
            activateFinderDesktop()
        }
        // Bridged moves are asynchronous. One bounded check validates the hide;
        // nothing is scheduled once the transition has settled.
        scheduler.main.after(milliseconds: 50) { [weak self] in
            guard let self, self.transition == token, self.status.enabled else { return }
            if !hide.intersection(self.onScreen()).isEmpty {
                self.disable(reason: "SkyLight could not hide a window")
            } else { self.publish() }
        }
    }

    private func activateFinderDesktop() {
        guard let finder = applications.applications(bundleID: "com.apple.finder").first else { return }
        guard fixtureOnly else { applications.activate(finder.pid); return }
        // A busy Finder, or one answering its first AX client, can miss a
        // short timeout. That is not evidence of an ordinary window: retry
        // failed reads off the main thread, and let only this render activate.
        let pid = finder.pid
        let token = transition
        let ax = ax, scheduler = scheduler
        scheduler.backgroundAsync { [weak self] in
            var safe: Bool?
            for _ in 0..<3 where safe == nil { safe = Self.finderListsOnlyItsDesktop(pid, ax: ax) }
            guard safe == true else { return }
            scheduler.main.async {
                guard let self, self.status.enabled, self.transition == token, self.focused == nil,
                      let finder = self.applications.application(pid),
                      finder.bundleID == "com.apple.finder" else { return }
                self.applications.activate(finder.pid)
            }
        }
    }

    /// Finder includes its desktop scroll area in AXWindows. Permit only that
    /// known non-window element; ordinary or unknown entries return false and
    /// failed reads return nil, so neither activates an unmanaged Finder window.
    private nonisolated static func finderListsOnlyItsDesktop(_ pid: Int32, ax: any AccessibilityPort) -> Bool? {
        let application = ax.application(pid)
        ax.setMessagingTimeout(application, seconds: 0.05)
        let value = ax.copy(.windows, of: application)
        guard value.status == .success, let windows = value.value?.elements else { return nil }
        for window in windows {
            ax.setMessagingTimeout(window, seconds: 0.05)
            let role = ax.copy(.role, of: window)
            guard role.status == .success else { return nil }
            guard role.value?.string == "AXScrollArea" else { return false }
            switch ax.copy(.subrole, of: window).status {
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
        carousel.replace(previous,with:id)
        if let frame = carouselPresentation?.frames.removeValue(forKey: previous) { carouselPresentation?.frames[id] = frame }
        if carouselPresentation?.pending.remove(previous) != nil { carouselPresentation?.pending.insert(id) }
        if carouselSizing.remove(previous) != nil { carouselSizing.insert(id) }
        if let size = carouselSizes.removeValue(forKey: previous) { carouselSizes[id] = size }
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
        carousel.remove(id)
        carouselSizing.remove(id)
        carouselSizes[id] = nil
        if let workspace = entries[id]?.workspace { arrival[workspace]?.removeAll { $0 == id } }
        entries[id]?.workspace = nil
    }

    private func forget(_ id: UInt32) {
        carousel.forget(id)
        detach(id)
        entries.removeValue(forKey: id)
        closeted.remove(id)
    }

    private func rememberInitialFocus(_ id: UInt32) {
        // A focused dialog leaves its existing tile underneath. At startup no
        // focus history exists yet, so seed it from the visible stacking order.
        if entries[id]?.observation.record.state == .floats, let workspace = entries[id]?.workspace,
           let tile = windowOrder.onScreenOrder().first(where: {
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
        if carouselEnabled { carousel.select(id) }
    }

    private func preferred(in workspace: Int) -> UInt32? {
        let recent = mostRecent(in: workspace)
        if carouselEnabled {
            // Floating dialogs retain the workspace's focus history; tiles
            // return to the current rail's remembered selection.
            if let recent, carousel.location(recent) == nil { return recent }
            if let id = carousel.remembered(workspace), available(id) { return id }
        }
        return recent
    }

    private func mostRecent(in workspace: Int) -> UInt32? {
        entries.keys.filter { entries[$0]?.workspace == workspace && entries[$0]?.observation.parent == nil && available($0) }
            .max { ((entries[$0]?.recent ?? 0), $0) < ((entries[$1]?.recent ?? 0), $1) }
    }

    private func availableState(_ state: WindowState) -> Bool { state == .tiled || state == .floats }
    private func available(_ id: UInt32) -> Bool { entries[id].map { availableState($0.observation.record.state) } ?? false }

    private func primary(_ observation: WindowObservation) -> Bool {
        if carouselEnabled && (carousel.location(observation.record.id) != nil || entries[observation.record.id]?.workspace != nil) { return true }
        guard let screen = screens.primaryScreen else { return false }
        return CGRect(x: screen.frame.minX, y: 0, width: screen.frame.width, height: screen.frame.height)
            .contains(CGPoint(x: observation.frame.midX, y: observation.frame.midY))
    }

    private var area: CGRect {
        guard let screen = screens.primaryScreen else { return .zero }
        let frame = screen.visibleFrame
        let gap = configuration.gaps.outer
        let width = max(1, frame.width - 2 * gap), height = max(1, frame.height - 2 * gap)
        return CGRect(x: frame.midX - width / 2, y: screen.frame.height - frame.midY - height / 2,
                      width: width, height: height)
    }

    private var screenRight: CGFloat { screens.primaryScreen?.frame.maxX ?? area.maxX }

    private func onScreen() -> Set<UInt32> { Set(windowOrder.onScreenOrder()) }

    private func publish() {
        status.animationDuration = motionPreferences?.reduceMotion == true ? 0 : configuration.animation.duration
        if carouselEnabled && status.enabled {
            let ws = carousel.workspaces[status.active]
            status.railCount = ws?.rails.count ?? 0
            status.rail = status.railCount > 0 ? (ws?.current ?? 0)+1 : nil
        }
        let visible = onScreen()
        var rows: [Int32: [WindowRecord]] = [:]
        for (id, entry) in entries {
            var row = entry.observation.record
            row.workspace = status.enabled ? entry.workspace : nil
            row.visible = visible.contains(id)
            if carouselEnabled && status.enabled, let p = carousel.location(id) {
                row.rail = p.rail+1; row.slot = p.slot+1
                row.state = .tiled
                if let size = carousel.size(id), size.height < area.height-2 { row.reason = "maximum height; aligned to top" }
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

    private func addCarouselTile(_ id: UInt32, initial: Bool = false, restoring: Bool = false) {
        guard let entry = entries[id], let workspace = entry.workspace else { return }
        let observed = min(area.width, entry.observation.frame.width)
        let preset = initial || restoring ? Carousel.presets.first { abs(carousel.presetWidth($0) - observed) <= 1 } : 0.5
        let tile = Carousel.Tile(id: id, size: CGSize(width: observed, height: area.height), preset: preset)
        if initial { carousel.appendInitial(tile,workspace:workspace) }
        else { carousel.insert(tile,workspace:workspace,restoring:restoring) }
        carouselSizes[id] = entry.observation.frame.size
    }

    private func bounce(_ direction: WorkspaceCommand.Direction) {
        guard carousel.current(status.active) != nil else { return }
        wall = switch direction {
        case .left: CGPoint(x: 1, y: 0)
        case .right: CGPoint(x: -1, y: 0)
        case .up: CGPoint(x: 0, y: 1)
        case .down: CGPoint(x: 0, y: -1)
        }
        render(focusing: focused, relayout: false, takeFocus: false)
    }

    private func interruptCarousel() {
        guard movingCarousel else { return }
        animator?.cancel()
        movingCarousel = false
        catalog?.cancelPresentations()
        catalog?.endMotion()
        transition += 1
        expectedFocus = nil
        interruptedSizing.formUnion(carouselSizing)
        publish()
    }

    private func renderCarousel(focusing selection: UInt32?, activateDesktop: Bool, takeFocus: Bool, instant: Bool) {
        let bounce = wall, direction = cardDirection
        wall = nil; cardDirection = nil
        let duration = motionPreferences?.reduceMotion == true ? 0 : configuration.animation.duration
        guard let animator, !instant, duration > 0, let previous = carouselPresentation,
              previous.workspace == status.active, let screen = screens.primaryScreen, let closet else {
            renderCarouselInstant(focusing: selection, activateDesktop: activateDesktop, takeFocus: takeFocus)
            return
        }
        let proposed = carousel.frames(status.active, area: area)
        if !animator.active, bounce == nil, previous.frames == proposed, previous.rail == carousel.current(status.active)?.identity,
           previous.pending.isEmpty {
            renderCarouselInstant(focusing: selection, activateDesktop: activateDesktop, takeFocus: takeFocus)
            return
        }
        let displayed = movingCarousel ? catalog?.motionFrames ?? animator.frames : [:]
        let startedAt = animator.now
        let leavingFocus = applications.frontmostPID.flatMap { appFocus[$0] }
        animator.cancel()
        movingCarousel = true
        focusDecision?.cancel()
        transition += 1
        let token = transition
        catalog?.cancelPresentations(invalidatingFocus: takeFocus)
        catalog?.beginMotion()
        if let selection, available(selection) { remember(selection) } else { focused = nil }
        let target = carousel.frames(status.active, area: area)
        let rail = carousel.current(status.active)?.identity, index = carousel.workspaces[status.active]?.current ?? 0
        let vertical = previous.rail != rail && previous.rail != nil && rail != nil
        let down = (direction ?? (index >= previous.railIndex ? 1 : -1)) > 0
        let bounds = CGRect(x: screen.frame.minX, y: 0, width: screen.frame.width, height: screen.frame.height)
        let menuBottom = screen.frame.height - screen.visibleFrame.maxY
        let visible = onScreen().subtracting(closeted)
        let tiles = Set(target.filter { $0.value.intersects(bounds) }.keys)
        var show = tiles.union(entries.keys.filter {
            entries[$0]?.workspace == status.active && available($0) && entries[$0]?.observation.parent == nil && carousel.location($0) == nil
        })
        for id in entries.keys {
            if let parent = entries[id]?.observation.parent, show.contains(parent), available(id) { show.insert(id) }
        }
        let source = Set(previous.frames.keys).intersection(visible).filter { available($0) }
        let participants = tiles.union(source)
        let newlyShown = show.subtracting(visible)
        let preparation = newlyShown.intersection(participants).union(tiles.subtracting(previous.frames.keys))
        let managed = Set(entries.keys.filter { entries[$0]?.workspace != nil && available($0) })
        let hide = managed.subtracting(show)
        var from: [UInt32: CGRect] = [:], to: [UInt32: CGRect] = [:]
        for id in participants.sorted() {
            guard let entry = entries[id] else { continue }
            var a = displayed[id] ?? entry.observation.frame
            var b = target[id] ?? a
            if preparation.contains(id) {
                a = previous.frames[id] ?? b
                a.size = b.size
                if vertical { a.origin.y = down ? bounds.maxY - 32 : area.minY }
            }
            if vertical && !tiles.contains(id) {
                b = a
                if !down { b.origin.y = bounds.maxY - 32 }
            }
            func safe(_ f: CGRect) -> CGRect {
                var f = f
                f.origin.x = max(bounds.minX + 1 - f.width, min(bounds.maxX - 1, f.minX))
                f.origin.y = max(menuBottom, min(bounds.maxY - 32, f.minY))
                return f
            }
            a = safe(a)
            b.origin.y = max(menuBottom, min(bounds.maxY - 32, b.minY))
            from[id] = a; to[id] = b
            if a.size != b.size || preparation.contains(id) { carouselSizing.insert(id) }
        }
        let unchanged = Set(tiles.filter { from[$0] == to[$0] })
        carouselPresentation = CarouselPresentation(workspace: status.active, rail: rail, railIndex: index,
                                                   frames: target, pending: Set(target.keys).intersection(show).subtracting(unchanged))
        expectedFocus = takeFocus ? focused : nil
        let focusID = focused
        let starts = from, ends = to
        let finish: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.transition == token else { return }
            closet.hide(hide.subtracting(self.closeted).filter { self.entries[$0]?.observation.parent == nil })
            self.closeted.formUnion(hide); self.closeted.subtract(show)
            self.carouselSizing.subtract(unchanged)
            self.catalog?.endMotion()
            self.movingCarousel = false
            if takeFocus && (!vertical || !down) && self.expectedFocus == focusID { self.focusCarousel(focusID, token: token) {} }
            self.publish()
            if self.carousel.frames(self.status.active, area: self.area) != target {
                self.render(focusing: self.focused, relayout: false, takeFocus: false)
            }
            self.checkCarouselHide(hide, token: token)
        }
        let begin: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.transition == token else { return }
            var actualStarts = starts, actualEnds = ends
            for id in preparation {
                if let size = self.carouselSizes[id] { actualStarts[id]?.size = size }
                if let frame = self.carousel.frames(self.status.active, area: self.area)[id] {
                    actualEnds[id]?.origin.x = frame.minX
                    actualEnds[id]?.size = self.carouselSizes[id] ?? frame.size
                }
            }
            animator.start(from: actualStarts, to: actualEnds, duration: duration, bounds: bounds, menuBottom: menuBottom, bounce: bounce, startedAt: startedAt,
                apply: { [weak self] writes, final, done in
                    guard let self, self.transition == token else { return }
                    self.writeCarousel(writes, final: final, focusOnLanding: !vertical, token: token) { [weak self] accepted in
                        guard let self, self.transition == token else { return }
                        if final {
                            for id in accepted.keys.sorted() {
                                guard let frame = accepted[id], let requested = target[id], tiles.contains(id) else { continue }
                                self.carouselPresentation?.pending.remove(id)
                                self.carouselSizing.remove(id)
                                self.carouselSizes[id] = frame.size
                                self.carousel.accept(id, requested: requested.size, accepted: frame.size, learnWidth: requested.minX >= bounds.minX && requested.maxX <= bounds.maxX)
                            }
                        }
                        if final { done() }
                    }
                    if !final { done() }
                }, completion: finish)
        }
        let ordered: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.transition == token else { return }
            let movingCard = vertical ? (down ? tiles : Set(source)) : []
            let cardFocus = down ? focusID : leavingFocus
            let neighbors: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, self.transition == token else { return }
                self.raiseCarousel(movingCard, excluding: cardFocus, token: token) { [weak self] in
                    guard let self, self.transition == token else { return }
                    // Raising siblings can change AXMain. Preserve selection
                    // without another raise or application activation.
                    if let cardFocus, movingCard.contains(cardFocus), let entry = self.entries[cardFocus] {
                        self.catalog?.keepMain(pid: entry.pid, id: cardFocus, completion: begin)
                    } else { begin() }
                }
            }
            if vertical && !down, let cardFocus, let entry = self.entries[cardFocus] {
                // A revealed sibling of the active app can return above its
                // current key window. Reassert the leaving card's order first.
                self.catalog?.raise(pid: entry.pid, id: cardFocus, completion: neighbors)
            } else { neighbors() }
        }
        prepareCarousel(Array(preparation).sorted(), starts: starts, token: token) { [weak self] in
            guard let self, self.transition == token else { return }
            // Down activates the incoming focus before raising its background
            // windows. Up retains the leaving activation until it is hidden.
            if takeFocus && vertical && down { self.focusCarousel(focusID, token: token, completion: ordered) }
            else { ordered() }
        }
        if focused == nil && activateDesktop && takeFocus { activateFinderDesktop() }
        publish()
    }

    private func writeCarousel(_ writes: [UInt32: CarouselAnimator.Write], final: Bool, focusOnLanding: Bool, token: UInt64,
                               completion: @escaping @MainActor @Sendable ([UInt32: CGRect]) -> Void) {
        let pids = Set(writes.keys.compactMap { entries[$0]?.pid }).sorted()
        guard !pids.isEmpty, let catalog else { completion([:]); return }
        var remaining = pids.count, result: [UInt32: CGRect] = [:]
        for pid in pids {
            catalog.writeMotion(pid: pid, writes: writes.filter { entries[$0.key]?.pid == pid }, final: final) { [weak self] frames in
                guard let self, self.transition == token else { return }
                if final && focusOnLanding, let focused = self.expectedFocus, frames[focused] != nil {
                    self.focusCarousel(focused, token: token) { [weak self] in self?.publish() }
                }
                result.merge(frames) { _, new in new }
                remaining -= 1
                if remaining == 0 { completion(result) }
            }
        }
    }

    private func prepareCarousel(_ ids: [UInt32], starts: [UInt32: CGRect], token: UInt64, completion: @escaping @MainActor () -> Void) {
        guard let id = ids.first, let entry = entries[id], let start = starts[id], let catalog else { completion(); return }
        // Position writes survive the closet. Stage before showing so no old
        // desktop position flashes; every size write happens after the show.
        catalog.presentRail(pid: entry.pid, id: id, frame: start, position: true, resize: false, focus: false, screenRight: screenRight) { [weak self] _ in
            guard let self, self.transition == token else { return }
            self.closet?.show([id]); self.closeted.remove(id)
            let accepted = self.carouselSizes[id] ?? entry.observation.frame.size
            let resize = abs(accepted.width - start.width) > 1 || abs(accepted.height - start.height) > 1
            let next: @MainActor @Sendable () -> Void = { [weak self] in self?.prepareCarousel(Array(ids.dropFirst()), starts: starts, token: token, completion: completion) }
            guard resize else { next(); return }
            self.sizePreparedCarousel(id, frame: start, token: token, attempts: 2, completion: next)
        }
    }

    private func sizePreparedCarousel(_ id: UInt32, frame: CGRect, token: UInt64, attempts: Int, completion: @escaping @MainActor () -> Void) {
        guard let entry = entries[id] else { completion(); return }
        // Preparation can stage twice before the first display frame. Size a
        // returned sliver inside the area, then restore its animation start;
        // resizing at the right-hand sliver would look like a 1-point maximum.
        var sizing = frame
        sizing.origin = CGPoint(x: max(area.minX, min(frame.minX, area.maxX - frame.width)), y: area.minY)
        catalog?.presentRail(pid: entry.pid, id: id, frame: sizing, position: true, resize: true, focus: false, screenRight: screenRight) { [weak self] accepted in
            guard let self, self.transition == token else { return }
            if let accepted {
                self.carouselSizes[id] = accepted.size
                self.carousel.accept(id, requested: frame.size, accepted: accepted.size)
                if attempts > 1, var next = self.carousel.frames(self.status.active, area: self.area)[id],
                   abs(next.width - accepted.width) > 1 || abs(next.height - accepted.height) > 1 {
                    next.origin = frame.origin
                    self.sizePreparedCarousel(id, frame: next, token: token, attempts: attempts - 1, completion: completion)
                    return
                }
            }
            if let accepted, accepted.origin != frame.origin {
                let start = CGRect(origin: frame.origin, size: accepted.size)
                self.catalog?.presentRail(pid: entry.pid, id: id, frame: start, position: true, resize: false, focus: false, screenRight: self.screenRight) { [weak self] _ in
                    guard let self, self.transition == token else { return }
                    completion()
                }
            } else { completion() }
        }
    }

    private func focusCarousel(_ id: UInt32?, token: UInt64, completion: @escaping @MainActor () -> Void) {
        guard let id, let entry = entries[id], let catalog else { completion(); return }
        catalog.presentRail(pid: entry.pid, id: id, frame: nil, position: false, resize: false, focus: true, screenRight: screenRight) { [weak self] _ in
            guard let self, self.transition == token else { return }
            self.expectedFocus = nil
            completion()
        }
    }

    private func raiseCarousel(_ ids: Set<UInt32>, excluding focus: UInt32?, token: UInt64, completion: @escaping @MainActor () -> Void) {
        guard let id = ids.sorted().first(where: { $0 != focus }), let entry = entries[id], let catalog else { completion(); return }
        catalog.raise(pid: entry.pid, id: id) { [weak self] in
            guard let self, self.transition == token else { return }
            self.raiseCarousel(ids.subtracting([id]), excluding: focus, token: token, completion: completion)
        }
    }

    private func checkCarouselHide(_ hide: Set<UInt32>, token: UInt64) {
        scheduler.main.after(milliseconds: 50) { [weak self] in
            guard let self, self.transition == token, self.status.enabled else { return }
            if !hide.intersection(self.onScreen()).isEmpty { self.disable(reason: "SkyLight could not hide a window") }
            else { self.publish() }
        }
    }

    private func renderCarouselInstant(focusing selection: UInt32?, activateDesktop: Bool, takeFocus: Bool) {
        animator?.cancel()
        movingCarousel = false
        catalog?.endMotion()
        guard status.enabled, let closet else { return }
        focusDecision?.cancel()
        transition += 1
        let token = transition
        expectedFocus = nil
        catalog?.cancelPresentations(invalidatingFocus: takeFocus)
        if let selection, available(selection) { remember(selection) } else { focused = nil }
        let frames = carousel.frames(status.active,area:area)
        let screen = screens.primaryScreen!
        let bounds = CGRect(x:screen.frame.minX,y:0,width:screen.frame.width,height:screen.frame.height)
        var show = Set(frames.filter { $0.value.intersects(bounds) }.keys)
        show.formUnion(entries.keys.filter {
            entries[$0]?.workspace == status.active && available($0) && entries[$0]?.observation.parent == nil && carousel.location($0) == nil
        })
        for id in entries.keys {
            if let parent = entries[id]?.observation.parent, show.contains(parent), available(id) { show.insert(id) }
        }
        let managed = Set(entries.keys.filter { entries[$0]?.workspace != nil && available($0) })
        let hide = managed.subtracting(show)
        let newlyShown = show.intersection(closeted).union(show.subtracting(onScreen()))
        closet.hide(hide.subtracting(closeted).filter { entries[$0]?.observation.parent == nil })
        closet.show(newlyShown.filter { entries[$0]?.observation.parent == nil })
        closeted.formUnion(hide); closeted.subtract(show)
        for id in show.sorted() {
            guard let frame = frames[id] else { continue }
            // Use the same one-point tolerance as width-limit learning. A
            // fractional accepted size must stay stable on focus-only input.
            if let accepted = carouselSizes[id], abs(accepted.width - frame.width) <= 1,
               abs(accepted.height - frame.height) <= 1 { continue }
            if carouselPresentation?.frames[id] == frame, !newlyShown.contains(id),
               frame.minX < bounds.minX || frame.maxX > bounds.maxX { continue }
            carouselSizing.insert(id)
        }
        let rail = carousel.current(status.active)?.identity
        let redraw = carouselPresentation?.workspace != status.active || carouselPresentation?.rail != rail || carouselPresentation?.frames != frames
        var positions = redraw ? Set(frames.keys).intersection(show) : (carouselPresentation?.pending.intersection(show) ?? [])
        positions.formUnion(newlyShown.intersection(frames.keys))
        carouselPresentation = CarouselPresentation(workspace: status.active, rail: rail, railIndex: carousel.workspaces[status.active]?.current ?? 0, frames: frames, pending: positions)
        if let focused, takeFocus { expectedFocus = focused }
        // Focus first, then neighbors in spatial order; each app keeps its own
        // queue and timeout. Scrolls write only positions, never AXSize.
        let ordered = show.sorted {
            if $0 == focused { return true }; if $1 == focused { return false }
            return (frames[$0]?.minX ?? 0,$0) < (frames[$1]?.minX ?? 0,$1)
        }
        for id in ordered where entries[id]?.observation.parent == nil {
            guard let candidate = entries[id] else { continue }
            let resize = carouselSizing.contains(id)
            let position = positions.contains(id) || resize
            let target = position || resize ? frames[id] : nil
            guard target != nil || takeFocus && id == focused else { continue }
            catalog?.presentRail(pid:candidate.pid,id:id,frame:target,position:position,resize:resize,focus:takeFocus && id == focused, screenRight: screenRight) { [weak self] accepted in
                guard let self, self.status.enabled, self.carouselEnabled, self.transition == token else { return }
                if accepted != nil { self.carouselPresentation?.pending.remove(id) }
                if resize, let accepted, let target {
                    self.carouselSizing.remove(id)
                    self.carouselSizes[id] = accepted.size
                    self.carousel.accept(id, requested: target.size, accepted: accepted.size, learnWidth: target.minX >= bounds.minX && target.maxX <= bounds.maxX)
                    if self.carousel.frames(self.status.active, area: self.area) != frames {
                        self.render(focusing: self.focused, relayout: false, takeFocus: false)
                    }
                }
                if self.transition == token && id == focused { self.expectedFocus = nil }
                self.publish()
            }
        }
        if focused == nil && activateDesktop && takeFocus { activateFinderDesktop() }
        scheduler.main.after(milliseconds: 50) { [weak self] in
            guard let self, self.transition == token, self.status.enabled else { return }
            if !hide.intersection(self.onScreen()).isEmpty { self.disable(reason:"SkyLight could not hide a window") }
            else { self.publish() }
        }
    }

}
