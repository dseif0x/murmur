import AppKit
import ApplicationServices

/// Push-to-talk: hold a modifier key (alone) anywhere in macOS. Watching keys
/// outside the app needs the Accessibility permission.
final class HoldKey {
    enum Key: String, CaseIterable, Identifiable {
        case rightOption, rightCommand, fn
        var id: String { rawValue }
        var label: String {
            switch self {
            case .rightOption: return "Right ⌥ Option"
            case .rightCommand: return "Right ⌘ Command"
            case .fn: return "fn / 🌐"
            }
        }
        var keyCode: UInt16 {
            switch self {
            case .rightOption: return 61
            case .rightCommand: return 54
            case .fn: return 63
            }
        }
        var flag: NSEvent.ModifierFlags {
            switch self {
            case .rightOption: return .option
            case .rightCommand: return .command
            case .fn: return .function
            }
        }
    }

    var key: Key = .rightOption
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    private var monitors: [Any] = []
    private var held = false

    static var trusted: Bool { AXIsProcessTrusted() }

    static func askForPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func start() {
        stop()
        let handler: (NSEvent) -> Void = { [weak self] e in self?.handle(e) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { e in handler(e); return e }) {
            monitors.append(l)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if held {
            held = false
            onUp?()
        }
    }

    private func handle(_ e: NSEvent) {
        guard e.keyCode == key.keyCode else { return }
        let down = e.modifierFlags.contains(key.flag)
        if down && !held {
            held = true
            onDown?()
        } else if !down && held {
            held = false
            onUp?()
        }
    }
}
