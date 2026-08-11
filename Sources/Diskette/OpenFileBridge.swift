import AppKit
import Foundation

/// Queues file URLs opened from Finder before SwiftUI is ready to consume them.
enum OpenFileBridge {
    static let flushNotification = Notification.Name("Diskette.OpenFileBridge.flush")

    private static let lock = NSLock()
    private static var queue: [URL] = []

    static func enqueue(_ url: URL) {
        lock.lock()
        queue.append(url)
        lock.unlock()
        requestFlush()
    }

    static func hasPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !queue.isEmpty
    }

    static func drain() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        let items = queue
        queue.removeAll()
        return items
    }

    static func requestFlush() {
        NotificationCenter.default.post(name: flushNotification, object: nil)
    }
}

/// Lets AppDelegate coordinate dirty-disc prompts on quit.
@MainActor
enum DocumentCloseBridge {
    /// Whether the mounted disc has unsaved changes.
    static var isDirty: () -> Bool = { false }
    /// Save the mounted disc (may show Save As). Returns true on success.
    static var saveMountedDisc: () -> Bool = { false }

    /// Prompt if needed. Returns true when quit may proceed.
    static func prepareToQuit() -> Bool {
        guard isDirty() else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes before quitting?"
        alert.informativeText = "The mounted disc has unsaved changes."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveMountedDisc()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}
