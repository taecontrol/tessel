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
    private var pointerHeld = false
    private var pointerReconciling = false
    private var pointerFrames: [UInt32: CGRect] = [:]
    private var pointerGeneration: UInt64 = 0
    private var pointerCommands: [WorkspaceCommand] = []
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
        /// A retarget's real windows have not been placed under the stage yet.
        var awaitsPlacement = false
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
    private var placementToken: UInt64?
    private var carouselPresentation: CarouselPresentation?
    private var layers: [Int: FloatingLayer] = [:]
    private var layerPlacements: [UInt32: CGRect] = [:]
    private var pendingFloatTransfer: (window: UInt32, decision: UInt64)?
    private var desktopFocusObservation: (any ApplicationObservation)?
    private struct LayerHandoff {
        let token: UInt64
        var selection: UInt32
        let commit: @MainActor () -> Void
        var awaitingObservation = false
    }
    private var layerHandoff: LayerHandoff?
    /// Restacking follows observed state instead of being carried through
    /// renders: every placement owes a pass, and so does a change of the
    /// native frontmost app. See `restackLayer`.
    private enum LayerRestack: Equatable {
        case owed
        case running(UInt64)
        /// The last pass was computed for this frontmost app.
        case done(front: Int32?)
    }
    private var layerRestack = LayerRestack.done(front: nil)
    private var restackPasses: UInt64 = 0
    /// Apps whose floats the last pass left unraised, because an activation
    /// tessel requested may still be pending there. The app's first
    /// publication with that activation resolved owes another pass.
    private var restackAwaitingActivation = Set<Int32>()
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
        motionObservation = motionPreferences?.observe { [weak self] reduced in
            if reduced { self?.finishMotionImmediately() }
            self?.publish()
        }
        pointerObservation = pointerActivity?.observeButtons { [weak self] held in self?.pointerChanged(held) }
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
        guard trusted else { disable(reason: "Accessibility permission needed"); return }
        guard let closet, unavailable == nil else { disable(reason: unavailable ?? "SkyLight window hiding is unavailable"); return }
        carousel.width = area.width
        carousel.gap = next.gaps.outer
        if !status.enabled {
            do { try closet.start() }
            catch let error as WindowCloset.Unavailable { disable(reason: error.reason); return }
            catch { disable(reason: "SkyLight could not create the hidden Space"); return }
            status.enabled = true
            status.reason = "active"
            status.active = 1
            enablingFront = applications.frontmostPID
            initialApplications = Set(applications.runningApplications.map(\.pid))
            for id in entries.keys.sorted() { assign(id, to: 1); if railTile(id) { addCarouselTile(id, initial: true) } }
            // The front app already shows its focused window. Its last read
            // can predate a newer native selection; raising it would take
            // focus back, so render without a focus request. A fresh report
            // then selects whichever window really has focus.
            var nativeFocus: UInt32?
            if let front = enablingFront, let current = appFocus[front], available(current), !floating(current) {
                rememberInitialFocus(current)
                nativeFocus = current
            }
            installKeys()
            if focused.map(floating) == true { focused = carousel.remembered(1) }
            if !entries.isEmpty { render(focusing: focused ?? preferred(in: 1), relayout: true, takeFocus: nativeFocus == nil) }
        } else {
            if old.keys != next.keys { installKeys() }
            if old.animation.duration != next.animation.duration, next.animation.duration == 0 { finishMotionImmediately() }
            if old.gaps != next.gaps {

                carousel.resizeArea(height: area.height)
                carouselSizing.formUnion(entries.keys.filter { carousel.location($0) != nil })

                render(focusing: focused, relayout: true, takeFocus: false)
            }
        }
        publish()
    }

    private func installKeys() {
        hotkeys?.stop()
        hotkeys = nil
        let keys = configuration.keys
        do { hotkeys = try hotkeyInstaller.install(keys: keys) { [weak self] in self?.perform($0) } }
        catch { disable(reason: "Could not register workspace hotkeys") }
    }

    /// Clears motion immediately, then calls `ready` once when captures
    /// settle or after 500 ms, immediately if none are pending. Call before
    /// starting application termination; repeated requests are ignored.
    func prepareToQuit(_ ready: @escaping @MainActor @Sendable () -> Void) {
        guard !quitting else { return }
        quitting = true
        pendingFloatTransfer = nil
        layerRestack = .done(front: nil)
        clearStage()
        transition += 1
        decisions += 1
        cancelFocusDecision()
        catalog?.cancelPresentations()
        placementToken = nil
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
        pendingFloatTransfer = nil
        layerRestack = .done(front: nil)
        clearStage()
        transition += 1
        decisions += 1
        cancelFocusDecision()
        catalog?.cancelPresentations()
        placementToken = nil
        hotkeys?.stop()
        hotkeys = nil
        // Return only our managed windows. Fullscreen windows are never touched.
        catalog?.returnInside(ids: Set(entries.keys.filter { entries[$0]?.workspace != nil && entries[$0]?.observation.record.state != .fullscreen }), area: area)
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

    func update(pid: Int32, observations: [WindowObservation], focused rawFocus: UInt32?, frontmost: Bool,
                activationPending: Bool = false, change: CatalogChange) {
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
        var needsRender = placementToken != nil && !replacements.isEmpty
        for id in previous.keys where !incoming.contains(id) {
            if previous[id]?.workspace == status.active && !closeted.contains(id) { needsRender = true }
            if id == previousFocus { carousel.remove(id) }
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
                assign(id, to: observation.parent.flatMap { entries[$0]?.workspace } ?? status.active, initial: firstSnapshot && initialApplications.contains(pid))
                newWindows.append(id)
                needsRender = true
            }

            if railTile(id) {
                if carousel.location(id) == nil { addCarouselTile(id, initial: firstSnapshot && initialApplications.contains(pid) && old == nil, restoring: old != nil); needsRender = true }
                else if let old, !pointerHeld, !pointerReconciling, !carouselSizing.contains(id), !closeted.contains(id),
                        abs(old.observation.frame.width - observation.frame.width) > 1 || abs(old.observation.frame.height - observation.frame.height) > 1 {
                    // AX/AppKit can publish a late redraw after a successful
                    // write. Only a pointer release adopts user geometry;
                    // an unsolicited change retains the chosen preset.
                    carouselSizes[id] = observation.frame.size
                    carouselSizing.insert(id)
                    resizedRail = true
                }
            } else { carousel.remove(id, suspending: true) }

            if let old, [.minimized, .hidden, .fullscreen].contains(old.observation.record.state), available(id) {
                restored.append(id)
                needsRender = true
            }
            if let old, availableState(old.observation.record.state) != available(id) { needsRender = true }
            if let old, availableState(old.observation.record.state), available(id), old.observation.record.state != observation.record.state {
                changedTiling = true
                if observation.record.state == .tiled { newlyTiled.insert(id) }
                if floating(id) { newFloats.append(id) }
            }
        }
        guard status.enabled, !pointerHeld, !pointerReconciling else { publish(); return }
        if lostCurrent || previousFocus.map({ !available($0) }) == true {
            cancelFocusDecision()
            expectedFocus = nil
            // A coalesced destruction snapshot can also remove the neighbor
            // captured while the focused window was detached.

            if case .single(let id) = layer.entry, !floating(id) { layer.entry = .rails }
            if floatingOrder(in: status.active).isEmpty { layer = FloatingLayer() }
            if let previousFocus, let state = entries[previousFocus]?.observation.record.state,
               state == .minimized || state == .hidden, !layer.focused {
                focused = entries.keys.filter { entries[$0]?.workspace == status.active && railTile($0) }
                    .max { ((entries[$0]?.recent ?? 0), $0) < ((entries[$1]?.recent ?? 0), $1) }
            } else { focused = preferred(in: status.active) }

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
        let initialEnumeration = firstSnapshot && initialApplications.contains(pid)
        if !initialEnumeration { newFloats += newWindows.filter { floating($0) } }
        if let newFloat = newFloats.last, entries[newFloat]?.workspace == status.active {
            layer.arrive(newFloat)
            remember(newFloat)
            render(focusing: newFloat, relayout: false, instant: true)
        } else if let restored = restoredFocus {
            if let workspace = entries[restored]?.workspace { status.active = workspace }
            if floating(restored) { layer.entry = .all }
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
                    if floating(selection) { layer.entry = .all }
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
        if !activationPending, restackAwaitingActivation.remove(pid) != nil { layerRestack = .owed }
        restackLayer()
        publish()
    }

    private func finishLayerHandoff(observedFocus: UInt32?, pid: Int32) {
        guard let handoff = layerHandoff, handoff.awaitingObservation,
              handoff.token == transition, status.enabled,
              available(handoff.selection), entries[handoff.selection]?.workspace == status.active,
              entries[handoff.selection]?.pid == pid, applications.frontmostPID == pid,
              observedFocus == handoff.selection else { return }
        layerHandoff = nil
        handoff.commit()
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
        for id in removed.keys { forget(id) }

        for workspace in Set(removed.values.compactMap(\.workspace)).sorted() { reconcileLayer(in: workspace) }

        knownApplications.remove(pid)
        appFocus.removeValue(forKey: pid)
        store.update(pid: pid, windows: nil)
        if status.enabled && affectsVisible {
            // App termination closes its tiles just like a destruction snapshot;
            // a floating MRU must not override the surviving rail's selection.
            let selection = preferred(in: status.active)
            render(focusing: selection, relayout: false)
        }
        publish()
    }

    private func perform(_ command: WorkspaceCommand) {
        guard status.enabled, !quitting, !pointerHeld else { return }
        if pointerReconciling { pointerCommands.append(command); return }
        // A command right after the user selected another window acts on it.
        if let selection = externalSelection, decisionPending {
            cancelFocusDecision()
            followExternalSelection(pid: selection.pid, id: selection.id)
        }
        cancelFocusDecision()
        switch command {
        case .toggleLayer:
            if layer.focused {
                layer.entry = .rails
                render(focusing: carousel.remembered(status.active), relayout: false, instant: true)
            } else if let next = preferredFloat(in: status.active) {
                layer.entry = .all
                render(focusing: next, relayout: false, instant: true)
            }
        case .pinLayer:
            layer.togglePin()
            render(focusing: focused, relayout: false, takeFocus: false, instant: true)
        case .toggleFloat:
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
            if railTile(focused) {
                if let tile { carousel.insert(tile, workspace: number) }
                else { addCarouselTile(focused) }
            }
            if floating(focused) {
                reconcileLayer(in: workspace)
                layers[number, default: FloatingLayer()].entry = .all
            }
            status.active = number
            remember(focused)
            render(focusing: focused, relayout: false, layoutWindows: [focused], instant: true)
        case .focus(let direction):
            if layer.focused {
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
            guard let focused, carousel.location(focused) != nil else { return }
            carousel.cycleWidth(focused)
            render(focusing: focused, relayout: false)
        case .move(let direction):
            guard let focused, carousel.location(focused) != nil else { return }
            let moved = direction == .left || direction == .right
                ? carousel.moveX(focused,direction:direction == .left ? -1 : 1)
                : carousel.moveY(focused,direction:direction == .up ? -1 : 1)
            guard moved else { bounce(direction); return }
            if direction == .up || direction == .down { cardDirection = direction == .up ? -1 : 1 }
            // A successful reorder restores logical geometry after a mouse move,
            // even if the resulting target frames match the previous layout.
            render(focusing:focused,relayout:false)
        case .next, .previous:
            if layer.focused {
                navigateLayer({ if case .next = command { 1 } else { -1 } }()); break
            }
            if let focused, carousel.location(focused) != nil {
                guard let next = carousel.focusX(status.active,direction: { if case .next = command { return 1 }; return -1 }()) else {
                    if case .next = command { bounce(.right) } else { bounce(.left) }; return
                }
                remember(next); render(focusing:next,relayout:false); publish(); return
            }
            let order = (arrival[status.active] ?? []).filter { available($0) && entries[$0]?.observation.parent == nil }
            guard !order.isEmpty else { return }
            let index = focused.flatMap { order.firstIndex(of: $0) } ?? 0
            let step = if case .next = command { 1 } else { -1 }
            if !order.indices.contains(index + step) { return }
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
        if let focused, let owner = entries[focused]?.pid,
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
        layer.entry = floating(id) ? .all : .rails
        remember(id)
        // The native operation already selected this window. A queued raise
        // can otherwise interrupt a minimize that begins after this snapshot.
        render(focusing: id, relayout: false, takeFocus: false, layoutWindows: layoutWindows)
        publish()
    }

    private func render(focusing selection: UInt32?, relayout: Bool, activateDesktop: Bool = true, takeFocus: Bool = true,
                        layoutWindows: Set<UInt32> = [], instant: Bool = false) {
        guard status.enabled, !quitting, !pointerHeld else { return }
        if let selection, carousel.location(selection) != nil { layer.entry = .rails }
        renderCarousel(focusing: selection, activateDesktop: activateDesktop, takeFocus: takeFocus, instant: instant)
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

    private func assign(_ id: UInt32, to workspace: Int, initial: Bool = false) {
        guard let entry = entries[id], ![.fullscreen, .ignored].contains(entry.observation.record.state), primary(entry.observation) else { return }
        entries[id]?.workspace = workspace
        if !(arrival[workspace] ?? []).contains(id) {
            if initial {
                let index = arrival[workspace, default: []].firstIndex { $0 > id } ?? arrival[workspace, default: []].endIndex
                arrival[workspace, default: []].insert(id, at: index)
            } else { arrival[workspace, default: []].append(id) }
        }
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
        carousel.select(id)
    }

    private func preferred(in workspace: Int) -> UInt32? {
        if layers[workspace]?.focused == true { return preferredFloat(in: workspace) ?? carousel.remembered(workspace) }
        return carousel.remembered(workspace).flatMap { available($0) ? $0 : nil }
    }

    private func availableState(_ state: WindowState) -> Bool { state == .tiled || state == .floats }
    private func available(_ id: UInt32) -> Bool { entries[id].map { availableState($0.observation.record.state) } ?? false }

    private func primary(_ observation: WindowObservation) -> Bool {
        if (carousel.location(observation.record.id) != nil || entries[observation.record.id]?.workspace != nil) { return true }
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
        status.layer = status.enabled ? layer.status : nil
        status.animationDuration = motionDuration
        status.motion = configuration.animation.duration == 0 ? "off: duration 0"
            : motionPreferences?.reduceMotion == true ? "off: Reduce Motion"
            : stage?.available != true ? "off: Screen Recording permission needed" : "on"
        if status.enabled {
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
            if status.enabled, let p = carousel.location(id) {
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
        return e.observation.record.state == .tiled
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

    private var layerNeedsRaises: Bool { layer.pinned || layer.entry == .all }

    /// One idempotent pass, computed from the current frontmost app and the
    /// current visible floats. It is owed after each placement and whenever
    /// the native frontmost app differs from the last pass's, and runs once
    /// focus has settled: an activation still in flight would make the app
    /// about to lose focus look foreground and skip its floats. Called after
    /// placements, focus results and every catalog publication; with nothing
    /// owed and the same frontmost app it does nothing. A worker declines
    /// floats of an app with an unresolved activation, which owes another
    /// pass once that app publishes it resolved.
    private func restackLayer() {
        guard layerNeedsRaises, status.enabled, !quitting, !pointerHeld, !pointerReconciling, placementToken == nil else { return }
        let front = applications.frontmostPID
        switch layerRestack {
        case .running: return
        case .done(let last): if last == front { return }; layerRestack = .owed
        case .owed: break
        }
        guard staging?.awaitsPlacement != true, focusSettled else { return }
        restackPasses += 1
        layerRestack = .running(restackPasses)
        restackAwaitingActivation.removeAll()
        let visible = onScreen()
        let ids = layerRaiseOrder.filter { visible.contains($0) && !closeted.contains($0) && available($0) && entries[$0]?.pid != front }
        raiseLayerFloats(ids[...], token: restackPasses, front: front)
    }

    /// Tessel's own focus write has answered (its activation reorders the
    /// app's windows, and a layer handoff waits on it too), and native focus
    /// is not on a managed window other than the selection, which would mean
    /// a selection, tessel's or the user's, is still on its way. Focus on
    /// nothing tessel manages, such as an ignored panel, cannot become one.
    private var focusSettled: Bool {
        guard !pendingFocus else { return false }
        guard let focused, let front = applications.frontmostPID, let native = appFocus[front], native != focused else { return true }
        return !(available(native) && entries[native]?.workspace != nil)
    }

    private var layerRestackPending: Bool {
        guard layerNeedsRaises else { return false }
        if case .done = layerRestack { return false }
        return true
    }

    /// Serial across app workers as well as within one app: concurrent AXRaise
    /// replies cannot preserve a cross-app MRU order. A new placement cancels it.
    private func raiseLayerFloats(_ ids: ArraySlice<UInt32>, token: UInt64, front: Int32?) {
        guard layerRestack == .running(token), status.enabled, !quitting, layerNeedsRaises, !pointerHeld, !pointerReconciling else { return }
        guard let id = ids.first else {
            layerRestack = .done(front: front)
            // The frontmost app can change while the pass runs.
            restackLayer()
            guard !layerRestackPending else { return }
            orderStage()
            finishStage()
            return
        }
        guard let entry = entries[id], available(id), !closeted.contains(id), entry.pid != applications.frontmostPID,
              let catalog else { raiseLayerFloats(ids.dropFirst(), token: token, front: front); return }
        catalog.raiseBackground(pid: entry.pid, id: id) { [weak self] result in
            guard let self else { return }
            if result == .awaitingActivation, self.layerRestack == .running(token) { self.restackAwaitingActivation.insert(entry.pid) }
            self.raiseLayerFloats(ids.dropFirst(), token: token, front: front)
        }
    }

    /// Visible windows keep their observed relative order, including native
    /// panels and failed raises. Only an unseen destination tile needs a
    /// provisional slot until placement: before the currently visible tiles,
    /// preserving floats already above those tiles. Reveal reads CG again.
    private func orderStage() {
        guard layer.pinned, let staging, let stage else { return }
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
        // A second toggle reverses the pending return before any membership
        // changed; a third starts a new read with a distinct decision.
        if pendingFloatTransfer?.window == id, pendingFloatTransfer?.decision == decisions {
            pendingFloatTransfer = nil
            decisions += 1
            return
        }
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
            decisions += 1
            let decision = decisions
            pendingFloatTransfer = (id, decision)
            catalog?.refreshFrame(pid: entry.pid, id: id) { [weak self] frame in
                guard let self, self.pendingFloatTransfer?.decision == decision else { return }
                self.pendingFloatTransfer = nil
                guard let frame, self.status.enabled, !self.quitting,
                      self.decisions == decision, self.focused == id, self.available(id), self.floating(id),
                      self.applications.frontmostPID == entry.pid, self.appFocus[entry.pid] == id,
                      self.entries[id]?.workspace == self.status.active, self.entries[id]?.observation.parent == nil else { return }
                self.moveFloatToRail(id, frame: frame)
            }
            return
        } else { return }
        render(focusing: id, relayout: false, instant: true)
    }

    private func moveFloatToRail(_ id: UInt32, frame: CGRect) {
        layerPlacements[id] = nil
        entries[id]?.manual = .tiled
        entries[id]?.observation.record.state = .tiled
        entries[id]?.observation.record.reason = "moved to a rail"
        let width = frame.width
        let preset = Carousel.presets.min {
            let a = abs(carousel.presetWidth($0) - width), b = abs(carousel.presetWidth($1) - width)
            return abs(a - b) < 1e-6 ? $0 > $1 : a < b
        }
        carousel.insert(Carousel.Tile(id: id, size: CGSize(width: width, height: area.height), preset: preset), workspace: status.active)
        carouselSizes[id] = frame.size
        layer.entry = .rails
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
        clearStage()
        catalog?.cancelPresentations()
        placementToken = nil
        transition += 1
        decisions += 1
        expectedFocus = nil
        publish()
    }

    private func pointerChanged(_ held: Bool) {
        guard !quitting else { return }
        if held {
            guard !pointerHeld else { return }
            pointerHeld = true
            pointerReconciling = false
            pointerGeneration += 1
            pointerFrames = entries.mapValues { $0.observation.frame }
            layerRestack = .owed
            interruptCarousel()
            cancelFocusDecision()
        } else {
            guard pointerHeld else { return }
            pointerHeld = false
            pointerReconciling = true
            let generation = pointerGeneration
            // The last move's debounced publication can follow mouse-up. Read
            // on each existing AX lane, then reconcile all neighbors once.
            catalog?.refreshFrames { [weak self] in
                guard let self, !self.pointerHeld, self.pointerGeneration == generation else { return }
                self.pointerReconciling = false
                var changedTile = false
                for id in self.pointerFrames.keys.sorted() {
                    guard self.carousel.location(id) != nil, let previous = self.pointerFrames[id],
                          let current = self.entries[id]?.observation.frame,
                          abs(current.width - previous.width) > 1 || abs(current.height - previous.height) > 1 else { continue }
                    changedTile = true
                    self.carouselSizing.remove(id)
                    self.carousel.adoptWidth(id, current.width, left: current.minX - self.area.minX)
                    self.carouselSizes[id] = current.size
                }
                self.pointerFrames.removeAll()
                if changedTile { self.render(focusing: self.focused, relayout: false, takeFocus: false, instant: true) }
                let commands = self.pointerCommands
                self.pointerCommands.removeAll()
                for command in commands { self.perform(command) }
                self.restackLayer()
                self.publish()
            }
        }
    }

    private func finishMotionImmediately() {
        guard staging != nil, !pointerHeld else { return }
        clearStage()
        renderCarouselInstant(focusing: focused, activateDesktop: false, takeFocus: pendingFocus, keepFocus: true)
    }

    /// Check duration and Reduce Motion before touching the capture adapter.
    private var motionDuration: Int {
        guard configuration.animation.duration > 0, motionPreferences?.reduceMotion != true,
              stage?.available == true else { return 0 }
        return configuration.animation.duration
    }

    private var pinnedFrames: [UInt32: CGRect] {
        guard layer.pinned else { return [:] }
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
        // An old raise pass is superseded; the placement under the stage
        // owes a new one.
        layerRestack = .owed
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
        stagingNow.awaitsPlacement = true
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
        guard placementToken == nil, var staging, staging.settled, !staging.revealing, !staging.covering, layerHandoff == nil,
              carouselPresentation?.pending.isEmpty != false, !layerRestackPending, let stage else { return }
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
            self.restackLayer()
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
                                       keepFocus: Bool = false, underStage: Bool = false) {
        if !underStage { clearStage(); decisions += 1; cancelFocusDecision() }
        guard status.enabled, !quitting, let closet else { return }
        transition += 1
        let token = transition
        placementToken = token
        layerRestack = .owed
        if underStage { staging?.awaitsPlacement = false }
        desktopFocusObservation = nil
        layerHandoff = nil
        if !keepFocus { expectedFocus = nil }
        catalog?.cancelPresentations(invalidatingFocus: takeFocus)
        let outgoingSelection = applications.frontmostPID.flatMap { appFocus[$0] } ?? focused
        if let selection, available(selection) { remember(selection) } else { focused = nil }
        let frames = carousel.frames(status.active,area:area)
        let screen = screens.primaryScreen!
        let bounds = CGRect(x:screen.frame.minX,y:0,width:screen.frame.width,height:screen.frame.height)
        var show = Set(frames.filter { Self.onScreen($0.value, bounds) }.keys)
        show.formUnion(entries.keys.filter {
            entries[$0]?.workspace == status.active && available($0) && entries[$0]?.observation.parent == nil && carousel.location($0) == nil
                && layer.shows($0)
        })
        for id in entries.keys {
            if let parent = entries[id]?.observation.parent, show.contains(parent), available(id) { show.insert(id) }
        }
        let managed = Set(entries.keys.filter { entries[$0]?.workspace != nil && available($0) })
        let hide = managed.subtracting(show)
        let newlyShown = show.intersection(closeted).union(show.subtracting(onScreen()))
        let newlyHidden = hide.subtracting(closeted)
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
        // Resolve the whole placement before writing. Hidden destinations are
        // prepared first, then visible tiles sweep from the old view to the new.
        struct Placement {
            let id: UInt32
            let pid: Int32
            let target: CGRect?
            let resize: Bool
            let position: Bool
            let float: Bool
        }
        var remaining: [Placement] = []
        for id in show.sorted() where entries[id]?.observation.parent == nil {
            guard let candidate = entries[id] else { continue }
            let floatTarget = layerPlacements[id]
            let resize = carouselSizing.contains(id) || floatTarget != nil
            let position = positions.contains(id) || resize
            let target = floatTarget ?? (position ? frames[id] : nil)
            if target != nil { remaining.append(Placement(id: id, pid: candidate.pid, target: target, resize: resize, position: position, float: floatTarget != nil)) }
        }
        // Returning destinations cover the start view before any visible tile
        // vacates it. A focused resize grows over its neighbor before that
        // neighbor moves, preserving coverage throughout the sweep.
        let placements = remaining.sorted {
            let a = newlyShown.contains($0.id), b = newlyShown.contains($1.id)
            if a != b { return a }
            if $0.id == focused && $1.id != focused { return true }
            if $1.id == focused { return false }
            return (frames[$0.id]?.minX ?? 0, $0.id) < (frames[$1.id]?.minX ?? 0, $1.id)
        }
        let hiddenCount = placements.prefix { newlyShown.contains($0.id) }.count
        let shownRoots = newlyShown.filter { entries[$0]?.observation.parent == nil }.sorted()
        let hiddenRoots = newlyHidden.filter { entries[$0]?.observation.parent == nil }.sorted()
        var changedBounds = false
        var focusStarted = false, focusReady = false, geometryReady = false
        var remainingHides = Set(hiddenRoots)
        let targets = Dictionary(uniqueKeysWithValues: show.compactMap { id in
            entries[id].map { (id, frames[id] ?? layerPlacements[id] ?? $0.observation.frame) }
        })
        var ready = Set(show.filter { id in
            !closeted.contains(id) && targets[id] == entries[id]?.observation.frame
        })
        func commitVisibility() {
            guard self.transition == token, self.status.enabled, !self.pointerHeld, focusReady else { return }
            // A busy app must not delay an independent destination's focus.
            // Return windows as each is prepared; retire an old window only
            // when every destination covering its area is actually in place.
            let safe = remainingHides.filter { id in
                guard let old = self.entries[id]?.observation.frame else { return true }
                return targets.allSatisfy { replacement, rect in
                    !rect.intersects(old.intersection(bounds)) || ready.contains(replacement)
                }
            }.sorted()
            closet.hide(safe)
            self.closeted.formUnion(safe)
            remainingHides.subtract(safe)
            guard geometryReady, remainingHides.isEmpty else { self.publish(); return }
            self.layerHandoff = nil
            self.desktopFocusObservation = nil
            self.placementToken = nil
            self.restackLayer()
            if self.focused == nil && activateDesktop && takeFocus { self.activateFinderDesktop() }
            if underStage { self.finishStage() }
            self.publish()
            if changedBounds { self.render(focusing: self.focused, relayout: false, takeFocus: false) }
            self.scheduler.main.after(milliseconds: 50) { [weak self] in
                guard let self, self.transition == token, self.status.enabled else { return }
                if !hide.intersection(self.onScreen()).isEmpty { self.disable(reason: "SkyLight could not hide a window") }
                else { self.publish() }
            }
        }
        func finishFocus() { focusReady = true; commitVisibility() }
        func focusAndCommit() {
            guard self.transition == token, !focusStarted else { return }
            if let focused = self.focused, self.closeted.contains(focused), !ready.contains(focused) { return }
            focusStarted = true
            let outgoingFront = self.applications.frontmostPID
            let handoff = hiddenRoots.contains { self.entries[$0]?.pid == outgoingFront && (self.floating($0) || $0 == outgoingSelection) }
            guard takeFocus || handoff else { finishFocus(); return }
            if self.focused == nil {
                if activateDesktop { self.activateFinderDesktop() }
                finishFocus()
                return
            }
            guard let focused = self.focused, let candidate = self.entries[focused], let catalog = self.catalog else { finishFocus(); return }
            self.expectedFocus = focused
            if let outgoingFront, hiddenRoots.contains(where: { self.entries[$0]?.pid == outgoingFront }) {
                self.desktopFocusObservation = self.applications.observe { [weak self] event, app in
                    guard let self, event == .activated, app.pid != outgoingFront, self.transition == token else { return }
                    self.desktopFocusObservation = nil
                    finishFocus()
                }
            }
            // The destination is visible before native focus moves. A modal
            // outgoing float relinquishes focus before entering the closet.
            self.layerHandoff = LayerHandoff(token: token, selection: focused, commit: finishFocus)
            catalog.presentRail(pid: candidate.pid, id: focused, frame: nil, position: false, resize: false, focus: true, screenRight: self.screenRight) { [weak self] result in
                guard let self, self.transition == token else { return }
                self.layerHandoff?.awaitingObservation = true
                if result.focus == nil { self.expectedFocus = nil }
                if let focus = result.focus, focus.frontmost {
                    self.finishLayerHandoff(observedFocus: focus.window.map { self.entries[$0]?.observation.parent ?? $0 }, pid: candidate.pid)
                }
            }
        }
        func place(_ index: Int) {
            guard self.transition == token, !self.pointerHeld else { return }
            if index == 0 {
                let unchanged = shownRoots.filter { id in !placements.contains { $0.id == id } }
                closet.show(unchanged)
                self.closeted.subtract(unchanged)
                ready.formUnion(unchanged)
                if !placements.contains(where: { $0.id == self.focused }) { focusAndCommit() }
            }
            guard index < placements.count else { geometryReady = true; focusAndCommit(); commitVisibility(); return }
            let p = placements[index]
            guard let catalog = self.catalog else { geometryReady = true; finishFocus(); return }
            catalog.presentRail(pid: p.pid, id: p.id, frame: p.target, position: p.position, resize: p.resize, focus: false, screenRight: self.screenRight) { [weak self] result in
                guard let self, self.transition == token else { return }
                if let accepted = result.frame {
                    self.carouselPresentation?.pending.remove(p.id)
                    ready.insert(p.id)
                    if index < hiddenCount {
                        closet.show([p.id])
                        self.closeted.remove(p.id)
                    }
                    if p.float { self.layerPlacements[p.id] = nil }
                    if underStage { self.staging?.placed[p.id] = accepted }
                    if p.resize, !p.float, let target = p.target {
                        if underStage, self.staging?.shown == true { self.stage?.refresh(p.id) }
                        self.carouselSizing.remove(p.id)
                        self.carouselSizes[p.id] = accepted.size
                        self.carousel.accept(p.id, requested: target.size, accepted: accepted.size,
                                             learnBounds: target.minX >= bounds.minX && target.maxX <= bounds.maxX)
                        if abs(accepted.width - target.width) > 1 || abs(accepted.height - target.height) > 1 { changedBounds = true }
                    }
                }
                if p.id == self.focused {
                    if result.frame == nil { self.expectedFocus = nil }
                    focusAndCommit()
                }
                commitVisibility()
                place(index + 1)
            }
        }
        place(0)
    }

}
