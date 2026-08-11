import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// In-app file browser for a mounted virtual floppy.
struct BrowserView: View {
    @ObservedObject var volume: DisketteEngine.Volume
    @Binding var currentPath: String
    var onStatus: (String) -> Void
    var onDirty: () -> Void
    /// Open a dropped `.Floppy` in the app (replace mounted disc).
    var onOpenFloppy: ((URL) -> Void)? = nil

    @State private var selection: Set<String> = []
    @State private var renamePath: String?
    @State private var renameText = ""
    @State private var showNewFolder = false
    @State private var newFolderName = "New Folder"

    private var children: [DisketteEngine.Entry] {
        volume.children(of: currentPath)
    }

    private var hasFileSelection: Bool {
        selection.contains { path in
            guard let e = volume.entry(at: path) else { return false }
            return !e.isDirectory
        }
    }

    private var selectedEntries: [DisketteEngine.Entry] {
        selection.compactMap { volume.entry(at: $0) }
    }

    private var breadcrumbs: [String] {
        if currentPath == "/" { return ["/"] }
        let parts = currentPath.split(separator: "/").map(String.init)
        var acc: [String] = ["/"]
        var built = ""
        for p in parts {
            built += "/" + p
            acc.append(built)
        }
        return acc
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            pathBar
            Divider()
            fileList
        }
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        // Drops are handled at the window (ContentView) so multi-target doesn't double-import.
        .sheet(isPresented: $showNewFolder) {
            newFolderSheet
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                goUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Parent folder")
            .disabled(currentPath == "/")

            Button {
                addFiles()
            } label: {
                Label("Add…", systemImage: "plus")
            }
            .help("Copy files from Mac onto this disc")

            Button {
                newFolderName = "New Folder"
                showNewFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("New folder")

            Button {
                extractSelection()
            } label: {
                Label("Extract…", systemImage: "square.and.arrow.up")
            }
            .disabled(selection.isEmpty)
            .help("Extract selected items to a folder on your Mac")

            Button {
                deleteSelection()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(selection.isEmpty)
            .help("Delete from disc")

            Divider()
                .frame(height: 14)

            Button {
                openSelectionInApp()
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            .disabled(!hasFileSelection)
            .help("Open with the default macOS app (temp copy)")

            Button {
                quickLookSelection()
            } label: {
                Image(systemName: "eye")
            }
            .disabled(!hasFileSelection)
            .help("Quick Look (space-bar style preview)")

            Spacer()

            Text("\(children.count) item\(children.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { idx, path in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        currentPath = path
                        selection.removeAll()
                    } label: {
                        Text(path == "/" ? "Disc" : (path as NSString).lastPathComponent)
                            .font(.caption.weight(path == currentPath ? .semibold : .regular))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(path == currentPath ? AppTheme.accent : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    // MARK: - List

    private var fileList: some View {
        Group {
            if children.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 32))
                        .foregroundStyle(AppTheme.accent.opacity(0.5))
                    Text(currentPath == "/" ? "Empty disc" : "Empty folder")
                        .font(.headline)
                            Text("Drop files or folders here · drag the ⋮⋮ handle to export to Finder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Important: do NOT put `.onDrag` on the whole row — it steals clicks and
                // breaks List selection / double-click navigation (same class of bug as
                // onTapGesture on Table cells). Drag-out lives only on the grip handle.
                List(selection: $selection) {
                    ForEach(children, id: \.path) { entry in
                        fileRow(entry)
                            .tag(entry.path)
                            .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 8))
                    }
                }
                .listStyle(.inset)
                // Don't use .id(currentPath) on the List — it remounts the control and
                // kills selection/focus when opening folders.
                .contextMenu(forSelectionType: String.self) { paths in
                    selectionContextMenu(paths: paths)
                } primaryAction: { paths in
                    if let first = paths.first, let entry = volume.entry(at: first) {
                        openEntry(entry)
                    }
                }
                .onChange(of: currentPath) { _ in
                    selection = []
                }
                .onChange(of: childPathsSignature) { _ in
                    let valid = Set(children.map(\.path))
                    let pruned = selection.intersection(valid)
                    if pruned != selection {
                        selection = pruned
                    }
                }
            }
        }
    }

    /// Drag selection (or this row) out to Finder as real files.
    private func dragProvider(for entry: DisketteEngine.Entry) -> NSItemProvider {
        let paths: [String]
        if selection.contains(entry.path), !selection.isEmpty {
            paths = Array(selection)
        } else {
            paths = [entry.path]
        }
        do {
            let url = try DragDropSupport.exportForDrag(
                paths: paths,
                volume: volume,
                volumeId: volume.id
            )
            return DragDropSupport.itemProvider(fileURL: url)
        } catch {
            onStatus("Drag failed: \(error.localizedDescription)")
            return NSItemProvider()
        }
    }

    /// Stable signature of visible paths for pruning selection.
    private var childPathsSignature: String {
        children.map(\.path).joined(separator: "\u{1e}")
    }

    @ViewBuilder
    private func fileRow(_ entry: DisketteEngine.Entry) -> some View {
        HStack(spacing: 8) {
            // Dedicated drag handle — keeps selection working on the rest of the row.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
                .help("Drag to Finder")
                .onDrag { dragProvider(for: entry) }

            Image(systemName: entry.isDirectory ? "folder.fill" : iconName(for: entry.name))
                .foregroundStyle(entry.isDirectory ? AppTheme.accent : .secondary)
                .frame(width: 18, alignment: .center)
            Text(entry.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(entry.isDirectory ? "—" : DisketteEngine.formatBytes(entry.size))
                .foregroundStyle(.secondary)
                .font(.caption.monospacedDigit())
                .frame(minWidth: 64, alignment: .trailing)
            Text(entry.modified, style: .date)
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func selectionContextMenu(paths: Set<String>) -> some View {
        let entries = paths.compactMap { volume.entry(at: $0) }
        let files = entries.filter { !$0.isDirectory }
        if let first = entries.first {
            if first.isDirectory {
                Button("Open") { openEntry(first) }
            } else {
                Button("Open") { openInDefaultApp(first) }
                Button("Quick Look") { quickLook(files.isEmpty ? [first] : files) }
                if let text = String(data: first.data, encoding: .utf8),
                   !text.contains("\0"), first.size < 512_000 {
                    Button("Peek Text…") {
                        showTextPreview(entry: first, text: text)
                    }
                }
            }
            Button("Extract…") { extractPaths(Array(paths)) }
            Divider()
            Button("Rename…") {
                renamePath = first.path
                renameText = first.name
                promptRename()
            }
            Button("Delete", role: .destructive) { deletePaths(Array(paths)) }
        }
    }

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Folder")
                .font(.headline)
            TextField("Folder name", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showNewFolder = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    createFolder()
                    showNewFolder = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    // MARK: - Actions

    private func goUp() {
        guard currentPath != "/" else { return }
        currentPath = (currentPath as NSString).deletingLastPathComponent
        if currentPath.isEmpty { currentPath = "/" }
        selection.removeAll()
    }

    /// Max characters shown in the quick preview alert (full file stays on the disc).
    private static let previewCharLimit = 480
    /// Max lines in the preview body.
    private static let previewLineLimit = 12

    private func openEntry(_ entry: DisketteEngine.Entry) {
        if entry.isDirectory {
            currentPath = entry.path
            selection.removeAll()
        } else {
            openInDefaultApp(entry)
        }
    }

    private func openInDefaultApp(_ entry: DisketteEngine.Entry) {
        do {
            try DiscFileOpener.openInDefaultApp(entry: entry, volumeId: volume.id)
            onStatus("Opened \(entry.name) in default app (temp copy from disc)")
        } catch {
            onStatus("Open failed: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    private func openSelectionInApp() {
        let files = selectedEntries.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        if files.count == 1 {
            openInDefaultApp(files[0])
            return
        }
        do {
            try DiscFileOpener.openInDefaultApp(entries: files, volumeId: volume.id)
            onStatus("Opened \(files.count) files in default apps")
        } catch {
            onStatus("Open failed: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    private func quickLook(_ entries: [DisketteEngine.Entry]) {
        do {
            try DiscFileOpener.quickLook(entries: entries, volumeId: volume.id)
            let n = entries.filter { !$0.isDirectory }.count
            onStatus("Quick Look · \(n) item\(n == 1 ? "" : "s")")
        } catch {
            onStatus("Quick Look failed: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    private func quickLookSelection() {
        quickLook(selectedEntries)
    }

    private func showTextPreview(entry: DisketteEngine.Entry, text: String) {
        let alert = NSAlert()
        alert.messageText = entry.name
        alert.informativeText = truncatedPreview(text, byteSize: entry.size)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Extract…")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            openInDefaultApp(entry)
        } else if response == .alertThirdButtonReturn {
            extractOne(entry)
        }
    }

    /// Short snippet suitable for NSAlert — not a full document viewer.
    private func truncatedPreview(_ text: String, byteSize: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var truncatedByLines = false
        if lines.count > Self.previewLineLimit {
            lines = Array(lines.prefix(Self.previewLineLimit))
            truncatedByLines = true
        }
        var body = lines.joined(separator: "\n")
        var truncatedByChars = false
        if body.count > Self.previewCharLimit {
            let end = body.index(body.startIndex, offsetBy: Self.previewCharLimit)
            body = String(body[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            truncatedByChars = true
        }

        let wasTruncated = truncatedByLines || truncatedByChars || body.count < normalized.count
        if wasTruncated {
            let total = DisketteEngine.formatBytes(byteSize)
            body += "\n\n… preview truncated · \(total) on disc — Extract… for the full file"
        }
        return body
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Add files or folders onto the disc"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            importHost(url)
        }
    }

    private func importHost(_ url: URL) {
        do {
            try importHostThrowing(url)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                onStatus("Added folder \(url.lastPathComponent)")
            } else {
                let dest = DisketteEngine.Volume.join(currentPath, url.lastPathComponent)
                onStatus("Added \(url.lastPathComponent) (\(DisketteEngine.formatBytes(volume.entry(at: dest)?.size ?? 0)))")
            }
            onDirty()
        } catch {
            onStatus("Add failed: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    private func importHostThrowing(_ url: URL) throws {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let dest = DisketteEngine.Volume.join(currentPath, url.lastPathComponent)
            try DisketteEngine.importHostFolder(into: volume, from: url, destDir: dest)
        } else {
            let dest = DisketteEngine.Volume.join(currentPath, url.lastPathComponent)
            try DisketteEngine.importHostFile(into: volume, from: url, destPath: dest, overwrite: true)
        }
    }

    private func extractSelection() {
        extractPaths(Array(selection))
    }

    private func extractPaths(_ rawPaths: [String]) {
        // Prefer parents when both parent and child are selected
        let paths = collapseToRoots(rawPaths)
        guard !paths.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.allowedContentTypes = [.folder]
        panel.message = "Extract selected items to…"
        panel.prompt = "Extract"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        var count = 0
        for p in paths {
            do {
                try DisketteEngine.extract(from: volume, path: p, toHostDirectory: dest)
                count += 1
            } catch {
                onStatus("Extract failed: \(error.localizedDescription)")
                return
            }
        }
        onStatus("Extracted \(count) item\(count == 1 ? "" : "s") → \(dest.lastPathComponent)")
    }

    private func extractOne(_ entry: DisketteEngine.Entry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        panel.message = "Extract file from disc"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            let data = try volume.readFile(at: entry.path)
            try data.write(to: dest, options: .atomic)
            onStatus("Extracted \(entry.name)")
        } catch {
            onStatus("Extract failed: \(error.localizedDescription)")
        }
    }

    private func deleteSelection() {
        deletePaths(Array(selection))
    }

    private func deletePaths(_ rawPaths: [String]) {
        // Delete deepest paths first; skip children if a parent is also selected.
        let paths = collapseToRoots(rawPaths).sorted {
            $0.split(separator: "/").count > $1.split(separator: "/").count
        }
        guard !paths.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = paths.count == 1
            ? "Delete “\((paths[0] as NSString).lastPathComponent)”?"
            : "Delete \(paths.count) items?"
        alert.informativeText = "Items are removed from the virtual disc. Save the disc to keep the change."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var deleted = 0
        for p in paths {
            do {
                try volume.remove(at: p)
                deleted += 1
            } catch DisketteEngine.EngineError.fileNotFound {
                // Already removed as part of a parent folder
                continue
            } catch {
                onStatus("Delete failed: \(error.localizedDescription)")
                return
            }
        }
        selection.removeAll()
        onDirty()
        onStatus("Deleted \(deleted) item\(deleted == 1 ? "" : "s")")
    }

    /// Drop child paths when an ancestor is also selected.
    private func collapseToRoots(_ paths: [String]) -> [String] {
        let unique = Array(Set(paths)).sorted()
        var roots: [String] = []
        for p in unique {
            let covered = roots.contains { root in
                p == root || p.hasPrefix(root == "/" ? "/" : root + "/")
            }
            if !covered { roots.append(p) }
        }
        return roots
    }

    private func promptRename() {
        guard let path = renamePath else { return }
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "New name for \((path as NSString).lastPathComponent)"
        let field = NSTextField(string: renameText)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else {
            renamePath = nil
            return
        }
        let rawName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = DisketteEngine.Volume.sanitizeNameComponent(rawName)
        guard !newName.isEmpty else { return }
        if newName != rawName {
            onStatus("Name sanitized to “\(newName)”")
        }
        let parent = (path as NSString).deletingLastPathComponent
        let dest = DisketteEngine.Volume.join(parent.isEmpty ? "/" : parent, newName)
        do {
            try volume.rename(from: path, to: dest)
            selection = [dest]
            onDirty()
            onStatus("Renamed → \(newName)")
        } catch {
            onStatus("Rename failed: \(error.localizedDescription)")
        }
        renamePath = nil
    }

    private func createFolder() {
        let name = DisketteEngine.Volume.sanitizeNameComponent(newFolderName)
        guard !name.isEmpty else { return }
        let path = DisketteEngine.Volume.join(currentPath, name)
        do {
            try volume.addDirectory(at: path)
            onDirty()
            onStatus("Created folder \(name)")
        } catch {
            onStatus("Folder failed: \(error.localizedDescription)")
        }
    }

    private func iconName(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "tiff", "heic": return "photo"
        case "txt", "md", "text", "log": return "doc.text"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz": return "doc.zipper"
        case "swift", "py", "js", "ts", "c", "h", "rs", "go": return "chevron.left.forwardslash.chevron.right"
        case "mp3", "wav", "aiff", "m4a": return "waveform"
        case "mp4", "mov": return "film"
        default: return "doc"
        }
    }
}
