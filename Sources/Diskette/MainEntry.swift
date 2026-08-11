import AppKit
import SwiftUI

@main
struct MainEntry {
    static func main() {
        let args = CommandLine.arguments

        if args.contains("--self-test") {
            if let err = DisketteEngine.selfTest() {
                fputs("SELF-TEST FAILED: \(err)\n", stderr)
                exit(1)
            }
            print("SELF-TEST OK")
            exit(0)
        }

        if args.contains("--help") || args.contains("-h") {
            print(
                """
                Diskette — virtual floppy disc containers (FLOP/2 binary default)

                Usage:
                  Diskette                              Launch app
                  Diskette --self-test                  Round-trip fixtures
                  Diskette --create -o OUT.Floppy [--media SIZE] [--label NAME] [--format binary|text] [--no-compress]
                  Diskette --list FILE.Floppy
                  Diskette --add FILE.Floppy HOST_PATH [--path DEST_ON_DISC]
                  Diskette --extract FILE.Floppy DISC_PATH -o HOST_DIR_OR_FILE
                  Diskette --info FILE.Floppy
                  Diskette --repack FILE.Floppy [-o OUT] [--format binary|text] [--no-compress]
                  Diskette --repair-layout FILE.Floppy   Opt-in: Film Hiss-file → Film Hiss/file (heuristic; see docs)
                  Diskette --span FOLDER -o OUTDIR [--media SIZE] [--label NAME] [--format binary|text] [--no-compress]
                  Diskette --unspan DISC1.Floppy [DISC2…] -o OUTDIR [--force|--skip-existing]
                  Diskette --unspan-dir DIR -o OUTDIR [--force|--skip-existing]

                Media:
                  360 | 720 | 1.2 | 1.44 (default) | 2.88
                  (also: 5.25-dd-360k, 3.5-hd-1.44m, …)

                Packaging:
                  binary (default, FLP2) — raw payloads + optional zlib
                  text (FLOP/1) — base64, greppable, ~33% larger

                Span (multi-disc sets):
                  Pack a folder across multiple .Floppy discs (streams; not all in RAM).
                  Oversized files are chunked. Hidden files are skipped. Empty dirs kept.
                  Restore default refuses an existing destination root; --force overwrites.

                Containers open inside the app — multi-file browse/add/extract.
                Packaging only, not encryption.
                """
            )
            exit(0)
        }

        if args.contains("--create") {
            cliCreate(args)
        }
        if args.contains("--repack") {
            cliRepack(args)
        }
        if args.contains("--span") {
            cliSpan(args)
        }
        if args.contains("--unspan-dir") {
            cliUnspanDir(args)
        }
        if args.contains("--unspan") {
            cliUnspan(args)
        }
        if args.contains("--list") {
            cliList(args)
        }
        if args.contains("--add") {
            cliAdd(args)
        }
        if args.contains("--extract") {
            cliExtract(args)
        }
        if args.contains("--info") {
            cliInfo(args)
        }
        if args.contains("--repair-layout") {
            cliRepairLayout(args)
        }

        // Bare .Floppy paths on the command line → open in GUI
        let flagsWithValue: Set<String> = [
            "--encode", "--decode", "--create", "--list", "--add", "--extract",
            "--info", "--repack", "--repair-layout", "--span", "--unspan", "--unspan-dir",
            "-o", "--media", "--label", "--format", "--path", "--dialect",
        ]
        var i = 1
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("-") {
                if flagsWithValue.contains(a) { i += 2 } else { i += 1 }
                continue
            }
            let url = URL(fileURLWithPath: a)
            if DisketteEngine.isFloppyFilename(url) {
                OpenFileBridge.enqueue(url)
            }
            i += 1
        }

        let app = NSApplication.shared
        let delegate = AppDelegate.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    // MARK: - CLI

