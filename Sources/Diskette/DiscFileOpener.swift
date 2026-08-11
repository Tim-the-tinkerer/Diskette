import AppKit
import Foundation
import Quartz

/// Materializes virtual-disc files to a temp folder so macOS can open or Quick Look them.
/// Snapshots only — edits in other apps do not write back to the `.Floppy`.
enum DiscFileOpener {

    private static let rootName = "DisketteOpen"

    static var stagingRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(rootName, isDirectory: true)
    }

    /// Write an entry to a stable temp path for this volume session and return the URL.
    @discardableResult
    static func materialize(entry: DisketteEngine.Entry, volumeId: UUID) throws -> URL {
        guard !entry.isDirectory else {
            throw DisketteEngine.EngineError.isDirectory(entry.path)
        }
        let crc = DisketteEngine.crc32(entry.data)
        if crc != entry.crc32 {
            throw DisketteEngine.EngineError.crcMismatch(path: entry.path)
        }
        let data = entry.data

        let dir = stagingRoot
            .appendingPathComponent(volumeId.uuidString, isDirectory: true)
            .appendingPathComponent(stagingRelativeDirectory(for: entry.path), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileURL = dir.appendingPathComponent(entry.name)
        // Temporarily writable so we can replace contents
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: fileURL.path
            )
        }
        try data.write(to: fileURL, options: .atomic)
        // Read-only so casual edits don't imply the disc was updated
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: fileURL.path
        )
        return fileURL
    }

    /// Open with the default macOS application for this file type.
    static func openInDefaultApp(entry: DisketteEngine.Entry, volumeId: UUID) throws {
        let url = try materialize(entry: entry, volumeId: volumeId)
        guard NSWorkspace.shared.open(url) else {
            throw DisketteEngine.EngineError.io("macOS could not open \(entry.name)")
        }
    }

    /// Open several files in their default apps.
    static func openInDefaultApp(entries: [DisketteEngine.Entry], volumeId: UUID) throws {
        let files = entries.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        for e in files {
            try openInDefaultApp(entry: e, volumeId: volumeId)
        }
    }

    /// Present Quick Look for one or more materialized files.
    static func quickLook(entries: [DisketteEngine.Entry], volumeId: UUID) throws {
        let files = entries.filter { !$0.isDirectory }
        guard !files.isEmpty else {
            throw DisketteEngine.EngineError.io("Nothing to preview")
        }
        var urls: [URL] = []
        for e in files {
            urls.append(try materialize(entry: e, volumeId: volumeId))
        }
        QuickLookController.shared.show(urls: urls)
    }

    static func cleanup(volumeId: UUID) {
        let dir = stagingRoot.appendingPathComponent(volumeId.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    static func cleanupAll() {
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    private static func stagingRelativeDirectory(for volumePath: String) -> String {
        let parent = (volumePath as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == "/" { return "_root" }
        let trimmed = parent.hasPrefix("/") ? String(parent.dropFirst()) : parent
        return trimmed
            .split(separator: "/")
            .map { component -> String in
                let s = String(component)
                if s == ".." || s == "." { return "_" }
                return s
            }
            .joined(separator: "/")
    }
}

// MARK: - Quick Look panel

/// Owns `QLPreviewPanel` data source while the panel is visible.
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []

    private override init() {
        super.init()
    }

    func show(urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }

        let proxy = QuickLookResponderProxy.shared
        proxy.controller = self
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            if proxy.superview == nil, let content = window.contentView {
                proxy.frame = .zero
                proxy.isHidden = true
                content.addSubview(proxy)
            }
            window.makeFirstResponder(proxy)
        }

        // Prefer explicit dataSource; also register via responder chain for space-bar reuse
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0, index < urls.count else { return nil }
        return urls[index] as QLPreviewItem
    }

    // MARK: QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        false
    }
}

/// Sits in the responder chain so `QLPreviewPanel` can adopt our data source.
final class QuickLookResponderProxy: NSView {
    static let shared: QuickLookResponderProxy = {
        let v = QuickLookResponderProxy(frame: .zero)
        v.isHidden = true
        return v
    }()

    weak var controller: QuickLookController?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = controller
        panel.delegate = controller
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}
