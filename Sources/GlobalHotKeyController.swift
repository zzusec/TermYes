@preconcurrency import Carbon.HIToolbox
import Combine
import Foundation

private let termosaicHotKeyEventHandler: EventHandlerUPP = { _, _, _ in
    Task { @MainActor in
        TerminalManager.shared.showDashboard()
    }
    return noErr
}

enum GlobalShortcut: String, CaseIterable, Identifiable {
    case commandO
    case commandP
    case commandOptionO
    case commandShiftO
    case controlOptionCommandO
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .commandP: return "⌘P"
        case .commandO: return "⌘O"
        case .commandOptionO: return "⌥⌘O"
        case .commandShiftO: return "⇧⌘O"
        case .controlOptionCommandO: return "⌃⌥⌘O"
        case .disabled: return "关闭"
        }
    }

    var menuTitle: String {
        self == .disabled ? "关闭全局快捷键" : displayName
    }

    fileprivate var carbonModifiers: UInt32 {
        switch self {
        case .commandP, .commandO:
            return UInt32(cmdKey)
        case .commandOptionO:
            return UInt32(cmdKey | optionKey)
        case .commandShiftO:
            return UInt32(cmdKey | shiftKey)
        case .controlOptionCommandO:
            return UInt32(cmdKey | optionKey | controlKey)
        case .disabled:
            return 0
        }
    }

    fileprivate var carbonKeyCode: UInt32 {
        self == .commandP ? UInt32(kVK_ANSI_P) : UInt32(kVK_ANSI_O)
    }

    static var saved: GlobalShortcut {
        guard let raw = UserDefaults.standard.string(forKey: "globalShortcut"),
              let shortcut = GlobalShortcut(rawValue: raw) else {
            return .commandO
        }
        return shortcut
    }
}

@MainActor
final class GlobalHotKeyController: ObservableObject {
    static let shared = GlobalHotKeyController()

    @Published private(set) var selectedShortcut = GlobalShortcut.saved
    @Published private(set) var registrationError: String?

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private let hotKeyID = EventHotKeyID(signature: 0x544D4F53, id: 1) // TMOS

    private init() {}

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func activateSavedShortcut() {
        setShortcut(GlobalShortcut.saved, persist: false)
    }

    func setShortcut(_ shortcut: GlobalShortcut, persist: Bool = true) {
        unregisterCurrentShortcut()
        selectedShortcut = shortcut
        registrationError = nil

        if persist {
            UserDefaults.standard.set(shortcut.rawValue, forKey: "globalShortcut")
        }
        guard shortcut != .disabled else { return }
        guard installEventHandlerIfNeeded() else { return }

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.carbonKeyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            registrationError = Self.registrationFailure(shortcut, status: status)
            hotKey = nil
            return
        }
        hotKey = reference
    }

    static func registrationFailure(_ shortcut: GlobalShortcut, status: OSStatus) -> String {
        if status == eventHotKeyExistsErr {
            return "快捷键 \(shortcut.displayName) 已被其他应用占用（错误 \(status)）"
        }
        return "无法启用快捷键 \(shortcut.displayName)（错误 \(status)）"
    }

    private func installEventHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            termosaicHotKeyEventHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )
        if status != noErr || eventHandler == nil {
            registrationError = "无法启用全局快捷键（错误 \(status)）"
            return false
        }
        return true
    }

    private func unregisterCurrentShortcut() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }
}
