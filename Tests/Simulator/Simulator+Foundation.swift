import Foundation
import Ports

package enum ContentTabStyle: String, CaseIterable, Sendable {
    case empty, populated, segmentedGroup, segmentedRadioGroup, segmentedTabs
}

extension SimulatedApp {
    @MainActor package func replaceChromeDescendant(in window: UInt32, forReads count: Int = 1) {
        mac.assume(.staleChromeDescendant)
        mac.action("\(alias) replace chrome descendant in window \(window) for \(count) children reads")
        var chrome = mac.foundation.chrome[window] ?? .init()
        chrome.replacements = max(0, count)
        mac.foundation.chrome[window] = chrome
        mac.notify(.layoutChanged, node: .window(window))
    }

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
        struct Chrome { var generation = 0; var replacements = 0 }
        var chrome: [UInt32: Chrome] = [:]
        var content: [UInt32: ContentTabs] = [:]
        var newTabButtons: Set<Int> = []
        var windowLists: [Int32: [UInt32]] = [:]
        var withheldFocus: Set<Int32> = []
    }
    enum FoundationNode: Hashable, Sendable {
        case contentGroup, contentTab(Int), page, newTabButton, chrome(Int)
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
        var children: [AXElement] = []
        if foundation.content[window] != nil {
            assume(.contentTabChrome)
            children.append(element(.foundation(window, .contentGroup)))
        }
        if var chrome = foundation.chrome[window] {
            assume(.staleChromeDescendant)
            children.append(element(.foundation(window, .chrome(chrome.generation))))
            // AppKit replaces the child after capturing the parent's reply.
            if chrome.replacements > 0 {
                chrome.replacements -= 1
                chrome.generation += 1
                foundation.chrome[window] = chrome
            }
        }
        return children
    }
    func extraNativeControls(_ group: Int) -> [AXElement] {
        guard foundation.newTabButtons.contains(group), let selected = groups[group]?.selected else { return [] }
        assume(.nativeTabExtraControls)
        return [element(.foundation(selected, .newTabButton))]
    }
    func readFoundation(_ attribute: AXAttribute, window: UInt32, node: FoundationNode) -> AXResult<AXValue> {
        if case .chrome(let generation) = node {
            assume(.staleChromeDescendant)
            guard windows[window]?.closed == false, foundation.chrome[window]?.generation == generation else { return AXResult(.invalidUIElement) }
            switch attribute {
            case .role: return AXResult(.success, .string("AXGroup"))
            case .children: return AXResult(.success, .elements([]))
            default: break
            }
        } else if node == .newTabButton {
            assume(.nativeTabExtraControls)
            switch attribute {
            case .role: return AXResult(.success, .string("AXButton"))
            case .children: return AXResult(.success, .elements([]))
            default: break
            }
        } else if let content = foundation.content[window] {
            assume(.contentTabChrome)
            let contents = [.empty, .segmentedRadioGroup].contains(content.style) ? [] : [element(.foundation(window, .page))]
            switch (node, attribute) {
            case (.contentGroup, .role):
                let role: String = switch content.style {
                case .segmentedGroup: "AXGroup"
                case .segmentedRadioGroup: "AXRadioGroup"
                default: "AXTabGroup"
                }
                return AXResult(.success, .string(role))
            case (.contentGroup, .tabs):
                if content.style == .segmentedRadioGroup { return AXResult(.attributeUnsupported) }
                return AXResult(.success, .elements((0..<content.count).map { element(.foundation(window, .contentTab($0))) }))
            case (.contentGroup, .contents):
                if content.style == .segmentedRadioGroup { return AXResult(.attributeUnsupported) }
                return AXResult(.success, .elements(contents))
            case (.contentGroup, .children):
                return AXResult(.success, .elements((0..<content.count).map { element(.foundation(window, .contentTab($0))) }
                    + contents))
            case (.contentTab, .role): return AXResult(.success, .string("AXRadioButton"))
            case (.page, .role): return AXResult(.success, .string(content.style == .populated ? "AXStaticText" : "AXGroup"))
            case (.contentTab, .children): return AXResult(.noValue)
            case (.page, .children): return AXResult(.success, .elements([]))
            default: break
            }
        }
        scheduler.failUnmodeled("AccessibilityPort.copy \(attribute.rawValue) \(name(.foundation(window, node)))")
        return AXResult(.cannotComplete)
    }
}
