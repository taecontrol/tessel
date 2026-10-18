import Foundation
import Ports

package enum ContentTabStyle: String, CaseIterable, Sendable {
    // Keep segmented chrome as choices until the real contract pins its shape.
    case empty, populated, segmentedGroup, segmentedRadioGroup, segmentedTabs
}

extension SimulatedApp {
    @MainActor package func showContentTabs(in window: UInt32, count: Int = 3, style: ContentTabStyle = .populated) {
        mac.assume(.contentTabChrome)
        mac.action("\(alias) show \(count) \(style.rawValue) content tabs in window \(window)")
        mac.foundation.content[window] = .init(count: count, style: style)
        mac.notify(.layoutChanged, node: .window(window))
    }

    @MainActor package func showNewTabButton(in window: UInt32) {
        mac.assume(.nativeTabExtraControls)
        guard let group = mac.windows[window]?.group else {
            mac.scheduler.failUnmodeled("app.showNewTabButton without native group"); return
        }
        mac.action("\(alias) show New Tab button in window \(window)")
        mac.foundation.newTabButtons.insert(group)
        mac.notify(.layoutChanged, node: .window(window))
    }

    @MainActor @discardableResult package func addNativeTab(to reference: UInt32) -> UInt32 {
        mac.assume(.nativeTabIdentity)
        guard let window = mac.windows[reference], let group = window.group else {
            mac.scheduler.failUnmodeled("app.addNativeTab without native group"); return 0
        }
        let id = mac.open(pid, spec: window.spec, background: true)
        mac.windows[id]?.group = group
        mac.groups[group]?.windows.append(id)
        mac.action("\(alias) insert native tab window \(id) beside \(reference)")
        mac.focus(id)
        mac.notify(.layoutChanged, node: .window(id))
        return id
    }

    @MainActor package func publishWindowList(_ windows: [UInt32]?) {
        mac.assume(.delayedNativeTabFocus)
        mac.action("\(alias) publish \(windows.map { String(describing: $0) } ?? "native") window list")
        mac.foundation.windowLists[pid] = windows
    }

    @MainActor package func publishFocusedWindow(_ published: Bool) {
        mac.assume(.delayedNativeTabFocus)
        mac.action("\(alias) publish focused window=\(published)")
        if published { mac.foundation.withheldFocus.remove(pid) }
        else { mac.foundation.withheldFocus.insert(pid) }
        if published {
            mac.notify(.focusedWindowChanged, node: .application(pid))
            mac.notify(.mainWindowChanged, node: .application(pid))
        }
    }
}

extension SimulatedMac {
    struct FoundationState {
        struct ContentTabs { let count: Int; let style: ContentTabStyle }
        var content: [UInt32: ContentTabs] = [:]
        var newTabButtons: Set<Int> = []
        var windowLists: [Int32: [UInt32]] = [:]
        var withheldFocus: Set<Int32> = []
    }
    enum FoundationNode: Hashable, Sendable {
        case contentGroup, contentTab(Int), page, newTabButton
    }

    func publishedWindowList(_ pid: Int32) -> [UInt32]? {
        guard let windows = foundation.windowLists[pid] else { return nil }
        assume(.delayedNativeTabFocus)
        return windows
    }
    func withholdsFocus(_ pid: Int32) -> Bool {
        guard foundation.withheldFocus.contains(pid) else { return false }
        assume(.delayedNativeTabFocus)
        return true
    }
    func foundationChildren(_ window: UInt32) -> [AXElement] {
        guard foundation.content[window] != nil else { return [] }
        assume(.contentTabChrome)
        return [element(.foundation(window, .contentGroup))]
    }
    func extraNativeControls(_ group: Int) -> [AXElement] {
        guard foundation.newTabButtons.contains(group), let selected = groups[group]?.selected else { return [] }
        assume(.nativeTabExtraControls)
        return [element(.foundation(selected, .newTabButton))]
    }
    func readFoundation(_ attribute: AXAttribute, window: UInt32, node: FoundationNode) -> AXResult<AXValue> {
        if node == .newTabButton {
            assume(.nativeTabExtraControls)
            switch attribute {
            case .role: return AXResult(.success, .string("AXButton"))
            case .children: return AXResult(.success, .elements([]))
            default: break
            }
        } else if let content = foundation.content[window] {
            assume(.contentTabChrome)
            let contents = content.style == .empty ? [] : [element(.foundation(window, .page))]
            switch (node, attribute) {
            case (.contentGroup, .role):
                let role: String = switch content.style {
                case .segmentedGroup: "AXGroup"
                case .segmentedRadioGroup: "AXRadioGroup"
                default: "AXTabGroup"
                }
                return AXResult(.success, .string(role))
            case (.contentGroup, .tabs):
                return AXResult(.success, .elements((0..<content.count).map { element(.foundation(window, .contentTab($0))) }))
            case (.contentGroup, .contents):
                return AXResult(.success, .elements(contents))
            case (.contentGroup, .children):
                return AXResult(.success, .elements((0..<content.count).map { element(.foundation(window, .contentTab($0))) }
                    + contents))
            case (.contentTab, .role): return AXResult(.success, .string("AXRadioButton"))
            case (.page, .role): return AXResult(.success, .string(content.style == .populated ? "AXStaticText" : "AXGroup"))
            case (.contentTab, .children), (.page, .children): return AXResult(.success, .elements([]))
            default: break
            }
        }
        scheduler.failUnmodeled("AccessibilityPort.copy \(attribute.rawValue) \(name(.foundation(window, node)))")
        return AXResult(.cannotComplete)
    }
}
