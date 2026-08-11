import AppKit
import Foundation
import UniformTypeIdentifiers

/// Shared drag-and-drop helpers for Finder ↔ Diskette.
enum DragDropSupport {

    /// Load all file URLs from a drop’s item providers (multi-file drops).
    @MainActor
    static func loadURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadURL(from: provider) {
                urls.append(url)
            }
        }
        // De-dupe while preserving order
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    @MainActor
    static func loadURL(from provider: NSItemProvider) async -> URL? {
        // Prefer modern URL object loading
        if provider.canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { cont in
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    cont.resume(returning: object)
                }
            }
            if let url { return url }
        }

        return await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: url)
                } else if let url = item as? URL {
                    cont.resume(returning: url)
                } else if let str = item as? String {
                    cont.resume(returning: URL(fileURLWithPath: str))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Run `body` with security-scoped access for each URL that needs it.
    static func withSecurityScopedAccess<T>(to urls: [URL], _ body: ([URL]) throws -> T) rethrows -> T {
        var tokens: [(URL, Bool)] = []
        for url in urls {
            let ok = url.startAccessingSecurityScopedResource()
            tokens.append((url, ok))
        }
        defer {
            for (url, ok) in tokens where ok {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body(urls)
    }

    /// Materialize disc entries to temp files/folders for a Finder drag-out.
    /// - If one path: that file or folder URL.
    /// - If many: a temporary folder containing all items (Finder-friendly multi-drag).
    static func exportForDrag(
        paths: [String],
        volume: DisketteEngine.Volume,
        volumeId: UUID
    ) throws -> URL {
        let unique = Array(Set(paths)).sorted()
        guard !unique.isEmpty else {
            throw DisketteEngine.EngineError.io("Nothing to drag")
        }

        let stamp = UUID().uuidString
        let root = DiscFileOpener.stagingRoot
            .appendingPathComponent(volumeId.uuidString, isDirectory: true)
            .appendingPathComponent("DragOut-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var exported: [URL] = []
        for path in unique {
            guard let entry = volume.entry(at: path) else { continue }
            if entry.isDirectory {
                // extract puts contents under hostDir using entry name when path is a dir
                try DisketteEngine.extract(from: volume, path: path, toHostDirectory: root)
                let dirURL = root.appendingPathComponent(entry.name)
                if FileManager.default.fileExists(atPath: dirURL.path) {
                    exported.append(dirURL)
                }
            } else {
                let dest = root.appendingPathComponent(entry.name)
                // Avoid clobber within multi-export
                let finalDest = uniqueFileURL(dest)
                let data = try volume.readFile(at: entry.path)
                try data.write(to: finalDest, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: finalDest.path
                )
                exported.append(finalDest)
            }
        }

        guard !exported.isEmpty else {
            throw DisketteEngine.EngineError.io("Nothing to drag")
        }
        if exported.count == 1 {
            return exported[0]
        }
        // Multi-item: drag the folder that contains them all
        return root
    }

    private static func uniqueFileURL(_ url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Build an `NSItemProvider` that delivers a file URL to Finder / other apps.
    static func itemProvider(fileURL: URL) -> NSItemProvider {
        if let provider = NSItemProvider(contentsOf: fileURL) {
            return provider
        }
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(fileURL, false, nil)
            return nil
        }
        return provider
    }
}
