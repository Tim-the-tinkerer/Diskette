import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum AppTheme {
    static let accent = Color(red: 0.28, green: 0.48, blue: 0.82)
    static let accentSoft = Color(red: 0.28, green: 0.48, blue: 0.82).opacity(0.14)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let paper = Color(nsColor: .windowBackgroundColor)
    static let shell = Color(red: 0.14, green: 0.15, blue: 0.20)
}

struct ContentView: View {
    @StateObject private var session = DriveSession()
    @State private var mode: WorkMode = .drive
    @State private var statusMessage: String?
    @State private var currentPath = "/"
    @State private var newLabel = "Untitled"
    @State private var newMedia: DisketteEngine.Media = .hd1440
    @State private var showNewDiscSheet = false
    @State private var windowDropTargeted = false

    private enum WorkMode: String, CaseIterable, Identifiable {
        case drive = "Drive"
        case format = "Format"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            mainPane
            Divider()
            footer
        }
        .frame(minWidth: 920, minHeight: 620)
        .background(AppTheme.paper)
        .onAppear {
            let session = self.session
            DocumentCloseBridge.isDirty = {
                session.volume?.isDirty == true
            }
            DocumentCloseBridge.saveMountedDisc = {
                // Save without relying on View identity; use session volume directly.
                guard let volume = session.volume else { return true }
                if let url = volume.sourceURL {
                    do {
                        try DisketteEngine.save(volume, to: url)
                        return true
                    } catch {
                        let alert = NSAlert(error: error)
                        alert.runModal()
                        return false
                    }
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = DisketteEngine.exportContentTypes
                panel.nameFieldStringValue = DisketteEngine.suggestedFilename(stem: volume.label)
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return false }
                let dest = url.pathExtension.lowercased() == DisketteEngine.fileExtension.lowercased()
                    ? url
                    : url.appendingPathExtension(DisketteEngine.fileExtension)
                do {
                    try DisketteEngine.save(volume, to: dest)
                    return true
                } catch {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                    return false
                }
            }
            consumePendingOpens()
        }
        .onReceive(NotificationCenter.default.publisher(for: OpenFileBridge.flushNotification)) { _ in
            consumePendingOpens()
        }
        .sheet(isPresented: $showNewDiscSheet) {
            newDiscSheet
        }
        .onChange(of: session.volume?.id) { _ in
            currentPath = "/"
        }
        // Window-level drop: read URLs from the drag pasteboard synchronously (providers
        // often go stale if loading is deferred in a Task after the drop ends).
        .onDrop(of: [.fileURL], isTargeted: $windowDropTargeted) { _ in
            let urls = Self.fileURLsFromDragPasteboard()
            guard !urls.isEmpty else { return false }
            Task { @MainActor in
                handleDroppedURLs(urls)
            }
            return true
        }
        .overlay {
            if windowDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(AppTheme.accent, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(AppTheme.accentSoft)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diskette")
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Picker("Mode", selection: $mode) {
                    ForEach(WorkMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .labelsHidden()
            }

            if mode == .drive {
                HStack(spacing: 8) {
                    Button {
                        showNewDiscSheet = true
                    } label: {
                        Label("New Disc", systemImage: "plus.rectangle.on.folder")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)

                    Button {
                        openDisc()
                    } label: {
                        Label("Open…", systemImage: "folder")
                    }

                    Button {
                        spanFolder()
                    } label: {
                        Label("Span Folder…", systemImage: "externaldrive.badge.plus")
                    }
                    .help("Pack a large folder across multiple virtual floppies (chunks oversized files)")

                    Button {
                        unspanSet()
                    } label: {
                        Label("Restore Set…", systemImage: "arrow.triangle.merge")
                    }
                    .help("Reassemble a multi-disc span set into a folder")

                    Button {
                        recoverMissingDisc()
                    } label: {
                        Label("Recover Missing Disc…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("Rebuild lost data disc(s) using Recovery disc(s) — XOR (1) or Reed–Solomon (2+)")

                    if session.volume != nil {
                        Button {
                            repairLayoutOnMountedDisc()
                        } label: {
                            Label("Repair Layout…", systemImage: "wrench.and.screwdriver")
                        }
                        .help("Opt-in: move Dir-name files into sibling Dir/ (join-bug heuristic only)")

                        Button {
                            saveDisc()
                        } label: {
                            Label(session.volume?.isDirty == true ? "Save…" : "Save", systemImage: "square.and.arrow.down")
                        }
                        .disabled(session.volume == nil)

                        Button {
                            saveDiscAs()
                        } label: {
                            Text("Save As…")
                        }

                        Button(role: .destructive) {
                            ejectDisc()
                        } label: {
                            Label("Eject", systemImage: "eject")
                        }
                    }

                    Spacer()

                    if let v = session.volume {
                        Text(v.sourceURL?.lastPathComponent ?? "(unsaved)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if v.isDirty {
                            Text("• Modified")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.orange)
                        }
                    }
                }
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        switch mode {
        case .drive:
            if let v = session.volume {
                return "Mounted: \(v.label) · \(v.media.displayName) · open in this window"
            }
            return "Create or open a .Floppy container — browse it here, no mount required"
        case .format:
            return "FLOP/2 binary · multi-disc span · XOR / Reed–Solomon recovery · CRC integrity"
        }
    }

    // MARK: - Main

    @ViewBuilder
    private var mainPane: some View {
        switch mode {
        case .drive:
            drivePane
        case .format:
            formatPane
        }
    }

    @ViewBuilder
    private var drivePane: some View {
        if let volume = session.volume {
            MountedDriveView(
                volume: volume,
                currentPath: $currentPath,
                statusMessage: $statusMessage
            )
        } else {
            emptyDrive
        }
    }

    private var emptyDrive: some View {
        VStack(spacing: 20) {
            ZStack {
                FloppyVisual(media: newMedia, label: "Insert disc", fillFraction: 0)
                    .frame(width: 180, height: 180)
                    .opacity(0.85)
            }

            Text("No disc in drive")
                .font(.title2.weight(.semibold))
            Text("Create a virtual floppy, open a .\(DisketteEngine.fileExtension), or drop one here.\nDrop files onto a mounted disc to copy them in; drag disc items out to Finder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button {
                    showNewDiscSheet = true
                } label: {
                    Label("New Disc", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .controlSize(.large)

                Button {
                    openDisc()
                } label: {
                    Label("Open Disc…", systemImage: "folder")
                }
                .controlSize(.large)
            }

            // Quick media picker for “feel”
            Picker("Default media", selection: $newMedia) {
                ForEach(DisketteEngine.Media.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .frame(maxWidth: 280)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        // Window-level drop handler covers empty state as well.
    }

    /// Prefer drag pasteboard file URLs (reliable) over deferred NSItemProvider loads.
    private static func fileURLsFromDragPasteboard() -> [URL] {
        let pb = NSPasteboard(name: .drag)
        let classes: [AnyClass] = [NSURL.self]
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        guard let objects = pb.readObjects(forClasses: classes, options: options) else {
            return []
        }
        var seen = Set<String>()
        var urls: [URL] = []
        for obj in objects {
            guard let url = obj as? URL else { continue }
            if seen.insert(url.path).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    @MainActor
    private func handleDroppedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else {
            statusMessage = "Drop failed — could not read files"
            NSSound.beep()
            return
        }

        let floppies = urls.filter { DisketteEngine.isFloppyFilename($0) }
        let others = urls.filter { !DisketteEngine.isFloppyFilename($0) }

        if let floppy = floppies.first {
            openURL(floppy)
            if floppies.count > 1 {
                statusMessage = "Opened \(floppy.lastPathComponent) (first of \(floppies.count) discs dropped)"
            }
            return
        }

        // No disc mounted: a single dropped folder → offer to span it.
        if session.volume == nil, others.count == 1 {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: others[0].path, isDirectory: &isDir), isDir.boolValue {
                spanFolder(preselected: others[0])
                return
            }
        }

        guard let volume = session.volume else {
            statusMessage = "No disc mounted — drop a .\(DisketteEngine.fileExtension) to open, drop a folder to span, or create a new disc"
            NSSound.beep()
            return
        }

        mode = .drive
        var added = 0
        var failed = 0
        DragDropSupport.withSecurityScopedAccess(to: others) { scoped in
            for url in scoped {
                do {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    if isDir.boolValue {
                        let dest = DisketteEngine.Volume.join(currentPath, url.lastPathComponent)
                        try DisketteEngine.importHostFolder(into: volume, from: url, destDir: dest)
                    } else {
                        let dest = DisketteEngine.Volume.join(currentPath, url.lastPathComponent)
                        try DisketteEngine.importHostFile(into: volume, from: url, destPath: dest, overwrite: true)
                    }
                    added += 1
                } catch {
                    failed += 1
                    statusMessage = "Add failed: \(error.localizedDescription)"
                }
            }
        }
        if added > 0 {
            if failed == 0 {
                statusMessage = "Added \(added) item\(added == 1 ? "" : "s") from drop — save the disc to keep changes"
            } else {
                statusMessage = "Added \(added), failed \(failed)"
            }
        } else if failed > 0 {
            NSSound.beep()
        }
    }

    private var newDiscSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Format New Disc")
                .font(.headline)
            Text("Creates an empty virtual floppy container. Capacity is fixed like real media.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Volume label", text: $newLabel)
                .textFieldStyle(.roundedBorder)

            Picker("Media", selection: $newMedia) {
                ForEach(DisketteEngine.Media.allCases) { m in
                    Text("\(m.displayName) — \(DisketteEngine.formatBytes(m.capacity))").tag(m)
                }
            }

            HStack {
                FloppyVisual(media: newMedia, label: newLabel, fillFraction: 0, compact: true)
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(newMedia.formFactor == .threeHalf ? "3.5-inch form factor" : "5.25-inch form factor")
                        .font(.caption.weight(.medium))
                    Text("\(newMedia.capacity / DisketteEngine.sectorSize) sectors · \(DisketteEngine.sectorSize)-byte")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.card))

            HStack {
                Spacer()
                Button("Cancel") { showNewDiscSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    createNewDisc()
                    showNewDiscSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private var formatPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("FLOP packaging") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Default save: FLOP/2 binary (raw payloads + optional zlib) — no base64 overhead.")
                        Text("Legacy: FLOP/1 text (UTF-8 + base64) still opens; Save can keep text or upgrade to binary.")
                        Text("Extension: .\(DisketteEngine.fileExtension) · Magics: FLP2 · \(DisketteEngine.magic)")
                            .font(.body.monospaced())
                        Text("Logical capacity counts uncompressed file bytes; on-disk size depends on packaging and zlib.")
                            .foregroundStyle(.secondary)
                        Text("Sidebar Compress reflects the mounted disc’s FLOP/2 header (not a silent default).")
                            .foregroundStyle(.secondary)
                        Text("Not encryption — multi-file storage with classic capacity limits and CRC-32.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("Integrity") {
                    VStack(alignment: .leading, spacing: 6) {
                        labeledRow("File CRC", "CRC-32 of each logical (uncompressed) payload")
                        labeledRow("Volume", "volume_crc over the sorted directory digest; verified on load")
                        labeledRow("Span", "Part CRC + full-file CRC when chunking; checked on restore")
                        labeledRow("Damage", "CRC detects corruption; it does not repair. No parity inside a single data disc.")
                        labeledRow("Layout", "Repair Layout… / --repair-layout is opt-in only (join-bug heuristic)")
                    }
                    .padding(4)
                }

                GroupBox("Media capacities") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(DisketteEngine.Media.allCases) { m in
                            HStack {
                                Text(m.displayName)
                                Spacer()
                                Text("\(m.capacity) bytes")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(m.shortName)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(AppTheme.accentSoft))
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                    }
                    .padding(4)
                }

                GroupBox("Multi-disc span") {
                    VStack(alignment: .leading, spacing: 6) {
                        labeledRow("Span", "Span Folder… packs a host folder across numbered .Floppy discs")
                        labeledRow("Chunking", "Files larger than one disc split under /.diskette-span/parts/")
                        labeledRow("Manifest", "/.diskette-span/manifest.json on every data disc (DISKETTE-SPAN/2)")
                        labeledRow("Streaming", "Host files CRC’d and sliced from disk — not all held in RAM")
                        labeledRow("Hidden", "Host dotfiles skipped; empty directories preserved")
                        labeledRow("Restore", "Restore Set… needs a complete set; collision fail / overwrite / skip")
                        labeledRow("Warning", "Do not delete or rename /.diskette-span on a span disc")
                    }
                    .padding(4)
                }

                GroupBox("Recovery discs (optional)") {
                    VStack(alignment: .leading, spacing: 6) {
                        labeledRow("Create", "Span dialog: None · 1 XOR · 2–8 Reed–Solomon")
                        labeledRow("XOR (1)", "stem-Recovery-01of01.Floppy — rebuild any one lost data disc")
                        labeledRow("RS (N)", "stem-Recovery-JJofNN.Floppy — rebuild up to N lost data discs")
                        labeledRow("Coding", "XOR of disc images, or Cauchy RS over GF(256) on equal-sized blocks")
                        labeledRow("Recover", "Recover Missing Disc… with recovery disc(s) + survivors")
                        labeledRow("Limit", "Protects against at most N losses; not full PAR2 for arbitrary files")
                        Text("Paths: /.diskette-span/recovery/manifest.json · parity.bin")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    .padding(4)
                }

                GroupBox("In-app drive") {
                    VStack(alignment: .leading, spacing: 6) {
                        labeledRow("Open disc", "Double-click a .Floppy, Open…, or drop a disc — mounts in Diskette")
                        labeledRow("Browse", "Folder navigation; multi-select; double-click folders to enter")
                        labeledRow("Open file", "Double-click a file → default macOS app (temp read-only copy)")
                        labeledRow("Quick Look", "Toolbar eye or context menu — system QLPreviewPanel")
                        labeledRow("Drop in", "Drop .Floppy to open; drop files/folders onto a mounted disc to add")
                        labeledRow("Drag out", "Drag the ⋮⋮ handle to Finder (multi-select exports a folder)")
                        labeledRow("Add", "Add… button or drop from Finder (folder trees preserved)")
                        labeledRow("Extract", "Copy selected items back to the Mac (structure preserved)")
                        labeledRow("Repair", "Repair Layout… — opt-in join-bug fix; Save to persist")
                        labeledRow("Span", "Span Folder… — multi-disc; chunks + streaming; optional recovery")
                        labeledRow("Recover", "Recover Missing Disc… — XOR / Reed–Solomon rebuild")
                        labeledRow("Restore", "Restore Set… — merge discs, rejoin chunks; collision prompt")
                        labeledRow("Save", "Write the .Floppy container (Save / Save As); prompted if dirty")
                    }
                    .padding(4)
                }

                GroupBox("CLI") {
                    Text(
                        """
                        Diskette --self-test
                        Diskette --create -o blank.Floppy --media 1.44 --label "My Disc"
                        Diskette --list disc.Floppy
                        Diskette --add disc.Floppy ./photo.png --path /photo.png
                        Diskette --extract disc.Floppy /photo.png -o ./out
                        Diskette --repair-layout disc.Floppy
                        Diskette --span ./BigFolder -o ~/Discs --media 1.44 --recovery-discs 3
                        Diskette --recover-disc ~/Discs -o ~/Discs
                        Diskette --unspan-dir ~/Discs -o ~/Restored
                        """
                    )
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("Reference") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Full on-disk layout, span manifests, and recovery math: FORMAT.md in the project.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("App \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") · macOS 13+")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            .padding(20)
        }
    }

    private func labeledRow(_ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(width: 72, alignment: .leading)
                .foregroundStyle(AppTheme.accent)
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("FLOP/2 · span · XOR/RS recovery · open in-app")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let v = session.volume {
                Text("\(DisketteEngine.formatBytes(v.usedBytes)) / \(DisketteEngine.formatBytes(v.capacity))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func createNewDisc() {
        if session.volume?.isDirty == true {
            let alert = NSAlert()
            alert.messageText = "Replace current disc?"
            alert.informativeText = "The mounted disc has unsaved changes."
            alert.addButton(withTitle: "Save First")
            alert.addButton(withTitle: "Discard & Format")
            alert.addButton(withTitle: "Cancel")
            let r = alert.runModal()
            if r == .alertFirstButtonReturn {
                switch saveDisc() {
                case .saved: break
                case .cancelled, .failed: return
                }
            } else if r == .alertThirdButtonReturn {
                return
            }
        } else if session.volume != nil {
            // Clean mounted disc — still confirm replace
            let alert = NSAlert()
            alert.messageText = "Replace current disc?"
            alert.informativeText = "Format a new blank disc and eject the one currently mounted?"
            alert.addButton(withTitle: "Format New")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        if let id = session.volume?.id {
            DiscFileOpener.cleanup(volumeId: id)
        }
        let vol = DisketteEngine.create(label: newLabel, media: newMedia)
        session.mount(vol)
        currentPath = "/"
        statusMessage = "Formatted blank \(newMedia.displayName) — “\(vol.label)”"
    }

    /// Configure an open panel that can select normal folders (not restricted to .Floppy docs).
    private func makeFolderPicker(message: String, prompt: String, canCreate: Bool) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = canCreate
        panel.treatsFilePackagesAsDirectories = true
        panel.resolvesAliases = true
        panel.message = message
        panel.prompt = prompt
        // Without this, document-based apps often only surface registered file types
        // and folder selection appears broken or greyed out.
        panel.allowedContentTypes = [.folder]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        return panel
    }

    /// Pack a host folder across multiple virtual floppies (whole files + chunking).
    private func spanFolder(preselected: URL? = nil) {
        let folder: URL
        if let preselected {
            folder = preselected
        } else {
            let open = makeFolderPicker(
                message: "Choose a folder to span across virtual floppies",
                prompt: "Choose Folder",
                canCreate: false
            )
            guard open.runModal() == .OK, let picked = open.url else { return }
            folder = picked
        }

        // Ensure we got a directory (some panels can still return a file in edge cases).
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            statusMessage = "Please choose a folder, not a file"
            NSSound.beep()
            return
        }

        let mediaAlert = NSAlert()
        mediaAlert.messageText = "Span media size"
        mediaAlert.informativeText =
            "Large folders use multiple discs; oversized files are chunked. "
            + "Hidden files (dotfiles) are skipped. Empty folders are preserved. "
            + "Source data is streamed (not all loaded into memory)."
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 86))
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 56, width: 360, height: 24), pullsDown: false)
        for m in DisketteEngine.Media.allCases {
            pop.addItem(withTitle: "\(m.displayName) — \(DisketteEngine.formatBytes(m.capacity))")
            pop.lastItem?.representedObject = m.rawValue
        }
        if let idx = DisketteEngine.Media.allCases.firstIndex(of: newMedia) {
            pop.selectItem(at: idx)
        }
        let recoveryLabel = NSTextField(labelWithString: "Recovery discs:")
        recoveryLabel.frame = NSRect(x: 0, y: 28, width: 110, height: 22)
        let recoveryPop = NSPopUpButton(frame: NSRect(x: 112, y: 26, width: 248, height: 24), pullsDown: false)
        recoveryPop.addItem(withTitle: "None")
        recoveryPop.lastItem?.tag = 0
        recoveryPop.addItem(withTitle: "1 — XOR (rebuild any 1 lost disc)")
        recoveryPop.lastItem?.tag = 1
        for n in 2...min(8, SpanSet.maxRecoveryDiscs) {
            recoveryPop.addItem(withTitle: "\(n) — Reed–Solomon (rebuild up to \(n) losses)")
            recoveryPop.lastItem?.tag = n
        }
        recoveryPop.selectItem(at: 0)
        let recoveryHint = NSTextField(
            wrappingLabelWithString: "Recovery discs are extra floppies kept with the set."
        )
        recoveryHint.frame = NSRect(x: 0, y: 2, width: 360, height: 22)
        recoveryHint.font = NSFont.systemFont(ofSize: 11)
        recoveryHint.textColor = .secondaryLabelColor
        accessory.addSubview(pop)
        accessory.addSubview(recoveryLabel)
        accessory.addSubview(recoveryPop)
        accessory.addSubview(recoveryHint)
        mediaAlert.accessoryView = accessory
        mediaAlert.addButton(withTitle: "Continue")
        mediaAlert.addButton(withTitle: "Cancel")
        guard mediaAlert.runModal() == .alertFirstButtonReturn else { return }
        let mediaRaw = (pop.selectedItem?.representedObject as? String) ?? DisketteEngine.Media.default.rawValue
        let media = DisketteEngine.Media.parse(mediaRaw) ?? .default
        let recoveryDiscCount = recoveryPop.selectedItem?.tag ?? 0

        let save = makeFolderPicker(
            message: "Choose output folder for span discs (\(media.shortName))",
            prompt: "Save Discs Here",
            canCreate: true
        )
        guard save.runModal() == .OK, let outDir = save.url else { return }

        do {
            let result = try SpanSet.spanFolder(
                at: folder,
                outputDirectory: outDir,
                media: media,
                setLabel: folder.lastPathComponent,
                packaging: .binary,
                compress: true,
                recoveryDiscCount: recoveryDiscCount
            )
            let chunkNote = result.chunkedFiles > 0 ? " · \(result.chunkedFiles) chunked" : ""
            let recNote = result.recoveryURLs.isEmpty
                ? ""
                : " + \(result.recoveryURLs.count) recovery"
            statusMessage =
                "Spanned \(result.totalFiles) files (\(DisketteEngine.formatBytes(result.totalBytes)))"
                + "\(chunkNote) → \(result.discURLs.count) disc(s)\(recNote) in \(outDir.lastPathComponent)"
            // Mount first disc for inspection
            if let first = result.discURLs.first {
                openURL(first)
            }
            let note = NSAlert()
            note.messageText = "Span complete"
            var names = result.discURLs.map(\.lastPathComponent)
            names.append(contentsOf: result.recoveryURLs.map(\.lastPathComponent))
            var body =
                "Created \(result.discURLs.count) data disc(s)"
                + (result.chunkedFiles > 0 ? " (\(result.chunkedFiles) file(s) split across discs)" : "")
                + " in \(outDir.lastPathComponent):\n\n"
                + Self.truncatedNameList(names, limit: 8)
            if result.recoveryURLs.count == 1 {
                body +=
                    "\n\nXOR recovery disc can rebuild any one missing data disc "
                    + "(Recover Missing Disc…)."
            } else if result.recoveryURLs.count > 1 {
                body +=
                    "\n\n\(result.recoveryURLs.count) Reed–Solomon recovery discs can rebuild up to "
                    + "\(result.recoveryURLs.count) missing data discs (Recover Missing Disc…)."
            }
            body += "\n\nUse Restore Set… and select all data discs to reassemble."
            note.informativeText = body
            note.alertStyle = .informational
            note.addButton(withTitle: "OK")
            note.runModal()
        } catch {
            statusMessage = "Span failed: \(error.localizedDescription)"
            NSSound.beep()
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    /// Compact multi-line name list for alerts (avoids floor-to-ceiling dialogs).
    /// When truncated, keeps the first few names and the last so numbered span sets stay readable.
    private static func truncatedNameList(_ names: [String], limit: Int) -> String {
        guard !names.isEmpty else { return "(none)" }
        guard names.count > limit, limit >= 3 else {
            return names.joined(separator: "\n")
        }
        // head … and N more … last
        let headCount = limit - 2
        let head = names.prefix(headCount)
        let last = names.last!
        let omitted = names.count - headCount - 1
        return (Array(head) + ["… and \(omitted) more …", last]).joined(separator: "\n")
    }

    /// Rebuild missing span data disc(s) from XOR / Reed–Solomon recovery disc(s).
    private func recoverMissingDisc() {
        let open = NSOpenPanel()
        open.allowedContentTypes = DisketteEngine.importContentTypes
        open.allowsMultipleSelection = true
        open.canChooseDirectories = true
        open.canChooseFiles = true
        open.message =
            "Select Recovery disc(s) and remaining data discs (or a folder containing them)"
        open.prompt = "Recover"
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }

        var candidates: [URL] = []
        for url in open.urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let kids = try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil
                ) {
                    candidates.append(contentsOf: kids.filter { DisketteEngine.isFloppyFilename($0) })
                }
            } else if DisketteEngine.isFloppyFilename(url) {
                candidates.append(url)
            }
        }
        candidates = Array(Set(candidates.map(\.standardizedFileURL)))

        let hasRecovery = candidates.contains { url in
            if let vol = try? DisketteEngine.load(from: url) {
                return SpanSet.isRecoveryVolume(vol)
            }
            return false
        }
        guard hasRecovery else {
            statusMessage = "No Recovery disc found (need *-Recovery-…Floppy)"
            NSSound.beep()
            return
        }

        let save = makeFolderPicker(
            message: "Choose folder for reconstructed data disc(s)",
            prompt: "Save Rebuilt Discs Here",
            canCreate: true
        )
        guard save.runModal() == .OK, let outDir = save.url else { return }

        do {
            let batch = try SpanSet.reconstructMissingDiscs(
                availableDiscURLs: candidates,
                outputURL: outDir
            )
            let names = batch.results.map(\.missingFilename).joined(separator: ", ")
            statusMessage =
                "Recovered \(batch.results.count) disc(s) [\(batch.scheme.rawValue)]: \(names)"
            NSWorkspace.shared.activateFileViewerSelecting(batch.results.map(\.reconstructedURL))
            let note = NSAlert()
            note.messageText = batch.results.count == 1 ? "Disc recovered" : "Discs recovered"
            let list = batch.results.map {
                "• \($0.missingFilename) (disc \($0.missingIndex), \(DisketteEngine.formatBytes($0.byteLength)))"
            }.joined(separator: "\n")
            note.informativeText =
                "Scheme: \(batch.scheme.rawValue)\n\n\(list)\n\n"
                + "Add rebuilt disc(s) back to the set, then use Restore Set… with all data discs."
            note.alertStyle = .informational
            note.addButton(withTitle: "OK")
            note.runModal()
        } catch {
            statusMessage = "Recover failed: \(error.localizedDescription)"
            NSSound.beep()
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    /// Restore a multi-disc span set to a host folder.
    private func unspanSet() {
        let open = NSOpenPanel()
        open.allowedContentTypes = DisketteEngine.importContentTypes
        open.allowsMultipleSelection = true
        open.canChooseDirectories = true
        open.canChooseFiles = true
        open.message = "Select all span discs, or a folder containing them"
        open.prompt = "Restore"
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }

        let save = makeFolderPicker(
            message: "Choose folder for restored content (creates the set’s root folder inside)",
            prompt: "Restore Here",
            canCreate: true
        )
        guard save.runModal() == .OK, let outDir = save.url else { return }

        // Collision policy if root will already exist — determined after we know root name is hard;
        // default fail; offer overwrite via alert when destinationExists is thrown, and retry.
        var collision: SpanSet.CollisionPolicy = .fail

        do {
            func runUnspan() throws -> SpanSet.UnspanResult {
                if open.urls.count == 1 {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: open.urls[0].path, isDirectory: &isDir),
                       isDir.boolValue {
                        return try SpanSet.unspanDirectory(
                            open.urls[0],
                            outputDirectory: outDir,
                            collision: collision
                        )
                    }
                }
                let discs = open.urls.filter { DisketteEngine.isFloppyFilename($0) }
                guard !discs.isEmpty else {
                    throw SpanSet.SpanError.notASpanDisc("(no .Floppy selected)")
                }
                return try SpanSet.unspan(discURLs: discs, outputDirectory: outDir, collision: collision)
            }

            let result: SpanSet.UnspanResult
            do {
                result = try runUnspan()
            } catch SpanSet.SpanError.destinationExists(let path) {
                let alert = NSAlert()
                alert.messageText = "Destination already exists"
                alert.informativeText = "\(path)\n\nOverwrite existing files, skip existing, or cancel?"
                alert.addButton(withTitle: "Overwrite")
                alert.addButton(withTitle: "Skip Existing")
                alert.addButton(withTitle: "Cancel")
                let r = alert.runModal()
                if r == .alertFirstButtonReturn {
                    collision = .overwrite
                } else if r == .alertSecondButtonReturn {
                    collision = .skip
                } else {
                    statusMessage = "Restore cancelled"
                    return
                }
                result = try runUnspan()
            }
            let chunkNote = result.chunkedFiles > 0 ? " · \(result.chunkedFiles) rejoined" : ""
            statusMessage =
                "Restored \(result.filesRestored) files (\(DisketteEngine.formatBytes(result.bytesRestored)))"
                + "\(chunkNote) from \(result.discCount) disc(s) → \(result.outputRoot.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([result.outputRoot])
        } catch {
            statusMessage = "Restore failed: \(error.localizedDescription)"
            NSSound.beep()
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private func openDisc() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DisketteEngine.importContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Open a virtual floppy container"
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openURL(url)
    }

    /// Explicit join-bug layout repair — never runs on open/extract by itself.
    private func repairLayoutOnMountedDisc() {
        guard let volume = session.volume else { return }
        let alert = NSAlert()
        alert.messageText = "Repair flattened folder layout?"
        alert.informativeText =
            "Moves files named like “Folder-name” next to a sibling folder “Folder” into “Folder/name”.\n\n"
            + "This is a heuristic for discs written by a short-lived import bug. "
            + "Legitimate names (e.g. Reports-summary.txt beside a Reports folder) will also be moved.\n\n"
            + "Nothing is written until you Save."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Repair")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let moved = try volume.repairFlattenedFolderImports()
            if moved == 0 {
                statusMessage = "Repair Layout: no matching paths found"
            } else {
                statusMessage = "Repair Layout: moved \(moved) file(s) — Save to keep"
                currentPath = "/"
            }
        } catch {
            statusMessage = "Repair Layout failed: \(error.localizedDescription)"
            NSSound.beep()
        }
    }

    /// Result of a save attempt — callers must not eject/replace unless `.saved`.
    private enum SaveResult: Equatable {
        case saved
        case cancelled
        case failed(String)
    }

    private func openURL(_ url: URL) {
        if DisketteEngine.isFloppyFilename(url) {
            if session.volume?.isDirty == true {
                let alert = NSAlert()
                alert.messageText = "Save current disc?"
                alert.informativeText = "The mounted disc has unsaved changes."
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Don’t Save")
                alert.addButton(withTitle: "Cancel")
                let r = alert.runModal()
                if r == .alertFirstButtonReturn {
                    switch saveDisc() {
                    case .saved:
                        break
                    case .cancelled:
                        return
                    case .failed(let msg):
                        statusMessage = "Save failed: \(msg) — disc not replaced"
                        NSSound.beep()
                        return
                    }
                } else if r == .alertThirdButtonReturn {
                    return
                }
            }
            do {
                let vol = try DisketteEngine.load(from: url)
                if let id = session.volume?.id {
                    DiscFileOpener.cleanup(volumeId: id)
                }
                session.mount(vol)
                currentPath = "/"
                mode = .drive
                let pkg = vol.loadedFromText ? "FLOP/1 text → will save as \(vol.packaging.shortName)" : vol.packaging.shortName
                statusMessage =
                    "Opened \(url.lastPathComponent) — \(vol.fileCount) file(s), "
                    + "\(DisketteEngine.formatBytes(vol.usedBytes)) used · \(pkg)"
            } catch {
                statusMessage = "Open failed: \(error.localizedDescription)"
                NSSound.beep()
            }
        } else if let volume = session.volume {
            // Import host file into mounted disc
            do {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    let dest = DisketteEngine.Volume.join(currentPath, url.lastPathComponent)
                    try DisketteEngine.importHostFolder(into: volume, from: url, destDir: dest)
                } else {
                    let dest = DisketteEngine.Volume.join(currentPath, url.lastPathComponent)
                    try DisketteEngine.importHostFile(into: volume, from: url, destPath: dest, overwrite: true)
                }
                statusMessage = "Added \(url.lastPathComponent)"
            } catch {
                statusMessage = "Add failed: \(error.localizedDescription)"
            }
        } else {
            statusMessage = "Not a .\(DisketteEngine.fileExtension) file — open or create a disc first"
        }
    }

    @discardableResult
    private func saveDisc() -> SaveResult {
        guard let volume = session.volume else {
            return .failed("No disc mounted")
        }
        if let url = volume.sourceURL {
            do {
                try DisketteEngine.save(volume, to: url)
                statusMessage = "Saved \(url.lastPathComponent)"
                return .saved
            } catch {
                statusMessage = "Save failed: \(error.localizedDescription)"
                NSSound.beep()
                return .failed(error.localizedDescription)
            }
        }
        return saveDiscAs()
    }

    @discardableResult
    private func saveDiscAs() -> SaveResult {
        guard let volume = session.volume else {
            return .failed("No disc mounted")
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = DisketteEngine.exportContentTypes
        panel.nameFieldStringValue = DisketteEngine.suggestedFilename(stem: volume.label)
        panel.canCreateDirectories = true
        panel.message = "Save virtual floppy container"
        guard panel.runModal() == .OK, let url = panel.url else {
            statusMessage = "Save cancelled"
            return .cancelled
        }
        let dest = url.pathExtension.lowercased() == DisketteEngine.fileExtension.lowercased()
            ? url
            : url.appendingPathExtension(DisketteEngine.fileExtension)
        do {
            try DisketteEngine.save(volume, to: dest)
            statusMessage = "Saved \(dest.lastPathComponent)"
            return .saved
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
            NSSound.beep()
            return .failed(error.localizedDescription)
        }
    }

    private func ejectDisc() {
        if session.volume?.isDirty == true {
            let alert = NSAlert()
            alert.messageText = "Eject without saving?"
            alert.informativeText = "The disc has unsaved changes."
            alert.addButton(withTitle: "Save & Eject")
            alert.addButton(withTitle: "Eject")
            alert.addButton(withTitle: "Cancel")
            let r = alert.runModal()
            if r == .alertFirstButtonReturn {
                switch saveDisc() {
                case .saved:
                    break
                case .cancelled:
                    return
                case .failed:
                    // Keep disc mounted so the user can retry or choose Eject without save.
                    return
                }
            } else if r == .alertThirdButtonReturn {
                return
            }
        }
        performEject(status: "Disc ejected")
    }

    private func performEject(status: String) {
        if let id = session.volume?.id {
            DiscFileOpener.cleanup(volumeId: id)
        }
        session.eject()
        currentPath = "/"
        statusMessage = status
    }

    private func consumePendingOpens() {
        let urls = OpenFileBridge.drain()
        for url in urls {
            openURL(url)
        }
    }

}

/// Owns the currently mounted volume for the session.
@MainActor
final class DriveSession: ObservableObject {
    @Published var volume: DisketteEngine.Volume?
    /// Bumps when the mounted volume mutates so the header (dirty badge, Save title) refreshes.
    @Published private(set) var volumeRevision: UInt64 = 0

    private var volumeWatch: AnyCancellable?

    func mount(_ v: DisketteEngine.Volume) {
        volumeWatch?.cancel()
        volume = v
        // Forward in-volume edits (add/delete/label) so ContentView header stays in sync.
        volumeWatch = v.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.volumeRevision &+= 1
            self.objectWillChange.send()
        }
        volumeRevision &+= 1
    }

    func eject() {
        volumeWatch?.cancel()
        volumeWatch = nil
        volume = nil
        volumeRevision &+= 1
    }
}

/// Separate view so `@ObservedObject` tracks volume mutations (capacity, files, dirty).
private struct MountedDriveView: View {
    @ObservedObject var volume: DisketteEngine.Volume
    @Binding var currentPath: String
    @Binding var statusMessage: String?

    private func containerSizeLabel(_ volume: DisketteEngine.Volume) -> String {
        // Never full-serialize on redraw — that blocked the main thread and made
        // selection/navigation feel broken on discs with real payload.
        if !volume.isDirty, let url = volume.sourceURL,
           let n = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue {
            let used = volume.usedBytes
            if used == 0 { return DisketteEngine.formatBytes(n) }
            let overhead = max(0, n - used)
            let pct = used > 0 ? (Double(overhead) / Double(used) * 100.0) : 0
            return "\(DisketteEngine.formatBytes(n)) · +\(String(format: "%.0f", pct))% pkg"
        }
        let approx = DisketteEngine.approximateContainerSize(volume)
        let used = volume.usedBytes
        if used == 0 { return "~\(DisketteEngine.formatBytes(approx))" }
        let overhead = max(0, approx - used)
        let pct = used > 0 ? (Double(overhead) / Double(used) * 100.0) : 0
        return "~\(DisketteEngine.formatBytes(approx)) · +\(String(format: "%.0f", pct))% pkg"
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 16) {
                FloppyVisual(
                    media: volume.media,
                    label: volume.label,
                    fillFraction: volume.fillFraction
                )
                .frame(maxWidth: 220, maxHeight: 220)
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Label", text: Binding(
                        get: { volume.label },
                        set: { volume.setLabel($0); statusMessage = "Label updated" }
                    ))
                    .textFieldStyle(.roundedBorder)

                    CapacityMeter(used: volume.usedBytes, capacity: volume.capacity)

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("Media").foregroundStyle(.secondary)
                            Text(volume.media.displayName)
                        }
                        GridRow {
                            Text("Files").foregroundStyle(.secondary)
                            Text("\(volume.fileCount)")
                        }
                        GridRow {
                            Text("Folders").foregroundStyle(.secondary)
                            Text("\(volume.directoryCount)")
                        }
                        GridRow {
                            Text("Sectors").foregroundStyle(.secondary)
                            Text("\(volume.capacity / DisketteEngine.sectorSize) × \(DisketteEngine.sectorSize) B")
                        }
                        GridRow {
                            Text("On disk").foregroundStyle(.secondary)
                            Text(containerSizeLabel(volume))
                        }
                    }
                    .font(.caption)

                    Picker("Packaging", selection: Binding(
                        get: { volume.packaging },
                        set: { volume.setPackaging($0) }
                    )) {
                        ForEach(DisketteEngine.Packaging.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .font(.caption)
                    .help(volume.packaging.help)

                    Toggle("Compress (zlib)", isOn: Binding(
                        get: { volume.compressOnWrite },
                        set: { volume.setCompressOnWrite($0) }
                    ))
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .disabled(volume.packaging != .binary)
                    .help("Binary only: zlib each file when smaller than raw. Reflects how this disc was last saved.")

                    if volume.loadedFromText {
                        Text("Opened as FLOP/1 text — Save writes efficient FLOP/2 binary unless you pick Text.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let span = try? SpanSet.readManifest(from: volume) {
                        let partN = span.parts?.count ?? span.filesOnThisDisc.count
                        let chunkedOnDisc = span.parts?.filter(\.isChunked).count ?? 0
                        VStack(alignment: .leading, spacing: 8) {
                            // Visible warning: span system folder is real and required for restore.
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.orange)
                                    .font(.system(size: 14))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Span disc — system folder on this volume")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.orange)
                                    Text(
                                        "Do not delete or rename “.diskette-span”. "
                                            + "It holds the set manifest"
                                            + (chunkedOnDisc > 0 ? " and file chunks" : "")
                                            + ". Removing it will break Restore Set."
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.primary.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.orange.opacity(0.14))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
                            )

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Span set · \(span.shortLabel)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.accent)
                                Text(
                                    "“\(span.setLabel)” · \(partN) part(s) on this disc"
                                        + (chunkedOnDisc > 0 ? " · \(chunkedOnDisc) chunk(s)" : "")
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                Text("Set \(String(span.setId.prefix(8)))… · \(span.totalFilesInSet) files total · \(span.magic)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(AppTheme.accentSoft)
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)

                Spacer(minLength: 0)

                Text("Drop files onto window · ⋮⋮ handle drags out")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 12)
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
            .padding(.vertical, 8)

            BrowserView(
                volume: volume,
                currentPath: $currentPath,
                onStatus: { statusMessage = $0 },
                onDirty: {
                    if statusMessage == nil || statusMessage?.contains("Saved") == true {
                        statusMessage = "Disc modified — save to keep changes"
                    }
                },
                onOpenFloppy: { url in
                    // MountedDriveView can't call openURL; use bridge
                    OpenFileBridge.enqueue(url)
                    OpenFileBridge.requestFlush()
                }
            )
            .padding(12)
            .frame(minWidth: 420)
        }
    }
}