    private static func cliCreate(_ args: [String]) {
        var media = DisketteEngine.Media.default
        var label = "Untitled"
        var packaging = DisketteEngine.Packaging.default
        var compress = true
        if let mi = args.firstIndex(of: "--media"), mi + 1 < args.count {
            if let m = DisketteEngine.Media.parse(args[mi + 1]) {
                media = m
            } else {
                fputs("unknown media: \(args[mi + 1])\n", stderr)
                exit(1)
            }
        }
        if let li = args.firstIndex(of: "--label"), li + 1 < args.count {
            label = args[li + 1]
        }
        if let fi = args.firstIndex(of: "--format"), fi + 1 < args.count {
            packaging = parsePackaging(args[fi + 1])
        }
        if args.contains("--no-compress") { compress = false }
        let output: URL
        if let oi = args.firstIndex(of: "-o"), oi + 1 < args.count {
            output = URL(fileURLWithPath: args[oi + 1])
        } else {
            output = URL(fileURLWithPath: DisketteEngine.suggestedFilename(stem: label))
        }
        let dest = ensureFloppyExt(output)
        let vol = DisketteEngine.create(label: label, media: media)
        vol.packaging = packaging
        vol.compressOnWrite = compress
        do {
            try DisketteEngine.save(vol, to: dest)
            let size = (try? Data(contentsOf: dest).count) ?? 0
            print(
                "created \(dest.path) media=\(media.rawValue) capacity=\(media.capacity) "
                    + "label=\(vol.label) packaging=\(packaging.rawValue) bytes=\(size)"
            )
            exit(0)
        } catch {
            fputs("create error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func cliRepack(_ args: [String]) {
        guard let idx = args.firstIndex(of: "--repack"), idx + 1 < args.count else {
            fputs("usage: Diskette --repack FILE.Floppy [-o OUT] [--format binary|text] [--no-compress]\n", stderr)
            exit(1)
        }
        let input = URL(fileURLWithPath: args[idx + 1])
        var packaging = DisketteEngine.Packaging.default
        var compress = true
        if let fi = args.firstIndex(of: "--format"), fi + 1 < args.count {
            packaging = parsePackaging(args[fi + 1])
        }
        if args.contains("--no-compress") { compress = false }
        let output: URL
        if let oi = args.firstIndex(of: "-o"), oi + 1 < args.count {
            output = ensureFloppyExt(URL(fileURLWithPath: args[oi + 1]))
        } else {
            output = input
        }
        do {
            let before = try Data(contentsOf: input).count
            let vol = try DisketteEngine.load(from: input)
            vol.packaging = packaging
            vol.compressOnWrite = compress
            try DisketteEngine.save(vol, to: output)
            let after = try Data(contentsOf: output).count
            let saved = before > after ? before - after : 0
            print(
                "repacked \(output.path) packaging=\(packaging.rawValue) "
                    + "\(before) → \(after) bytes"
                    + (saved > 0 ? " (saved \(saved))" : "")
            )
            exit(0)
        } catch {
            fputs("repack error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func parsePackaging(_ s: String) -> DisketteEngine.Packaging {
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "text", "flop1", "flop/1", "v1", "base64":
            return .text
        case "binary", "bin", "flop2", "flop/2", "flp2", "v2":
            return .binary
        default:
            fputs("unknown --format \(s) (use binary|text)\n", stderr)
            exit(1)
        }
    }

    private static func cliSpan(_ args: [String]) {
        guard let idx = args.firstIndex(of: "--span"), idx + 1 < args.count else {
            fputs("usage: Diskette --span FOLDER -o OUTDIR [--media SIZE] [--label NAME]\n", stderr)
            exit(1)
        }
        let folder = URL(fileURLWithPath: args[idx + 1], isDirectory: true)
        guard let oi = args.firstIndex(of: "-o"), oi + 1 < args.count else {
            fputs("span requires -o OUTDIR\n", stderr)
            exit(1)
        }
        let outDir = URL(fileURLWithPath: args[oi + 1], isDirectory: true)
        var media = DisketteEngine.Media.default
        var label: String?
        var packaging = DisketteEngine.Packaging.default
        var compress = true
        if let mi = args.firstIndex(of: "--media"), mi + 1 < args.count {
            guard let m = DisketteEngine.Media.parse(args[mi + 1]) else {
                fputs("unknown media: \(args[mi + 1])\n", stderr)
                exit(1)
            }
            media = m
        }
        if let li = args.firstIndex(of: "--label"), li + 1 < args.count {
            label = args[li + 1]
        }
        if let fi = args.firstIndex(of: "--format"), fi + 1 < args.count {
            packaging = parsePackaging(args[fi + 1])
        }
        if args.contains("--no-compress") { compress = false }

        do {
            let result = try SpanSet.spanFolder(
                at: folder,
                outputDirectory: outDir,
                media: media,
                setLabel: label,
                packaging: packaging,
                compress: compress
            )
            print(
                "spanned files=\(result.totalFiles) bytes=\(result.totalBytes) "
                    + "chunked=\(result.chunkedFiles) emptyDirs=\(result.emptyDirectories) "
                    + "discs=\(result.discURLs.count) media=\(result.media.shortName) set=\(result.setId)"
            )
            for url in result.discURLs {
                print("  → \(url.path)")
            }
            exit(0)
        } catch {
            fputs("span error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func cliUnspan(_ args: [String]) {
        guard let idx = args.firstIndex(of: "--unspan"), idx + 1 < args.count else {
            fputs("usage: Diskette --unspan DISC1.Floppy [DISC2…] -o OUTDIR\n", stderr)
            exit(1)
        }
        guard let oi = args.firstIndex(of: "-o"), oi + 1 < args.count else {
            fputs("unspan requires -o OUTDIR\n", stderr)
            exit(1)
        }
        let outDir = URL(fileURLWithPath: args[oi + 1], isDirectory: true)
        let collision = parseCollision(args)
        var discs: [URL] = []
        var i = idx + 1
        while i < args.count {
            let a = args[i]
            if a == "-o" { break }
            if a.hasPrefix("--") { break }
            discs.append(URL(fileURLWithPath: a))
            i += 1
        }
        guard !discs.isEmpty else {
            fputs("unspan requires at least one .Floppy\n", stderr)
            exit(1)
        }
        do {
            let result = try SpanSet.unspan(discURLs: discs, outputDirectory: outDir, collision: collision)
            print(
                "unspanned files=\(result.filesRestored) bytes=\(result.bytesRestored) "
                    + "chunked=\(result.chunkedFiles) emptyDirs=\(result.emptyDirectories) "
                    + "discs=\(result.discCount) → \(result.outputRoot.path)"
            )
            exit(0)
        } catch {
            fputs("unspan error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func parseCollision(_ args: [String]) -> SpanSet.CollisionPolicy {
        if args.contains("--force") || args.contains("--overwrite") { return .overwrite }
        if args.contains("--skip-existing") { return .skip }
        return .fail
    }

    private static func cliUnspanDir(_ args: [String]) {
        guard let idx = args.firstIndex(of: "--unspan-dir"), idx + 1 < args.count else {
            fputs("usage: Diskette --unspan-dir DIR -o OUTDIR [--force|--skip-existing]\n", stderr)
            exit(1)
        }
        guard let oi = args.firstIndex(of: "-o"), oi + 1 < args.count else {
            fputs("unspan-dir requires -o OUTDIR\n", stderr)
            exit(1)
        }
        let dir = URL(fileURLWithPath: args[idx + 1], isDirectory: true)
        let outDir = URL(fileURLWithPath: args[oi + 1], isDirectory: true)
        let collision = parseCollision(args)
        do {
            let result = try SpanSet.unspanDirectory(dir, outputDirectory: outDir, collision: collision)
            print(
                "unspanned files=\(result.filesRestored) bytes=\(result.bytesRestored) "
                    + "chunked=\(result.chunkedFiles) emptyDirs=\(result.emptyDirectories) "
                    + "discs=\(result.discCount) → \(result.outputRoot.path)"
            )
            exit(0)
        } catch {
            fputs("unspan-dir error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func cliList(_ args: [String]) {
        guard let idx = args.firstIndex(of: "--list"), idx + 1 < args.count else {
            fputs("usage: Diskette --list FILE.Floppy\n", stderr)
            exit(1)
        }
        let url = URL(fileURLWithPath: args[idx + 1])
        do {
            let vol = try DisketteEngine.load(from: url)
            print("label=\(vol.label) media=\(vol.media.displayName) used=\(vol.usedBytes)/\(vol.capacity)")
            let all = vol.entries.values
                .filter { $0.path != "/" }
                .sorted { $0.path < $1.path }
            for e in all {
                if e.isDirectory {
                    print("  DIR  \(e.path)")
                } else {
                    print("  FILE \(e.path)  \(e.size)  crc=\(String(format: "%08x", e.crc32))")
                }
            }
            exit(0)
        } catch {
            fputs("list error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func cliAdd(_ args: [String]) {
        guard let idx = args.firstIndex(of: "--add"), idx + 2 < args.count else {
            fputs("usage: Diskette --add FILE.Floppy HOST_PATH [--path DEST]\n", stderr)
            exit(1)
        }
        let discURL = URL(fileURLWithPath: args[idx + 1])
        let hostURL = URL(fileURLWithPath: args[idx + 2])
        var destPath: String?
        if let pi = args.firstIndex(of: "--path"), pi + 1 < args.count {
            destPath = args[pi + 1]
        }
        do {
            let vol = try DisketteEngine.load(from: discURL)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: hostURL.path, isDirectory: &isDir)
            if isDir.boolValue {
                let dest = destPath ?? DisketteEngine.Volume.join("/", hostURL.lastPathComponent)
                try DisketteEngine.importHostFolder(into: vol, from: hostURL, destDir: dest)
            } else {
                let dest = destPath ?? DisketteEngine.Volume.join("/", hostURL.lastPathComponent)
                try DisketteEngine.importHostFile(into: vol, from: hostURL, destPath: dest, overwrite: true)
            }
            try DisketteEngine.save(vol, to: discURL)
            print("added \(hostURL.lastPathComponent) → \(discURL.path) used=\(vol.usedBytes)/\(vol.capacity)")
            exit(0)
        } catch {
            fputs("add error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func cliExtract(_ args: [String]) {
        guard let idx = args.firstIndex(of: "--extract"), idx + 2 < args.count else {
            fputs("usage: Diskette --extract FILE.Floppy DISC_PATH -o HOST\n", stderr)
            exit(1)
        }
        let discURL = URL(fileURLWithPath: args[idx + 1])
        let discPath = args[idx + 2]
        guard let oi = args.firstIndex(of: "-o"), oi + 1 < args.count else {
            fputs("extract requires -o HOST_DIR_OR_FILE\n", stderr)
            exit(1)
        }
        let host = URL(fileURLWithPath: args[oi + 1])
        do {
            let vol = try DisketteEngine.load(from: discURL)
            guard let entry = vol.entry(at: discPath) else {
                fputs("not found on disc: \(discPath)\n", stderr)
                exit(1)
            }
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
                try DisketteEngine.extract(from: vol, path: discPath, toHostDirectory: host)
            } else {
                // If -o is a directory, place file inside; else write to that path
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: host.path, isDirectory: &isDir), isDir.boolValue {
                    try DisketteEngine.extract(from: vol, path: discPath, toHostDirectory: host)
                } else {
                    try FileManager.default.createDirectory(
                        at: host.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try entry.data.write(to: host, options: .atomic)
                }
            }
            print("extracted \(discPath) → \(host.path)")
            exit(0)
        } catch {
            fputs("extract error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func cliRepairLayout(_ args: [String]) {
        guard let idx = args.firstIndex(of: "--repair-layout"), idx + 1 < args.count else {
            fputs("usage: Diskette --repair-layout FILE.Floppy\n", stderr)
            exit(1)
        }
        let url = URL(fileURLWithPath: args[idx + 1])
        do {
            // load() does not repair; apply heuristic only when the user asks.
            let vol = try DisketteEngine.load(from: url)
            let moved = try vol.repairFlattenedFolderImports()
            if moved == 0 {
                print("no matching paths found — layout unchanged")
                exit(0)
            }
            try DisketteEngine.save(vol, to: url)
            print("repaired \(moved) file(s) → \(url.path)")
            exit(0)
        } catch {
            fputs("repair-layout error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func cliInfo(_ args: [String]) {
        guard let idx = args.firstIndex(of: "--info"), idx + 1 < args.count else {
            fputs("usage: Diskette --info FILE.Floppy\n", stderr)
            exit(1)
        }
        let url = URL(fileURLWithPath: args[idx + 1])
        do {
            let vol = try DisketteEngine.load(from: url)
            let fileBytes = (try? Data(contentsOf: url).count) ?? 0
            let binEst = DisketteEngine.estimateContainerSize(
                vol, options: .init(packaging: .binary, compress: true)
            )
            let textEst = DisketteEngine.estimateContainerSize(
                vol, options: .init(packaging: .text, compress: false)
            )
            print("file:     \(url.path)")
            print("label:    \(vol.label)")
            print("media:    \(vol.media.displayName) (\(vol.media.rawValue))")
            print("packaging:\(vol.loadedFromText ? " FLOP/1 text (source)" : " \(vol.packaging.shortName)")")
            if let span = try? SpanSet.readManifest(from: vol) {
                print("span:     set \(span.setId) · disc \(span.index)/\(span.count) · “\(span.setLabel)” · root=\(span.rootName) · \(span.magic)")
                let chunked = span.chunkedFileCount ?? span.parts?.filter(\.isChunked).count ?? 0
                let partCount = span.parts?.count ?? span.filesOnThisDisc.count
                print("span parts on disc: \(partCount) · set total \(span.totalFilesInSet) files / \(span.totalBytesInSet) B · chunkedFiles=\(chunked)")
            }
            print("capacity: \(vol.capacity) bytes (\(DisketteEngine.formatBytes(vol.capacity)))")
            print("used:     \(vol.usedBytes) bytes (\(DisketteEngine.formatBytes(vol.usedBytes)))  [logical payload]")
            print("on disk:  \(fileBytes) bytes (\(DisketteEngine.formatBytes(fileBytes)))")
            print("estimate: binary+zlib ≈ \(binEst) · text/base64 ≈ \(textEst)")
            print("free:     \(vol.freeBytes) bytes")
            print("files:    \(vol.fileCount)")
            print("dirs:     \(vol.directoryCount)")
            print("created:  \(vol.created)")
            print("modified: \(vol.modified)")
            exit(0)
        } catch {
            fputs("info error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func ensureFloppyExt(_ url: URL) -> URL {
        if url.pathExtension.lowercased() == DisketteEngine.fileExtension.lowercased() {
            return url
        }
        return url.appendingPathExtension(DisketteEngine.fileExtension)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    private var window: NSWindow?
    private let minSize = NSSize(width: 920, height: 620)
    private let defaultSize = NSSize(width: 1080, height: 740)

    private override init() { super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        showMainWindow()
        DispatchQueue.main.async { [weak self] in self?.deliverPendingOpens() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.deliverPendingOpens()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        deliverPendingOpens()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if DocumentCloseBridge.prepareToQuit() {
            DiscFileOpener.cleanupAll()
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiscFileOpener.cleanupAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() } else { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { OpenFileBridge.enqueue(url) }
        showMainWindow()
        DispatchQueue.main.async { [weak self] in self?.deliverPendingOpens() }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        OpenFileBridge.enqueue(URL(fileURLWithPath: filename))
        showMainWindow()
        DispatchQueue.main.async { [weak self] in self?.deliverPendingOpens() }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for name in filenames { OpenFileBridge.enqueue(URL(fileURLWithPath: name)) }
        showMainWindow()
        DispatchQueue.main.async { [weak self] in self?.deliverPendingOpens() }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    private func deliverPendingOpens() {
        guard OpenFileBridge.hasPending() else { return }
        showMainWindow()
        OpenFileBridge.requestFlush()
    }

    private func showMainWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(
            rootView: ContentView().frame(minWidth: minSize.width, minHeight: minSize.height)
        )
        hosting.frame = NSRect(origin: .zero, size: defaultSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Diskette"
        window.contentView = hosting
        window.setContentSize(defaultSize)
        window.contentMinSize = minSize
        window.isRestorable = true
        window.setFrameAutosaveName("DisketteMain")
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    @objc private func showAbout(_ sender: Any?) {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        let versionLine: String
        switch (short, build) {
        case let (s?, b?): versionLine = "Version \(s) (\(b))"
        case let (s?, nil): versionLine = "Version \(s)"
        default: versionLine = "Version unavailable"
        }
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Diskette",
            .version: build ?? "",
            .applicationVersion: versionLine,
            .credits: NSAttributedString(
                string: """
                Store files in virtual floppy disc containers.

                Classic capacities (360 KB – 2.88 MB).
                Open .Floppy discs inside the app — browse,
                add, extract. Span large folders across multiple
                discs; oversize files are chunked and rejoined.
                Double-click a file to open it in the default app.
                FLOP/2 binary (default) + zlib; FLOP/1 text legacy.
                CRC-32 integrity. Packaging only — not encryption.
                """,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ),
        ])
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Diskette", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Diskette", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Diskette", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
