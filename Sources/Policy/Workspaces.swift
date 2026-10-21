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
        var manual: WindowState? = nil
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
    private var interruptedSizing = Set<UInt32>()
    private let stage: (any MotionStagePort)?
    /// One animated carousel change on the stage, retargeted by later
    /// commands until it clears.
    private struct Staging {
        let generation: UInt64
        /// Where each stand-in is heading, unclamped, and where a window first
        /// seen by this motion started.
        var rects: [UInt32: CGRect]
        var starts: [UInt32: CGRect] = [:]
        /// Requests belong to the stage session. A retarget only captures
        /// newly seen windows, including while earlier requests are pending.
        var requestedCaptures = Set<UInt32>()
        var rail: UInt64?
        var railIndex: Int
        var shown = false
        var settled = false
        var linger: (any ScheduledWork)?
        /// Counts retargets, so a superseded move's callbacks do nothing.
        var revision = 0
        /// Each placement Accessibility accepted, for WindowServer to show
        /// before the stage clears.
        var placed: [UInt32: CGRect] = [:]
        var revealing = false
        /// Placement waits for the stage to cover the real windows again.
        var covering = false
        init(generation: UInt64, rects: [UInt32: CGRect], rail: UInt64?, railIndex: Int) {
            self.generation = generation; self.rects = rects; self.starts = rects; self.rail = rail; self.railIndex = railIndex
        }
    }
    private var staging: Staging?
    private var stageGeneration: UInt64 = 0
    private var requestedCapture = false
    private var quitting = false
    private var quitDeadline: (any ScheduledWork)?
    /// The longest frozen captures stay after settling, and the bounce's legs.
    private static let lingerLimit = 300, bounceSeconds = 0.07
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
    private var carouselEnabled: Bool { configuration.carouselEnabled }
    private var layerEnabled: Bool { configuration.layerEnabled }
    private var layers: [Int: FloatingLayer] = [:]
    private var layerPlacements: [UInt32: CGRect] = [:]
    private var desktopFocusObservation: (any ApplicationObservation)?
    private struct LayerHandoff {
        let token: UInt64
        var selection: UInt32
        let underStage: Bool
        var awaitingObservation = false
    }
    private var layerHandoff: LayerHandoff?
    private var layerRaiseTransition: UInt64?
    private var layer: FloatingLayer {
        get { layers[status.active] ?? FloatingLayer() }
        set { layers[status.active] = newValue }
    }
    private var focused: UInt32?
    private var clock: UInt64 = 0
    private var closet: WindowCloset?
    private var unavailable: String?
    private var hotkeys: (any HotkeyRegistration)?
    private var closeted = Set<UInt32>()
    private var expectedFocus: UInt32?
    private var focusDecision: (any ScheduledWork)?
    /// The external selection a pending focus decision would follow.
    private var externalSelection: (pid: Int32, id: UInt32)?
    private var transition: UInt64 = 0
    /// Advances with every decision about what to show, but not with the
    /// placement that carries out a staged motion: a native selection reported
    /// during the motion is still followed.
    private var decisions: UInt64 = 0
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
         stage: (any MotionStagePort)? = nil, pointerActivity: (any PointerActivityPort)? = nil,
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
        self.stage = stage
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
        guard !quitting else { return }
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
        let layoutChanged = old.carouselEnabled != next.carouselEnabled
        let layerChanged = old.layerEnabled != next.layerEnabled
        if layerChanged { clearStage(); layers.removeAll() }
        if status.enabled && layoutChanged {
            clearStage()
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
            render(focusing: layerEnabled && layerChanged ? carousel.remembered(status.active) : focused, relayout: true, takeFocus: false)
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
            if let front = enablingFront, let current = appFocus[front], available(current), !layerEnabled || !floating(current) {
                rememberInitialFocus(current)
                nativeFocus = current
            }
            installKeys()
            if layerEnabled, focused.map(floating) == true { focused = carousel.remembered(1) }
            if !entries.isEmpty { render(focusing: focused ?? preferred(in: 1), relayout: true, takeFocus: nativeFocus == nil) }
        } else {
            if old.keys != next.keys || layerChanged { installKeys() }
            if layerChanged && !layoutChanged {
                let selection = layerEnabled ? carousel.remembered(status.active) : focused
                render(focusing: selection, relayout: false, instant: true)
            }
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
            guard let command = WorkspaceCommand(binding.value) else { return true }
            switch command {
            case .toggleLayer, .pinLayer, .toggleFloat: return layerEnabled
            case .focus, .move, .cycleWidth: return carouselEnabled
            default: return true
            }
        }
        do { hotkeys = try hotkeyInstaller.install(keys: keys) { [weak self] in self?.perform($0) } }
        catch { disable(reason: "Could not register workspace hotkeys") }
    }

    /// Clears motion immediately, then calls `ready` once when captures
    /// settle or after 500 ms, immediately if none are pending. Call before
    /// starting application termination; repeated requests are ignored.
    func prepareToQuit(_ ready: @escaping @MainActor @Sendable () -> Void) {
        guard !quitting else { return }
        quitting = true
        clearStage()
        transition += 1
        decisions += 1
        cancelFocusDecision()
        catalog?.cancelPresentations()
        hotkeys?.stop()
        hotkeys = nil
        guard let stage, stage.capturesPending else { ready(); return }
        let finish: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.quitDeadline != nil else { return }
            self.quitDeadline?.cancel()
            self.quitDeadline = nil
            self.stage?.onCapturesSettled = nil
            ready()
        }
        // Captures normally take 15–100 ms; even a cold stage starts within
        // about 230 ms. Allow margin without letting a stuck service hold quit.
        quitDeadline = scheduler.main.after(milliseconds: 500, finish)
        stage.onCapturesSettled = finish
    }

    func disable(reason: String) {
        clearStage()
        transition += 1
        decisions += 1
        cancelFocusDecision()
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
        layers.removeAll()
        desktopFocusObservation = nil
        layerHandoff = nil
        layerPlacements.removeAll()
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
        var newFloats: [UInt32] = []
        var enteredFullscreen = false
        var resizedRail = false
        // A pointer interruption gives geometry back to the user. Drop sizing
        // suppression before consuming its first observed width; afterward the
        // old observation has already been replaced and that delta is lost.
        let interruptedHere = interruptedSizing.intersection(incoming)
        carouselSizing.subtract(interruptedHere)
        interruptedSizing.subtract(interruptedHere)
        for var observation in observations.sorted(by: { $0.record.id < $1.record.id }) {
            let id = observation.record.id
            let old = entries[id]
            if let manual = old?.manual, availableState(observation.record.state) {
                observation.record.state = manual
                observation.record.reason = manual == .floats ? "moved to the layer" : "moved to a rail"
            }
            entries[id] = Entry(observation: observation, pid: pid, workspace: old?.workspace, recent: old?.recent ?? 0, manual: old?.manual)
            if observation.record.state == .fullscreen || observation.record.state == .ignored || !primary(observation) {
                if old?.workspace != nil {
                    // Release our hiding before giving up ownership. An
                    // ignored window will never participate in cleanup again.
                    if observation.record.state == .ignored, closeted.contains(id) { closet?.show([id]) }
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
                if layerEnabled && floating(id) { newFloats.append(id) }
            }
        }
        guard status.enabled else { publish(); return }
        if lostCurrent || previousFocus.map({ !available($0) }) == true {
            cancelFocusDecision()
            expectedFocus = nil
            // A coalesced destruction snapshot can also remove the neighbor
            // captured while the focused window was detached.
            if layerEnabled {
                if case .single(let id) = layer.entry, !floating(id) { layer.entry = .rails }
                if floatingOrder(in: status.active).isEmpty { layer = FloatingLayer() }
                focused = preferred(in: status.active)
            } else {
                focused = closeSelection.flatMap { available($0) ? $0 : nil }
                    ?? (lostCurrent && carouselEnabled ? carousel.remembered(status.active) : nil)
                    ?? mostRecent(in: status.active)
            }
            needsRender = true
        }
        // Entering a native fullscreen Space is the user's operation. Keep the
        // remaining stack in its closet instead of bringing a sibling into it.
        let front = applications.frontmostPID ?? (frontmost ? pid : nil)
        let frontFocus = front.flatMap { appFocus[$0] }
        let nativeFullscreenOwnsFront = frontFocus.map { entries[$0]?.observation.record.state == .fullscreen }
            ?? entries.contains { $0.value.pid == front && $0.value.observation.record.state == .fullscreen && onScreen.contains($0.key) }
        if enteredFullscreen || nativeFullscreenOwnsFront && (pid == front || firstSnapshot || newWindows.isEmpty && restored.isEmpty) {
            if staging != nil { interruptCarousel() }
            cancelFocusDecision()
            expectedFocus = nil
            publish()
            return
        }
        let restoredRoots = restored.filter { entries[$0]?.observation.parent == nil }
        let restoredFocus = reportedFocus.flatMap { restoredRoots.contains($0) ? $0 : nil }
            ?? restoredRoots.max { (entries[$0]?.recent ?? 0) < (entries[$1]?.recent ?? 0) }
        let initialEnumeration = firstSnapshot && (!carouselEnabled || initialApplications.contains(pid))
        if layerEnabled && !initialEnumeration { newFloats += newWindows.filter { floating($0) } }
        if let newFloat = newFloats.last, entries[newFloat]?.workspace == status.active {
            layer.arrive(newFloat)
            remember(newFloat)
            render(focusing: newFloat, relayout: false, instant: true)
        } else if let restored = restoredFocus {
            if let workspace = entries[restored]?.workspace { status.active = workspace }
            if layerEnabled && floating(restored) { layer.entry = .all }
            remember(restored)
            render(focusing: restored, relayout: false, layoutWindows: Set(restoredRoots))
        } else if let newest = newWindows.last(where: { available($0) && entries[$0]?.observation.parent == nil }) {
            // Initial enumeration preserves the app's actual focused window. Later
            // creations join the end of arrival order and become visible immediately.
            let selection = initialEnumeration && frontmost ? reportedFocus.flatMap { available($0) ? $0 : nil } ?? newest : newest
            if initialEnumeration && !frontmost && pid != enablingFront, let current = focused, available(current) {
                // Discovery redraws cancel pending writes, but must finish a
                // keyboard selection already requested before this snapshot.
                render(focusing: current, relayout: false, takeFocus: expectedFocus == current, layoutWindows: Set(newWindows))
            } else if initialEnumeration && !frontmost && pid != enablingFront && focused == nil {
                render(focusing: nil, relayout: false, activateDesktop: false, layoutWindows: Set(newWindows))
            } else {
                if initialEnumeration && frontmost {
                    if layerEnabled && floating(selection) { layer.entry = .all }
                    rememberInitialFocus(selection)
                }
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
                cancelFocusDecision()
                let token = decisions
                let item = scheduler.main.after(milliseconds: 50) { [weak self] in
                    guard let self, self.decisions == token else { return }
                    self.externalSelection = nil
                    self.followExternalSelection(pid: pid, id: reportedFocus)
                }
                focusDecision = item
                externalSelection = (pid, reportedFocus)
            }
        }
        finishLayerHandoff(observedFocus: reportedFocus, pid: pid)
        publish()
    }

    private func finishLayerHandoff(observedFocus: UInt32?, pid: Int32) {
        guard let handoff = layerHandoff, handoff.awaitingObservation,
              handoff.token == transition, status.enabled, layerEnabled,
              available(handoff.selection), entries[handoff.selection]?.workspace == status.active,
              entries[handoff.selection]?.pid == pid, applications.frontmostPID == pid,
              observedFocus == handoff.selection else { return }
        layerHandoff = nil
        renderCarouselInstant(focusing: handoff.selection, activateDesktop: false, takeFocus: false,
                              underStage: handoff.underStage, handoffCompleted: true)
    }

    private var decisionPending: Bool { focusDecision != nil && externalSelection != nil }

    private func cancelFocusDecision() {
        focusDecision?.cancel()
        focusDecision = nil
        externalSelection = nil
    }

    private func followExternalSelection(pid: Int32, id: UInt32) {
        guard available(id), appFocus[pid] == id, applications.frontmostPID == pid else { return }
        followExternalFocus(id)
    }

    func remove(pid: Int32) {
        let removed = entries.filter { $0.value.pid == pid }
        let affectsVisible = removed.contains { $0.value.workspace == status.active && !closeted.contains($0.key) }
        let lostRailFocus = carouselEnabled && focused.map { removed[$0] != nil && carousel.location($0) != nil } == true
        for id in removed.keys { forget(id) }
        if layerEnabled {
            for workspace in Set(removed.values.compactMap(\.workspace)).sorted() { reconcileLayer(in: workspace) }
        }
        knownApplications.remove(pid)
        appFocus.removeValue(forKey: pid)
        store.update(pid: pid, windows: nil)
        if status.enabled && affectsVisible {
            // App termination closes its tiles just like a destruction snapshot;
            // a floating MRU must not override the surviving rail's selection.
            let selection = lostRailFocus && !layerEnabled ? carousel.remembered(status.active) ?? mostRecent(in: status.active) : preferred(in: status.active)
            render(focusing: selection, relayout: false)
        }
        publish()
    }

    private func perform(_ command: WorkspaceCommand) {
        guard status.enabled, !quitting else { return }
        // A command right after the user selected another window acts on it.
        if let selection = externalSelection, decisionPending {
            cancelFocusDecision()
            followExternalSelection(pid: selection.pid, id: selection.id)
        }
        cancelFocusDecision()
        switch command {
        case .toggleLayer:
            guard layerEnabled else { return }
            if layer.focused {
                layer.entry = .rails
                render(focusing: carousel.remembered(status.active), relayout: false, instant: true)
            } else if let next = preferredFloat(in: status.active) {
                layer.entry = .all
                render(focusing: next, relayout: false, instant: true)
            }
        case .pinLayer:
            guard layerEnabled else { return }
            layer.togglePin()
            render(focusing: focused, relayout: false, takeFocus: false, instant: true)
        case .toggleFloat:
            guard layerEnabled else { return }
            toggleFloat()
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
            if layerEnabled && floating(focused) {
                reconcileLayer(in: workspace)
                layers[number, default: FloatingLayer()].entry = .all
            }
            status.active = number
            remember(focused)
            render(focusing: focused, relayout: false, layoutWindows: [focused], instant: true)
        case .focus(let direction):
            guard carouselEnabled else { return }
            if layerEnabled && layer.focused {
                navigateLayer(direction == .left || direction == .up ? -1 : 1); break
            }
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
            if layerEnabled && layer.focused {
                navigateLayer({ if case .next = command { 1 } else { -1 } }()); break
            }
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
        if layerEnabled { layer.entry = floating(id) ? .all : .rails }
        remember(id)
        // The native operation already selected this window. A queued raise
        // can otherwise interrupt a minimize that begins after this snapshot.
        render(focusing: id, relayout: false, takeFocus: false, layoutWindows: layoutWindows)
        publish()
    }

    private func render(focusing selection: UInt32?, relayout: Bool, activateDesktop: Bool = true, takeFocus: Bool = true,
                        layoutWindows: Set<UInt32> = [], instant: Bool = false) {
        guard status.enabled, !quitting, let closet else { return }
        if layerEnabled, let selection, carousel.location(selection) != nil { layer.entry = .rails }
        if carouselEnabled { renderCarousel(focusing: selection, activateDesktop: activateDesktop, takeFocus: takeFocus, instant: instant); return }
        cancelFocusDecision()
        transition += 1
        decisions += 1
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
        if let workspace = entry.workspace, layers[workspace]?.entry == .single(previous) { layers[workspace]?.entry = .single(id) }
        if let frame = layerPlacements.removeValue(forKey: previous) { layerPlacements[id] = frame }
        carousel.replace(previous,with:id)
        if let frame = carouselPresentation?.frames.removeValue(forKey: previous) { carouselPresentation?.frames[id] = frame }
        if carouselPresentation?.pending.remove(previous) != nil { carouselPresentation?.pending.insert(id) }
        if carouselSizing.remove(previous) != nil { carouselSizing.insert(id) }
        if let size = carouselSizes.removeValue(forKey: previous) { carouselSizes[id] = size }
        if focused == previous { focused = id }
        if expectedFocus == previous { expectedFocus = id }
        if layerHandoff?.selection == previous { layerHandoff?.selection = id }
        // Hide intent follows membership and focus history. A new CG window
        // still needs its own move; do not inherit the old ID's completed move.
        closeted.remove(previous)
    }

    private func assign(_ id: UInt32, to workspace: Int) {
        guard let entry = entries[id], ![.fullscreen, .ignored].contains(entry.observation.record.state), primary(entry.observation) else { return }
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
        layerPlacements[id] = nil
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
        if layerEnabled {
            if layers[workspace]?.focused == true { return preferredFloat(in: workspace) ?? carousel.remembered(workspace) }
            return carousel.remembered(workspace).flatMap { available($0) ? $0 : nil }
        }
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
        status.layer = status.enabled && layerEnabled ? layer.status : nil
        status.animationDuration = motionDuration
        status.motion = configuration.animation.duration == 0 ? "off: duration 0"
            : motionPreferences?.reduceMotion == true ? "off: Reduce Motion"
            : stage?.available != true ? "off: Screen Recording permission needed" : "on"
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
                if entries[id]?.manual == .tiled { row.reason = "moved to a rail" }
                else if let size = carousel.size(id), size.height < area.height-2 { row.reason = "maximum height; aligned to top" }
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
        return e.observation.record.state == .tiled || !layerEnabled && e.observation.record.reason == "cannot fill the screen"
    }

    private func floating(_ id: UInt32) -> Bool {
        guard let entry = entries[id], entry.workspace != nil, entry.observation.parent == nil else { return false }
        return entry.observation.record.state == .floats && carousel.location(id) == nil
    }

    private func floatingOrder(in workspace: Int) -> [UInt32] {
        (arrival[workspace] ?? []).filter { floating($0) }
    }

    private func preferredFloat(in workspace: Int) -> UInt32? {
        floatingOrder(in: workspace).reduce(nil) { best, id in
            guard let best else { return id }
            return (entries[id]?.recent ?? 0) > (entries[best]?.recent ?? 0) ? id : best
        }
    }

    /// Oldest use first, newest use last. For untouched floats the first
    /// arrival wins, as it does when entering the layer for the first time.
    private var layerRaiseOrder: [UInt32] {
        floatingOrder(in: status.active).enumerated().sorted {
            let a = entries[$0.element]?.recent ?? 0, b = entries[$1.element]?.recent ?? 0
            return a == b ? $0.offset > $1.offset : a < b
        }.map(\.element)
    }

    private var layerNeedsRaises: Bool { layerEnabled && (layer.pinned || layer.entry == .all) }

    private func restackLayer(token: UInt64) {
        guard transition == token else { return }
        guard layerNeedsRaises else { layerRaiseTransition = nil; return }
        layerRaiseTransition = token
        let visible = onScreen(), front = applications.frontmostPID
        let ids = layerRaiseOrder.filter { visible.contains($0) && !closeted.contains($0) && available($0) && entries[$0]?.pid != front }
        raiseLayerFloats(ids[...], token: token)
    }

    /// Serial across app workers as well as within one app: concurrent AXRaise
    /// replies cannot preserve a cross-app MRU order. A new render cancels it.
    private func raiseLayerFloats(_ ids: ArraySlice<UInt32>, token: UInt64) {
        guard transition == token, status.enabled, !quitting, layerNeedsRaises else { return }
        guard let id = ids.first else {
            layerRaiseTransition = nil
            orderStage()
            finishStage()
            return
        }
        guard let entry = entries[id], available(id), !closeted.contains(id), entry.pid != applications.frontmostPID,
              let catalog else { raiseLayerFloats(ids.dropFirst(), token: token); return }
        catalog.raiseBackground(pid: entry.pid, id: id) { [weak self] in
            self?.raiseLayerFloats(ids.dropFirst(), token: token)
        }
    }

    /// Visible windows keep their observed relative order, including native
    /// panels and failed raises. Only an unseen destination tile needs a
    /// provisional slot until placement: before the currently visible tiles,
    /// preserving floats already above those tiles. Reveal reads CG again.
    private func orderStage() {
        guard layerEnabled, layer.pinned, let staging, let stage else { return }
        let ids = Set(staging.rects.keys)
        var order = windowOrder.onScreenOrder()
        if let focused, ids.contains(focused), !order.contains(focused), carousel.location(focused) != nil {
            let index = order.firstIndex { carousel.location($0) != nil } ?? order.endIndex
            order.insert(focused, at: index)
        }
        order.append(contentsOf: ids.subtracting(order).sorted())
        stage.order(order.filter { ids.contains($0) })
    }

    private func reconcileLayer(in workspace: Int) {
        if floatingOrder(in: workspace).isEmpty { layers[workspace] = FloatingLayer() }
        else if case .single(let id) = layers[workspace]?.entry,
                entries[id]?.workspace != workspace || !floating(id) { layers[workspace]?.entry = .rails }
    }

    private func navigateLayer(_ step: Int) {
        let order = floatingOrder(in: status.active)
        guard !order.isEmpty else { return }
        let index = focused.flatMap { order.firstIndex(of: $0) } ?? 0
        layer.entry = .all
        render(focusing: order[(index + step + order.count) % order.count], relayout: false, instant: true)
    }

    private func toggleFloat() {
        guard let id = focused, let entry = entries[id], entry.workspace == status.active,
              available(id), entry.observation.parent == nil else { return }
        if carousel.location(id) != nil {
            carousel.remove(id)
            carouselSizing.remove(id)
            carouselSizes[id] = nil
            entries[id]?.manual = .floats
            entries[id]?.observation.record.state = .floats
            entries[id]?.observation.record.reason = "moved to the layer"
            arrival[status.active]?.removeAll { $0 == id }
            arrival[status.active, default: []].append(id)
            layerPlacements[id] = CGRect(x: area.midX - area.width / 4, y: area.midY - area.height / 3,
                                         width: area.width / 2, height: area.height * 2 / 3)
            layer.entry = .all
        } else if floating(id) {
            guard entry.observation.resizable else {
                if motionDuration > 0, let screen = screens.primaryScreen {
                    bounceStage(CGPoint(x: 1, y: 0), frames: [id: entry.observation.frame], bounds: screen.frame, duration: motionDuration)
                }
                return
            }
            layerPlacements[id] = nil
            entries[id]?.manual = .tiled
            entries[id]?.observation.record.state = .tiled
            entries[id]?.observation.record.reason = "moved to a rail"
            let width = entry.observation.frame.width
            let preset = Carousel.presets.min {
                let a = abs(carousel.presetWidth($0) - width), b = abs(carousel.presetWidth($1) - width)
                return abs(a - b) < 1e-6 ? $0 > $1 : a < b
            }
            carousel.insert(Carousel.Tile(id: id, size: CGSize(width: width, height: area.height), preset: preset), workspace: status.active)
            carouselSizes[id] = entry.observation.frame.size
            layer.entry = .rails
        } else { return }
        render(focusing: id, relayout: false, instant: true)
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
        guard staging != nil else { return }
        clearStage()
        catalog?.cancelPresentations()
        transition += 1
        decisions += 1
        expectedFocus = nil
        interruptedSizing.formUnion(carouselSizing)
        // The stage can be interrupted after its early tile-focus placement,
        // before placeUnderStage would restore the visible floats' order.
        restackLayer(token: transition)
        publish()
    }

    /// The motion's effective duration: zero with Reduce Motion, or when the
    /// stage cannot capture windows.
    private var motionDuration: Int {
        guard motionPreferences?.reduceMotion != true, stage?.available == true else { return 0 }
        return configuration.animation.duration
    }

    private var pinnedFrames: [UInt32: CGRect] {
        guard layerEnabled, layer.pinned else { return [:] }
        return Dictionary(uniqueKeysWithValues: floatingOrder(in: status.active).compactMap { id in
            guard !closeted.contains(id), let entry = entries[id] else { return nil }
            return (id, entry.observation.frame)
        })
    }

    /// Animated carousel changes run on the stage: captures of the windows that
    /// are seen move in tessel's overlay while the ordinary presenter places the
    /// real windows underneath, once each. The stage clears when the motion has
    /// settled and the real windows are in place.
    private func renderCarousel(focusing selection: UInt32?, activateDesktop: Bool, takeFocus: Bool, instant: Bool) {
        let bounce = wall, direction = cardDirection
        wall = nil; cardDirection = nil
        let duration = motionDuration
        // Motion needs Screen Recording; ask once, the first time it would run.
        if let stage, !instant, duration == 0, configuration.animation.duration > 0, motionPreferences?.reduceMotion != true,
           !stage.available, !requestedCapture {
            requestedCapture = true
            stage.requestAccess()
        }
        guard let stage, !instant, duration > 0, let previous = carouselPresentation,
              previous.workspace == status.active, let screen = screens.primaryScreen else {
            renderCarouselInstant(focusing: selection, activateDesktop: activateDesktop, takeFocus: takeFocus)
            return
        }
        let bounds = CGRect(x: screen.frame.minX, y: 0, width: screen.frame.width, height: screen.frame.height)
        if let bounce {
            if staging == nil { bounceStage(bounce, frames: previous.frames, bounds: bounds, duration: duration) }
            return
        }
        let tiles = carousel.frames(status.active, area: area)
        let pinned = pinnedFrames
        let target = tiles.merging(pinned) { _, float in float }
        let rail = carousel.current(status.active)?.identity, index = carousel.workspaces[status.active]?.current ?? 0
        if staging == nil, previous.frames == tiles, previous.rail == rail, previous.pending.isEmpty {
            renderCarouselInstant(focusing: selection, activateDesktop: activateDesktop, takeFocus: takeFocus)
            return
        }
        let leavingFocus = applications.frontmostPID.flatMap { appFocus[$0] }
        cancelFocusDecision()
        decisions += 1
        if let selection, available(selection) { remember(selection) } else { focused = nil }
        let first = staging == nil
        if first {
            stageGeneration += 1
            // A stand-in starts exactly where its window is, which can differ
            // from the layout after the user moved it. Parked and closeted
            // windows start at their unclamped strip position.
            var rects = previous.frames.merging(pinned) { _, float in float }
            for (id, rect) in previous.frames where !closeted.contains(id) {
                if let observed = entries[id]?.observation.frame, observed != rect, observed.intersection(bounds).width > 1 { rects[id] = observed }
            }
            staging = Staging(generation: stageGeneration, rects: rects, rail: previous.rail, railIndex: previous.railIndex)
        }
        guard var stagingNow = staging else { return }
        let generation = stagingNow.generation
        // A rail change slides both rails as one sheet: the entering rail
        // comes from below (down) or above (up), and the leaving one goes the
        // other way.
        let vertical = stagingNow.rail != rail && stagingNow.rail != nil && rail != nil
        let down = (direction ?? (index >= stagingNow.railIndex ? 1 : -1)) > 0
        let shift = vertical ? (area.height + configuration.gaps.outer) * (down ? 1 : -1) : 0
        var to = target, entering: [UInt32: CGRect] = [:]
        // A window that left the rail goes with the leaving sheet; a closed
        // one loses its stand-in.
        for (id, rect) in stagingNow.rects where target[id] == nil && available(id) && !floating(id) { to[id] = rect.offsetBy(dx: 0, dy: -shift) }
        // A window new to the rail starts where it opened.
        for (id, rect) in target where stagingNow.rects[id] == nil {
            let opened = entries[id].map(\.observation.frame).flatMap { Self.onScreen($0, bounds) ? $0 : nil }
            entering[id] = pinned[id] ?? (vertical ? rect.offsetBy(dx: 0, dy: shift) : previous.frames[id] ?? opened ?? rect)
        }
        let starts = stagingNow.rects.merging(entering) { current, _ in current }
        stagingNow.starts.merge(entering) { current, _ in current }
        let seen = Set(to.keys.filter { id in [starts[id], to[id]].contains { $0.map { Self.onScreen($0, bounds) } == true } && available(id) })
        let toCapture = seen.subtracting(stagingNow.requestedCaptures)
        stagingNow.requestedCaptures.formUnion(toCapture)
        stagingNow.rects = to; stagingNow.rail = rail; stagingNow.railIndex = index
        // A retarget may stop the stage fading into the real windows; they
        // move again only once it covers them.
        let interruptedReveal = !first && stagingNow.revealing
        // The previous move's settle and linger no longer apply.
        stagingNow.settled = false; stagingNow.revealing = false; stagingNow.revision += 1
        stagingNow.linger?.cancel(); stagingNow.linger = nil
        staging = stagingNow
        // Every seen window is captured at once, and focus is requested. The
        // focus look changes when the real window replaces its stand-in.
        let focusChanges = takeFocus && focused != nil && focused != leavingFocus
        if first || !toCapture.isEmpty {
            stage.capture(toCapture, background: first ? Set(starts.keys).union(to.keys) : nil)
        }
        orderStage()
        expectedFocus = takeFocus ? focused : nil
        let shown = starts.filter { seen.contains($0.key) }
        if first {
            stage.show(shown) { [weak self] ok in
                guard let self, self.staging?.generation == generation else { return }
                guard ok else {
                    // Without its captures the stage cannot hide the change.
                    self.clearStage()
                    self.renderCarouselInstant(focusing: self.focused, activateDesktop: false, takeFocus: self.pendingFocus, keepFocus: true)
                    return
                }
                self.staging?.shown = true
                self.advanceStage()
            }
        }
        if focusChanges { focusCarousel(focused, token: transition) }
        if focused == nil && activateDesktop && takeFocus { activateFinderDesktop() }
        if !first, stagingNow.shown { advanceStage(covering: interruptedReveal) }
        publish()
    }

    /// A focus request the app has not confirmed yet. Placement supersedes
    /// queued presentations, so it carries that request forward.
    private var pendingFocus: Bool { expectedFocus != nil && expectedFocus == focused }

    /// Moves the shown stand-ins to the current layout and places the real
    /// windows underneath.
    private func advanceStage(covering: Bool = false) {
        guard let stage, let staging, staging.shown else { return }
        let generation = staging.generation, revision = staging.revision
        // A capture that arrives late joins from where its window started.
        stage.move(staging.rects, entering: staging.starts, duration: Double(motionDuration) / 1_000) { [weak self] in
            guard let self, self.staging?.generation == generation, self.staging?.revision == revision else { return }
            self.staging?.settled = true
            // A slow app must not keep frozen captures on screen.
            self.staging?.linger = self.scheduler.main.after(milliseconds: Self.lingerLimit) { [weak self] in
                guard let self, self.staging?.generation == generation, self.staging?.revision == revision else { return }
                self.clearStage()
                self.publish()
            }
            self.finishStage()
        }
        guard covering || staging.covering else { placeUnderStage(); return }
        // The cover places whatever layout is current by then.
        guard !staging.covering else { return }
        self.staging?.covering = true
        stage.cover { [weak self] in
            guard let self, self.staging?.generation == generation else { return }
            self.staging?.covering = false
            self.placeUnderStage()
        }
    }

    private func placeUnderStage() {
        renderCarouselInstant(focusing: focused, activateDesktop: false, takeFocus: pendingFocus, keepFocus: true, underStage: true)
    }

    /// The real windows replace their stand-ins once the motion has settled,
    /// every placement is confirmed, and WindowServer shows them in place.
    private func finishStage() {
        guard var staging, staging.settled, !staging.revealing, !staging.covering, layerHandoff == nil,
              carouselPresentation?.pending.isEmpty != false, layerRaiseTransition != transition, let stage else { return }
        staging.revealing = true
        self.staging = staging
        let generation = staging.generation, revision = staging.revision
        let placed = staging.placed.filter { !closeted.contains($0.key) }
        let hidden = Set(staging.rects.keys).intersection(closeted)
        stage.reveal(placed, hidden: hidden, willReveal: { [weak self] in
            guard let self, self.staging?.generation == generation, self.staging?.revision == revision else { return }
            self.orderStage()
        }) { [weak self] in
            guard let self, self.staging?.generation == generation, self.staging?.revision == revision else { return }
            self.clearStage()
            self.publish()
        }
    }

    private func clearStage() {
        staging?.linger?.cancel()
        if staging != nil { stage?.clear() }
        staging = nil
    }

    /// At an end of the rail, the stand-ins recoil a little away from the wall
    /// and back; the real windows do not move.
    private func bounceStage(_ wall: CGPoint, frames: [UInt32: CGRect], bounds: CGRect, duration: Int) {
        guard let stage else { return }
        let pinned = pinnedFrames
        let all = frames.merging(pinned) { original, _ in original }
        let seen = all.filter { Self.onScreen($0.value, bounds) && available($0.key) }
        guard !seen.isEmpty else { return }
        stageGeneration += 1
        let generation = stageGeneration
        staging = Staging(generation: generation, rects: all, rail: carouselPresentation?.rail, railIndex: carouselPresentation?.railIndex ?? 0)
        staging?.requestedCaptures = Set(seen.keys)
        let offset = Dictionary(uniqueKeysWithValues: seen.map { id, rect in
            (id, frames[id] == nil ? rect : rect.offsetBy(dx: wall.x * area.width * 0.03, dy: wall.y * area.height * 0.03))
        })
        stage.capture(Set(seen.keys), background: Set(all.keys))
        orderStage()
        // A command during the bounce retargets it like any motion.
        func bouncing() -> Bool { staging?.generation == generation && staging?.revision == 0 }
        stage.show(seen) { [weak self] ok in
            guard let self, self.staging?.generation == generation else { return }
            guard ok else {
                let retargeted = !bouncing()
                self.clearStage()
                if retargeted { self.renderCarouselInstant(focusing: self.focused, activateDesktop: false, takeFocus: self.pendingFocus, keepFocus: true) }
                return
            }
            self.staging?.shown = true
            guard bouncing() else { self.advanceStage(); return }
            stage.move(offset, entering: [:], duration: Self.bounceSeconds) { [weak self] in
                guard let self, bouncing() else { return }
                stage.move(seen, entering: [:], duration: Self.bounceSeconds) { [weak self] in
                    guard let self, bouncing() else { return }
                    self.clearStage()
                    self.publish()
                }
            }
        }
    }

    private func focusCarousel(_ id: UInt32?, token: UInt64) {
        guard let id, let entry = entries[id], let catalog else { return }
        catalog.presentRail(pid: entry.pid, id: id, frame: nil, position: false, resize: false, focus: true, screenRight: screenRight) { [weak self] _ in
            guard let self, self.transition == token else { return }
            // A superseded request's confirmation must not release a newer one.
            if self.expectedFocus == id, self.appFocus[entry.pid] == id, self.applications.frontmostPID == entry.pid { self.expectedFocus = nil }
            self.publish()
        }
    }


    /// A frame shows at least a point of its window. Fractional widths leave
    /// a parked tile a rounding error inside the edge; AX would accept that
    /// position and macOS later pull the window back to show 40 points.
    private static func onScreen(_ frame: CGRect, _ bounds: CGRect) -> Bool { frame.intersection(bounds).width >= 1 }

    /// Places every window at once. Under the stage it runs once per motion
    /// change and keeps the focus the stage already requested.
    private func renderCarouselInstant(focusing selection: UInt32?, activateDesktop: Bool, takeFocus: Bool,
                                       keepFocus: Bool = false, underStage: Bool = false, handoffCompleted: Bool = false) {
        if !underStage { clearStage(); decisions += 1; cancelFocusDecision() }
        guard status.enabled, !quitting, let closet else { return }
        transition += 1
        let token = transition
        layerRaiseTransition = layerNeedsRaises ? token : nil
        desktopFocusObservation = nil
        layerHandoff = nil
        if !keepFocus { expectedFocus = nil }
        catalog?.cancelPresentations(invalidatingFocus: takeFocus)
        if let selection, available(selection) { remember(selection) } else { focused = nil }
        let frames = carousel.frames(status.active,area:area)
        let screen = screens.primaryScreen!
        let bounds = CGRect(x:screen.frame.minX,y:0,width:screen.frame.width,height:screen.frame.height)
        var show = Set(frames.filter { Self.onScreen($0.value, bounds) }.keys)
        show.formUnion(entries.keys.filter {
            entries[$0]?.workspace == status.active && available($0) && entries[$0]?.observation.parent == nil && carousel.location($0) == nil
                && (!layerEnabled || layer.shows($0))
        })
        for id in entries.keys {
            if let parent = entries[id]?.observation.parent, show.contains(parent), available(id) { show.insert(id) }
        }
        let managed = Set(entries.keys.filter { entries[$0]?.workspace != nil && available($0) })
        let hide = managed.subtracting(show)
        let newlyShown = show.intersection(closeted).union(show.subtracting(onScreen()))
        closet.show(newlyShown.filter { entries[$0]?.observation.parent == nil })
        closeted.subtract(show)
        // A modal can keep its app waiting in the closet, but it must first
        // relinquish keyboard focus. Show and focus the destination before
        // committing the hide, including a workspace switch from the layer.
        // A native selection can precede its queued catalog notification.
        // Any newly hidden window of the front app may own keyboard focus.
        let newlyHidden = hide.subtracting(closeted)
        if layerEnabled, !handoffCompleted, let front = applications.frontmostPID,
           newlyHidden.contains(where: { entries[$0]?.pid == front }) {
            if let selection, show.contains(selection), let candidate = entries[selection] {
                expectedFocus = selection
                layerHandoff = LayerHandoff(token: token, selection: selection, underStage: underStage)
                let target = newlyShown.contains(selection) ? frames[selection] : nil
                catalog?.presentRail(pid: candidate.pid, id: selection, frame: target, position: target != nil,
                                     resize: target != nil, focus: true, screenRight: screenRight) { [weak self] result in
                    guard let self, self.status.enabled, self.transition == token else { return }
                    // The worker and main queues preserve order: publications
                    // after this completion were read after the focus attempt.
                    // A skipped or failed attempt must not trust cached focus.
                    self.layerHandoff?.awaitingObservation = true
                    if let observation = result.focus, observation.frontmost {
                        let observed = observation.window.map { self.entries[$0]?.observation.parent ?? $0 }
                        self.finishLayerHandoff(observedFocus: observed, pid: candidate.pid)
                    } else if let replacement = self.layerHandoff?.selection, replacement != selection {
                        // The native successor can have published before the
                        // old target rejected presentation. Give it the intent.
                        self.renderCarouselInstant(focusing: replacement, activateDesktop: activateDesktop,
                                                   takeFocus: true, underStage: underStage)
                    }
                    self.publish()
                }
            } else if activateDesktop {
                desktopFocusObservation = applications.observe { [weak self] event, app in
                    guard let self, event == .activated, app.pid != front, self.transition == token else { return }
                    self.desktopFocusObservation = nil
                    self.render(focusing: nil, relayout: false, activateDesktop: false, takeFocus: false, instant: true)
                    self.publish()
                }
                activateFinderDesktop()
            }
            return
        }
        closet.hide(hide.subtracting(closeted).filter { entries[$0]?.observation.parent == nil })
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
            let floatTarget = layerPlacements[id]
            let resize = carouselSizing.contains(id) || floatTarget != nil
            let position = positions.contains(id) || resize
            let target = floatTarget ?? (position || resize ? frames[id] : nil)
            guard target != nil || takeFocus && id == focused else { continue }
            catalog?.presentRail(pid:candidate.pid,id:id,frame:target,position:position,resize:resize,focus:takeFocus && id == focused, screenRight: screenRight) { [weak self] result in
                guard let self, self.status.enabled, self.carouselEnabled, self.transition == token else { return }
                let accepted = result.frame
                if let accepted {
                    self.carouselPresentation?.pending.remove(id)
                    if floatTarget != nil {
                        self.layerPlacements[id] = nil
                    }
                    if underStage { self.staging?.placed[id] = accepted }
                }
                if resize, floatTarget == nil, let accepted, let target {
                    // The stand-in crossfades to the window at its new size.
                    if underStage, self.staging?.shown == true { self.stage?.refresh(id) }
                    self.carouselSizing.remove(id)
                    self.carouselSizes[id] = accepted.size
                    self.carousel.accept(id, requested: target.size, accepted: accepted.size, learnBounds: target.minX >= bounds.minX && target.maxX <= bounds.maxX)
                    if self.carousel.frames(self.status.active, area: self.area) != frames {
                        self.render(focusing: self.focused, relayout: false, takeFocus: false)
                    }
                }
                if self.transition == token && id == focused { self.expectedFocus = nil }
                if self.transition == token && id == focused && takeFocus { self.restackLayer(token: token) }
                if underStage { self.finishStage() }
                self.publish()
            }
        }
        if !takeFocus || focused == nil { restackLayer(token: token) }
        if focused == nil && activateDesktop && takeFocus { activateFinderDesktop() }
        if underStage { finishStage() }
        scheduler.main.after(milliseconds: 50) { [weak self] in
            guard let self, self.transition == token, self.status.enabled else { return }
            if !hide.intersection(self.onScreen()).isEmpty { self.disable(reason:"SkyLight could not hide a window") }
            else { self.publish() }
        }
    }

}
