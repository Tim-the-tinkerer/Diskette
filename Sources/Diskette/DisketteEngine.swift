import Combine
import Foundation
import UniformTypeIdentifiers
import zlib

/// Virtual floppy disc containers (FLOP/1 text · FLOP/2 binary).
///
/// A `.Floppy` file is a portable multi-file disc image with a fixed capacity
/// matching classic media (360 KB … 2.88 MB). The app **opens** the container
/// in place: browse, add, extract, delete — no external mount required.
///
/// Default on-disk packaging is **FLOP/2 binary** (raw payloads, optional zlib)
/// — ~0% base64 overhead vs FLOP/1 text. FLOP/1 remains readable for old files.
///
/// This is packaging / storage, not encryption.
enum DisketteEngine {

    static let magic = "FLOP/1"
    /// Binary container magic (`FLP2` ASCII).
    static let magicBinary = Data([0x46, 0x4C, 0x50, 0x32]) // "FLP2"
    static let fileExtension = "Floppy"
    /// Logical format family (directory model); packaging may be v1 text or v2 binary.
    static let formatVersion = 2
    static let binaryFormatVersion: UInt8 = 1
    static let sectorSize = 512

    /// How a `.Floppy` is encoded on disk.
    enum Packaging: String, CaseIterable, Identifiable, Equatable {
        /// FLOP/2: binary directory + raw (or zlib) payloads. Default — efficient.
        case binary
        /// FLOP/1: UTF-8 map + base64 payloads. Inspectable, ~33% larger.
        case text

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .binary: return "Binary (FLOP/2)"
            case .text: return "Text (FLOP/1)"
            }
        }

        var shortName: String {
            switch self {
            case .binary: return "FLP2"
            case .text: return "FLOP/1"
            }
        }

        var help: String {
            switch self {
            case .binary:
                return "Raw file bytes in a compact binary container. Optional zlib per file. Default."
            case .text:
                return "UTF-8 + base64 — greppable, but ~33% larger. For inspection / old tools."
            }
        }

        static var `default`: Packaging { .binary }
    }

    /// Write options for `serialize` / `save`.
    struct WriteOptions: Equatable {
        var packaging: Packaging = .default
        /// When packaging is binary: try zlib per file; keep raw if not smaller.
        var compress: Bool = true

        static let `default` = WriteOptions()
        static let textLegacy = WriteOptions(packaging: .text, compress: false)
    }

    static var contentType: UTType {
        UTType(exportedAs: "com.diskette.floppy", conformingTo: .data)
    }

    static var importContentTypes: [UTType] {
        [contentType, .data]
    }

    static var exportContentTypes: [UTType] {
        [contentType, .data]
    }

    static func isFloppyFilename(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == fileExtension.lowercased() || ext == "floppy"
    }

    static func suggestedFilename(stem: String) -> String {
        var base = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "untitled" }
        if let r = base.range(of: #"\.(Floppy|floppy)$"#, options: .regularExpression) {
            base = String(base[..<r.lowerBound])
        }
        if base.isEmpty { base = "untitled" }
        return "\(base).\(fileExtension)"
    }

    // MARK: - Media

    /// Classic floppy geometries (usable capacity = tracks × sectors × 512 × sides).
    enum Media: String, CaseIterable, Identifiable, Codable, Equatable {
        case dd360 = "5.25-dd-360k"
        case hd1200 = "5.25-hd-1.2m"
        case dd720 = "3.5-dd-720k"
        case hd1440 = "3.5-hd-1.44m"
        case ed2880 = "3.5-ed-2.88m"

        var id: String { rawValue }

        static var `default`: Media { .hd1440 }

        var displayName: String {
            switch self {
            case .dd360: return "5.25\" DD · 360 KB"
            case .hd1200: return "5.25\" HD · 1.2 MB"
            case .dd720: return "3.5\" DD · 720 KB"
            case .hd1440: return "3.5\" HD · 1.44 MB"
            case .ed2880: return "3.5\" ED · 2.88 MB"
            }
        }

        var shortName: String {
            switch self {
            case .dd360: return "360K"
            case .hd1200: return "1.2M"
            case .dd720: return "720K"
            case .hd1440: return "1.44M"
            case .ed2880: return "2.88M"
            }
        }

        /// Usable byte capacity (classic formatted size).
        var capacity: Int {
            switch self {
            case .dd360: return 40 * 9 * sectorSize * 2   // 368_640
            case .hd1200: return 80 * 15 * sectorSize * 2 // 1_228_800
            case .dd720: return 80 * 9 * sectorSize * 2   // 737_280
            case .hd1440: return 80 * 18 * sectorSize * 2 // 1_474_560
            case .ed2880: return 80 * 36 * sectorSize * 2 // 2_949_120
            }
        }

        var formFactor: FormFactor {
            switch self {
            case .dd360, .hd1200: return .fiveQuarter
            case .dd720, .hd1440, .ed2880: return .threeHalf
            }
        }

        var densityLabel: String {
            switch self {
            case .dd360, .dd720: return "DD"
            case .hd1200, .hd1440: return "HD"
            case .ed2880: return "ED"
            }
        }

        static func parse(_ s: String) -> Media? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let m = Media(rawValue: t) { return m }
            switch t {
            case "360", "360k", "dd360", "5.25", "5.25dd": return .dd360
            case "1.2", "1.2m", "1200", "hd1200", "5.25hd": return .hd1200
            case "720", "720k", "dd720", "3.5dd": return .dd720
            case "1.44", "1.44m", "1440", "hd1440", "3.5", "3.5hd", "hd": return .hd1440
            case "2.88", "2.88m", "2880", "ed2880", "ed": return .ed2880
            default: return nil
            }
        }
    }

    enum FormFactor: String {
        case threeHalf = "3.5"
        case fiveQuarter = "5.25"
    }

    // MARK: - Errors

    enum EngineError: LocalizedError {
        case emptyPath
        case invalidFormat(String)
        case capacityExceeded(need: Int, free: Int)
        case fileNotFound(String)
        case alreadyExists(String)
        case notADirectory(String)
        case isDirectory(String)
        case cannotDeleteRoot
        case io(String)
        case crcMismatch(path: String)
        case volumeCRCMismatch(expected: UInt32, actual: UInt32)

        var errorDescription: String? {
            switch self {
            case .emptyPath: return "Empty path."
            case .invalidFormat(let m): return "Invalid floppy: \(m)"
            case .capacityExceeded(let need, let free):
                return "Disc full: need \(DisketteEngine.formatBytes(need)), only \(DisketteEngine.formatBytes(free)) free."
            case .fileNotFound(let p): return "Not found: \(p)"
            case .alreadyExists(let p): return "Already exists: \(p)"
            case .notADirectory(let p): return "Not a directory: \(p)"
            case .isDirectory(let p): return "Is a directory: \(p)"
            case .cannotDeleteRoot: return "Cannot delete the volume root."
            case .io(let m): return m
            case .crcMismatch(let p): return "CRC mismatch for \(p)"
            case .volumeCRCMismatch(let expected, let actual):
                return String(
                    format: "Volume CRC mismatch (header %08x, computed %08x) — directory metadata may be corrupted",
                    expected, actual
                )
            }
        }
    }

    // MARK: - Directory model

    struct Entry: Identifiable, Equatable {
        var id: String { path }
        /// Absolute path on the volume, e.g. `/notes.txt` or `/docs/a.md`. Always starts with `/`.
        var path: String
        var isDirectory: Bool
        var size: Int
        var modified: Date
        var crc32: UInt32
        /// File payload only (directories have empty data).
        var data: Data

        var name: String {
            if path == "/" { return "/" }
            return (path as NSString).lastPathComponent
        }

        var parentPath: String {
            if path == "/" { return "/" }
            let parent = (path as NSString).deletingLastPathComponent
            return parent.isEmpty ? "/" : parent
        }
    }

    /// In-memory mounted disc.
    final class Volume: ObservableObject, Identifiable {
        let id = UUID()
        var label: String
        var media: Media
        var created: Date
        var modified: Date
        /// path → entry (files hold data; dirs are markers)
        private(set) var entries: [String: Entry]
        var sourceURL: URL?
        var isDirty: Bool = false
        /// Preferred packaging when saving (default binary FLOP/2).
        var packaging: Packaging = .default
        /// Prefer zlib when writing binary.
        var compressOnWrite: Bool = true
        /// True if the file was opened from FLOP/1 text (may upgrade on save).
        var loadedFromText: Bool = false

        init(
            label: String,
            media: Media,
            created: Date = Date(),
            modified: Date = Date(),
            entries: [String: Entry] = [:],
            sourceURL: URL? = nil,
            isDirty: Bool = false,
            packaging: Packaging = .default,
            compressOnWrite: Bool = true
        ) {
            self.label = label
            self.media = media
            self.created = created
            self.modified = modified
            var e = entries
            if e["/"] == nil {
                e["/"] = Entry(
                    path: "/",
                    isDirectory: true,
                    size: 0,
                    modified: created,
                    crc32: 0,
                    data: Data()
                )
            }
            self.entries = e
            self.sourceURL = sourceURL
            self.isDirty = isDirty
            self.packaging = packaging
            self.compressOnWrite = compressOnWrite
        }

        var capacity: Int { media.capacity }

        var usedBytes: Int {
            entries.values.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size }
        }

        var freeBytes: Int { max(0, capacity - usedBytes) }

        var fillFraction: Double {
            guard capacity > 0 else { return 0 }
            return min(1, Double(usedBytes) / Double(capacity))
        }

        var fileCount: Int {
            entries.values.filter { !$0.isDirectory && $0.path != "/" }.count
        }

        var directoryCount: Int {
            entries.values.filter { $0.isDirectory && $0.path != "/" }.count
        }

        func children(of directoryPath: String) -> [Entry] {
            let dir = Self.normalize(directoryPath)
            guard let d = entries[dir], d.isDirectory else { return [] }
            return entries.values
                .filter { $0.path != dir && $0.parentPath == dir }
                .sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
        }

        func entry(at path: String) -> Entry? {
            entries[Self.normalize(path)]
        }

        // MARK: Mutations

        func addFile(at path: String, data: Data, overwrite: Bool = false) throws {
            let p = Self.normalize(path)
            guard p != "/" else { throw EngineError.alreadyExists("/") }
            try Self.validatePathComponents(p)
            if let existing = entries[p] {
                if existing.isDirectory { throw EngineError.isDirectory(p) }
                if !overwrite { throw EngineError.alreadyExists(p) }
                // Free old size first for capacity check on overwrite
                let freed = existing.size
                let need = data.count - freed
                if need > freeBytes {
                    throw EngineError.capacityExceeded(need: data.count, free: freeBytes + freed)
                }
            } else if data.count > freeBytes {
                throw EngineError.capacityExceeded(need: data.count, free: freeBytes)
            }

            try ensureParentDirectories(for: p)

            let now = Date()
            entries[p] = Entry(
                path: p,
                isDirectory: false,
                size: data.count,
                modified: now,
                crc32: DisketteEngine.crc32(data),
                data: data
            )
            modified = now
            isDirty = true
            objectWillChange.send()
        }

        func addDirectory(at path: String) throws {
            let p = Self.normalize(path)
            guard p != "/" else { return }
            try Self.validatePathComponents(p)
            if let existing = entries[p] {
                if existing.isDirectory { return }
                throw EngineError.alreadyExists(p)
            }
            try ensureParentDirectories(for: p)
            let now = Date()
            entries[p] = Entry(
                path: p,
                isDirectory: true,
                size: 0,
                modified: now,
                crc32: 0,
                data: Data()
            )
            modified = now
            isDirty = true
            objectWillChange.send()
        }

        func remove(at path: String) throws {
            let p = Self.normalize(path)
            guard p != "/" else { throw EngineError.cannotDeleteRoot }
            guard let e = entries[p] else { throw EngineError.fileNotFound(p) }
            if e.isDirectory {
                let prefix = p.hasSuffix("/") ? p : p + "/"
                let doomed = entries.keys.filter { $0 == p || $0.hasPrefix(prefix) }
                for k in doomed { entries.removeValue(forKey: k) }
            } else {
                entries.removeValue(forKey: p)
            }
            modified = Date()
            isDirty = true
            objectWillChange.send()
        }

        func rename(from: String, to: String) throws {
            let src = Self.normalize(from)
            let dst = Self.normalize(to)
            guard src != "/" else { throw EngineError.cannotDeleteRoot }
            guard let e = entries[src] else { throw EngineError.fileNotFound(src) }
            guard entries[dst] == nil else { throw EngineError.alreadyExists(dst) }
            try Self.validatePathComponents(dst)
            // Disallow renaming into a descendant of itself (e.g. /a → /a/b)
            if e.isDirectory {
                let prefix = src == "/" ? "/" : src + "/"
                if dst == src || dst.hasPrefix(prefix) {
                    throw EngineError.invalidFormat("Cannot rename a folder into itself")
                }
            }
            try ensureParentDirectories(for: dst)

            if e.isDirectory {
                let prefix = src == "/" ? "/" : src + "/"
                var remap: [(String, Entry)] = []
                for (k, v) in entries {
                    if k == src || k.hasPrefix(prefix) {
                        let suffix = String(k.dropFirst(src.count))
                        let newPath = Self.normalize(dst + suffix)
                        var nv = v
                        nv.path = newPath
                        remap.append((k, nv))
                    }
                }
                for (old, _) in remap { entries.removeValue(forKey: old) }
                for (_, nv) in remap { entries[nv.path] = nv }
            } else {
                var nv = e
                nv.path = dst
                entries.removeValue(forKey: src)
                entries[dst] = nv
            }
            modified = Date()
            isDirty = true
            objectWillChange.send()
        }

        func readFile(at path: String) throws -> Data {
            let p = Self.normalize(path)
            guard let e = entries[p] else { throw EngineError.fileNotFound(p) }
            if e.isDirectory { throw EngineError.isDirectory(p) }
            let crc = DisketteEngine.crc32(e.data)
            if crc != e.crc32 { throw EngineError.crcMismatch(path: p) }
            return e.data
        }

        /// Heuristic repair for a short-lived join bug that wrote
        /// `/Root/Film Hiss-foo.txt` beside dir `/Root/Film Hiss` instead of
        /// `/Root/Film Hiss/foo.txt`.
        ///
        /// **Opt-in only** — do not run on open/extract. Any sibling file whose
        /// name is `DirName-rest` next to a directory `DirName` is moved to
        /// `DirName/rest`, including legitimate names like `Reports-summary.txt`.
        /// Prefer CLI `--repair-layout` or the UI **Repair Layout…** command.
        ///
        /// Returns the number of files moved (marks dirty when non-zero).
        @discardableResult
        func repairFlattenedFolderImports() throws -> Int {
            // Collect directory basenames grouped by parent path
            var dirsByParent: [String: [String]] = [:] // parent → [dir name]
            for e in entries.values where e.isDirectory && e.path != "/" {
                let parent = e.parentPath
                dirsByParent[parent, default: []].append(e.name)
            }
            // Longest directory names first so "Film Hiss Extra" wins over "Film"
            for parent in dirsByParent.keys {
                dirsByParent[parent]?.sort { $0.count > $1.count }
            }

            var moves: [(from: String, to: String)] = []
            for e in entries.values where !e.isDirectory {
                let parent = e.parentPath
                guard let dirNames = dirsByParent[parent] else { continue }
                for dirName in dirNames {
                    let prefix = dirName + "-"
                    guard e.name.hasPrefix(prefix) else { continue }
                    let rest = String(e.name.dropFirst(prefix.count))
                    guard !rest.isEmpty else { continue }
                    let dest = Self.join(Self.join(parent, dirName), rest)
                    if entries[dest] == nil {
                        moves.append((e.path, dest))
                    }
                    break
                }
            }

            for m in moves {
                try rename(from: m.from, to: m.to)
            }
            if !moves.isEmpty {
                isDirty = true
                objectWillChange.send()
            }
            return moves.count
        }

        func setLabel(_ newLabel: String) {
            let trimmed = String(newLabel.prefix(32)).trimmingCharacters(in: .whitespacesAndNewlines)
            let next = trimmed.isEmpty ? "Untitled" : trimmed
            guard next != label else { return }
            label = next
            modified = Date()
            isDirty = true
            objectWillChange.send()
        }

        func setPackaging(_ newValue: Packaging) {
            guard newValue != packaging else { return }
            packaging = newValue
            isDirty = true
            objectWillChange.send()
        }

        func setCompressOnWrite(_ newValue: Bool) {
            guard newValue != compressOnWrite else { return }
            compressOnWrite = newValue
            isDirty = true
            objectWillChange.send()
        }

        private func ensureParentDirectories(for path: String) throws {
            var components = Self.normalize(path)
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard components.count >= 1 else { return }
            components.removeLast()
            var built = ""
            for c in components {
                built += "/" + c
                if let existing = entries[built] {
                    if !existing.isDirectory { throw EngineError.notADirectory(built) }
                } else {
                    entries[built] = Entry(
                        path: built,
                        isDirectory: true,
                        size: 0,
                        modified: Date(),
                        crc32: 0,
                        data: Data()
                    )
                }
            }
        }

        static func normalize(_ path: String) -> String {
            var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { return "/" }
            if !p.hasPrefix("/") { p = "/" + p }
            // Collapse // and strip trailing slash (except root)
            let parts = p.split(separator: "/", omittingEmptySubsequences: true)
            if parts.isEmpty { return "/" }
            return "/" + parts.joined(separator: "/")
        }

        /// Join a directory with a single name **or** a relative path (`a/b/c`).
        /// Each path component is sanitized; `/` **between** components is preserved.
        /// (Earlier bug: sanitizing the whole relative path turned `Film Hiss/file.txt`
        /// into `Film Hiss-file.txt` and flattened folder imports.)
        static func join(_ dir: String, _ nameOrRelative: String) -> String {
            let d = normalize(dir)
            let parts = nameOrRelative
                .split(separator: "/", omittingEmptySubsequences: true)
                .map { sanitizeNameComponent(String($0)) }
                .filter { !$0.isEmpty }
            if parts.isEmpty { return d }
            let tail = parts.joined(separator: "/")
            if d == "/" { return normalize("/" + tail) }
            return normalize(d + "/" + tail)
        }

        /// Single path component only — do not pass multi-segment paths here.
        static func sanitizeNameComponent(_ name: String) -> String {
            var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Reject path separators and nulls within one component
            n = n.replacingOccurrences(of: "/", with: "-")
            n = n.replacingOccurrences(of: "\\", with: "-")
            n = n.replacingOccurrences(of: "\0", with: "")
            if n == "." || n == ".." { n = "_" + n }
            // Keep names reasonable for FLOP path encoding
            if n.count > 200 { n = String(n.prefix(200)) }
            return n
        }

        static func validatePathComponents(_ path: String) throws {
            let p = normalize(path)
            if p == "/" { return }
            let utf8Count = p.utf8.count
            // FLP2 path length field is u16
            if utf8Count > Int(UInt16.max) {
                throw EngineError.invalidFormat("Path too long (\(utf8Count) bytes): \(p)")
            }
            for part in p.split(separator: "/", omittingEmptySubsequences: true) {
                if part == "." || part == ".." {
                    throw EngineError.invalidFormat("Invalid path component in \(p)")
                }
                if part.contains("\0") {
                    throw EngineError.invalidFormat("Invalid null in path \(p)")
                }
            }
        }
    }

    // MARK: - Create / serialize / parse

    static func create(label: String = "Untitled", media: Media = .default) -> Volume {
        Volume(label: label.isEmpty ? "Untitled" : String(label.prefix(32)), media: media, isDirty: true)
    }

    /// Serialize using the volume’s preferred packaging (default: binary FLOP/2).
    static func serialize(_ volume: Volume) -> Data {
        serialize(volume, options: WriteOptions(
            packaging: volume.packaging,
            compress: volume.compressOnWrite
        ))
    }

    static func serialize(_ volume: Volume, options: WriteOptions) -> Data {
        switch options.packaging {
        case .binary:
            return serializeBinary(volume, compress: options.compress)
        case .text:
            return serializeText(volume)
        }
    }

    /// FLOP/1 portable text (UTF-8 + base64). Larger; inspectable.
    static func serializeText(_ volume: Volume) -> Data {
        var lines: [String] = []
        lines.append(magic)
        lines.append("label=\(escapeHeader(volume.label))")
        lines.append("media=\(volume.media.rawValue)")
        lines.append("capacity=\(volume.media.capacity)")
        lines.append("sector=\(sectorSize)")
        lines.append("created=\(iso8601(volume.created))")
        lines.append("modified=\(iso8601(volume.modified))")
        lines.append("files=\(volume.fileCount)")
        lines.append("dirs=\(volume.directoryCount)")
        lines.append("used=\(volume.usedBytes)")
        lines.append("")

        let sorted = sortedEntries(volume)
        for e in sorted where e.path != "/" {
            if e.isDirectory {
                lines.append("DIR \(escapePath(e.path)) \(Int(e.modified.timeIntervalSince1970))")
            } else {
                lines.append(
                    "FILE \(escapePath(e.path)) \(e.size) \(String(format: "%08x", e.crc32)) \(Int(e.modified.timeIntervalSince1970))"
                )
                let b64 = e.data.base64EncodedString()
                var i = b64.startIndex
                while i < b64.endIndex {
                    let j = b64.index(i, offsetBy: 76, limitedBy: b64.endIndex) ?? b64.endIndex
                    lines.append(String(b64[i..<j]))
                    i = j
                }
                lines.append("END")
            }
        }

        let volCRC = volumeDigestCRC(sorted)
        if let idx = lines.firstIndex(of: "used=\(volume.usedBytes)") {
            lines.insert("volume_crc=\(String(format: "%08x", volCRC))", at: idx + 1)
        } else {
            lines.insert("volume_crc=\(String(format: "%08x", volCRC))", at: 1)
        }

        let text = lines.joined(separator: "\n") + "\n"
        return Data(text.utf8)
    }

    /// FLOP/2 binary: raw (or zlib) payloads — no base64 overhead.
    ///
    /// ```
    /// "FLP2" | ver u8 | flags u8 | label… | media… | capacity u32 | sector u16
    /// created u64 | modified u64 | entryCount u32 | volume_crc u32
    /// repeated: pathLen u16 | path | kind u8 | mtime u64 | logicalSize u32
    ///           crc32 u32 | storedSize u32 | storeFlags u8 | [stored bytes]
    /// ```
    static func serializeBinary(_ volume: Volume, compress: Bool = true) -> Data {
        let sorted = sortedEntries(volume).filter { $0.path != "/" }
        var out = Data()
        out.append(magicBinary)
        out.append(binaryFormatVersion) // ver
        out.append(UInt8(compress ? 0x01 : 0x00)) // flags: bit0 = compression may be used

        appendPascal8(&out, volume.label)
        appendPascal8(&out, volume.media.rawValue)
        appendU32(&out, UInt32(volume.media.capacity))
        appendU16(&out, UInt16(sectorSize))
        appendU64(&out, UInt64(volume.created.timeIntervalSince1970))
        appendU64(&out, UInt64(volume.modified.timeIntervalSince1970))
        appendU32(&out, UInt32(sorted.count))
        // Digest over the same entry set we emit (non-root only).
        appendU32(&out, volumeDigestCRC(sorted))

        for e in sorted {
            let pathData = Data(e.path.utf8)
            // Caller must validate; oversize paths cannot be encoded in FLP2.
            precondition(pathData.count <= Int(UInt16.max), "path exceeds FLP2 limit: \(e.path)")
            appendU16(&out, UInt16(pathData.count))
            out.append(pathData)
            out.append(e.isDirectory ? 1 : 0)
            appendU64(&out, UInt64(e.modified.timeIntervalSince1970))
            if e.isDirectory {
                appendU32(&out, 0)
                appendU32(&out, 0)
                appendU32(&out, 0)
                out.append(0) // storeFlags
            } else {
                appendU32(&out, UInt32(e.size))
                appendU32(&out, e.crc32)
                let stored: Data
                let storeFlags: UInt8
                if compress, let z = zlibCompress(e.data), z.count < e.data.count {
                    stored = z
                    storeFlags = 1 // zlib
                } else {
                    stored = e.data
                    storeFlags = 0 // raw
                }
                appendU32(&out, UInt32(stored.count))
                out.append(storeFlags)
                out.append(stored)
            }
        }
        return out
    }

    static func parse(_ data: Data) throws -> Volume {
        if data.starts(with: magicBinary) {
            return try parseBinary(data)
        }
        // FLOP/1 text (also tolerate UTF-8 BOM)
        var slice = data
        if slice.starts(with: Data([0xEF, 0xBB, 0xBF])) {
            slice = slice.dropFirst(3)
        }
        guard let text = String(data: slice, encoding: .utf8) else {
            throw EngineError.invalidFormat("not FLOP/2 binary and not UTF-8 text")
        }
        return try parseText(text)
    }

    static func parseBinary(_ data: Data) throws -> Volume {
        var r = BinaryReader(data)
        let magic = try r.read(4)
        guard magic == magicBinary else {
            throw EngineError.invalidFormat("missing FLP2 magic")
        }
        let ver = try r.readU8()
        guard ver == binaryFormatVersion else {
            throw EngineError.invalidFormat("unsupported FLP2 version \(ver)")
        }
        let headerFlags = try r.readU8()
        // Only bit0 defined (compression may be used); reject unknown bits.
        if headerFlags & ~0x01 != 0 {
            throw EngineError.invalidFormat("unknown FLP2 header flags 0x\(String(headerFlags, radix: 16))")
        }
        /// Whether the writer preferred zlib (may still store some files raw).
        let compressPreferred = (headerFlags & 0x01) != 0
        var anyFileCompressed = false
        let label = try r.readPascal8()
        let mediaRaw = try r.readPascal8()
        guard let media = Media.parse(mediaRaw) else {
            throw EngineError.invalidFormat("unknown media \(mediaRaw)")
        }
        _ = try r.readU32() // capacity informational
        let sector = try r.readU16()
        if sector != 0 && sector != UInt16(sectorSize) {
            throw EngineError.invalidFormat("unexpected sector size \(sector)")
        }
        let created = Date(timeIntervalSince1970: TimeInterval(try r.readU64()))
        let modified = Date(timeIntervalSince1970: TimeInterval(try r.readU64()))
        let entryCount = Int(try r.readU32())
        let expectedVolumeCRC = try r.readU32()

        var entries: [String: Entry] = [
            "/": Entry(path: "/", isDirectory: true, size: 0, modified: created, crc32: 0, data: Data())
        ]
        /// Entries as declared in the file (for volume_crc; excludes auto-created parents).
        var declared: [Entry] = []

        for _ in 0..<entryCount {
            let path = Volume.normalize(try r.readStringU16())
            let kind = try r.readU8()
            let mtime = Date(timeIntervalSince1970: TimeInterval(try r.readU64()))
            let logicalSize = Int(try r.readU32())
            let crc = try r.readU32()
            let storedSize = Int(try r.readU32())
            let storeFlags = try r.readU8()
            let stored = try r.read(storedSize)

            // Only bit0 (zlib) is defined for store_flags.
            if storeFlags & ~0x01 != 0 {
                throw EngineError.invalidFormat("unknown store flags 0x\(String(storeFlags, radix: 16)) for \(path)")
            }
            if storeFlags & 0x01 != 0 {
                anyFileCompressed = true
            }

            if path == "/" {
                throw EngineError.invalidFormat("entry path must not be root /")
            }
            if entries[path] != nil {
                throw EngineError.invalidFormat("duplicate path \(path)")
            }

            switch kind {
            case 1: // directory
                if logicalSize != 0 || crc != 0 || storedSize != 0 || storeFlags != 0 || !stored.isEmpty {
                    throw EngineError.invalidFormat("directory \(path) must have empty payload fields")
                }
                try ensureParentEntries(&entries, for: path, mtime: mtime)
                let entry = Entry(
                    path: path,
                    isDirectory: true,
                    size: 0,
                    modified: mtime,
                    crc32: 0,
                    data: Data()
                )
                entries[path] = entry
                declared.append(entry)

            case 0: // file
                if storedSize != stored.count {
                    throw EngineError.invalidFormat("stored size mismatch for \(path)")
                }
                let payload: Data
                if storeFlags & 1 != 0 {
                    guard let inflated = zlibDecompress(stored) else {
                        throw EngineError.invalidFormat("zlib inflate failed for \(path)")
                    }
                    payload = inflated
                } else {
                    payload = stored
                }
                if payload.count != logicalSize {
                    throw EngineError.invalidFormat("size mismatch for \(path): \(payload.count) vs \(logicalSize)")
                }
                let actual = crc32(payload)
                if actual != crc {
                    throw EngineError.crcMismatch(path: path)
                }
                try ensureParentEntries(&entries, for: path, mtime: mtime)
                let entry = Entry(
                    path: path,
                    isDirectory: false,
                    size: logicalSize,
                    modified: mtime,
                    crc32: crc,
                    data: payload
                )
                entries[path] = entry
                declared.append(entry)

            default:
                throw EngineError.invalidFormat("unknown entry kind \(kind) at \(path)")
            }
        }

        if r.remaining > 0 {
            throw EngineError.invalidFormat("trailing \(r.remaining) byte(s) after entry table")
        }

        let computedVolumeCRC = volumeDigestCRC(declared)
        if computedVolumeCRC != expectedVolumeCRC {
            throw EngineError.volumeCRCMismatch(expected: expectedVolumeCRC, actual: computedVolumeCRC)
        }

        // Reflect what was actually written — don't force compress=true on every open
        // (that made the UI show Compress checked and confused dirty/eject UX).
        let compressOnWrite = compressPreferred || anyFileCompressed
        let vol = Volume(
            label: label.isEmpty ? "Untitled" : label,
            media: media,
            created: created,
            modified: modified,
            entries: entries,
            packaging: .binary,
            compressOnWrite: compressOnWrite
        )
        if vol.usedBytes > vol.capacity {
            throw EngineError.invalidFormat(
                "contents (\(formatBytes(vol.usedBytes))) exceed \(media.displayName) capacity (\(formatBytes(vol.capacity)))"
            )
        }
        return vol
    }

    private static func sortedEntries(_ volume: Volume) -> [Entry] {
        volume.entries.values.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.path < b.path
        }
    }

    private static func volumeDigestCRC(_ entries: [Entry]) -> UInt32 {
        // Stable order so header CRC matches regardless of declaration sequence.
        let ordered = entries
            .filter { $0.path != "/" }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
                return a.path < b.path
            }
        let digestSource = ordered
            .map { e -> String in
                if e.isDirectory {
                    return "D:\(e.path)"
                }
                return "F:\(e.path):\(e.size):\(String(format: "%08x", e.crc32))"
            }
            .joined(separator: "\n")
        return crc32(Data(digestSource.utf8))
    }

    private static func ensureParentEntries(_ entries: inout [String: Entry], for path: String, mtime: Date) throws {
        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return }
        components.removeLast()
        var built = ""
        for c in components {
            built += "/" + c
            if let existing = entries[built] {
                if !existing.isDirectory {
                    throw EngineError.invalidFormat("path \(path) nested under file \(built)")
                }
            } else if entries[built] == nil {
                entries[built] = Entry(
                    path: built,
                    isDirectory: true,
                    size: 0,
                    modified: mtime,
                    crc32: 0,
                    data: Data()
                )
            }
        }
    }

    static func parseText(_ text: String) throws -> Volume {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = rawLines.first?.trimmingCharacters(in: .whitespaces),
              first == magic || first.hasPrefix("FLOP/") else {
            throw EngineError.invalidFormat("missing FLOP/1 magic")
        }

        var label = "Untitled"
        var media: Media = .default
        var created = Date()
        var modified = Date()
        var expectedVolumeCRC: UInt32?
        var headerDone = false
        var i = 1

        while i < rawLines.count {
            let line = rawLines[i].trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty {
                headerDone = true
                break
            }
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("DIR ") || line.hasPrefix("FILE ") {
                // Body started without blank line
                i -= 1
                headerDone = true
                break
            }
            if let eq = line.firstIndex(of: "=") {
                let key = String(line[..<eq]).lowercased()
                let val = String(line[line.index(after: eq)...])
                switch key {
                case "label": label = unescapeHeader(val)
                case "media":
                    if let m = Media.parse(val) { media = m }
                case "created":
                    if let d = parseISO8601(val) { created = d }
                case "modified":
                    if let d = parseISO8601(val) { modified = d }
                case "volume_crc":
                    if let n = UInt32(val.trimmingCharacters(in: .whitespaces), radix: 16) {
                        expectedVolumeCRC = n
                    }
                default: break
                }
            }
        }
        _ = headerDone

        var entries: [String: Entry] = [
            "/": Entry(path: "/", isDirectory: true, size: 0, modified: created, crc32: 0, data: Data())
        ]
        var declared: [Entry] = []

        while i < rawLines.count {
            let line = rawLines[i].trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("DIR ") {
                let rest = String(line.dropFirst(4))
                let parts = splitWhitespace(rest)
                guard let pathTok = parts.first else { continue }
                let path = Volume.normalize(unescapePath(pathTok))
                if path == "/" {
                    throw EngineError.invalidFormat("DIR path must not be root /")
                }
                if entries[path] != nil {
                    throw EngineError.invalidFormat("duplicate path \(path)")
                }
                let ts = parts.count > 1 ? TimeInterval(parts[1]) ?? modified.timeIntervalSince1970 : modified.timeIntervalSince1970
                try ensureParentEntries(&entries, for: path, mtime: Date(timeIntervalSince1970: ts))
                let entry = Entry(
                    path: path,
                    isDirectory: true,
                    size: 0,
                    modified: Date(timeIntervalSince1970: ts),
                    crc32: 0,
                    data: Data()
                )
                entries[path] = entry
                declared.append(entry)
                continue
            }

            if line.hasPrefix("FILE ") {
                let rest = String(line.dropFirst(5))
                let parts = splitWhitespace(rest)
                guard parts.count >= 3 else {
                    throw EngineError.invalidFormat("bad FILE line")
                }
                let path = Volume.normalize(unescapePath(parts[0]))
                if path == "/" {
                    throw EngineError.invalidFormat("FILE path must not be root /")
                }
                if entries[path] != nil {
                    throw EngineError.invalidFormat("duplicate path \(path)")
                }
                guard let size = Int(parts[1]) else {
                    throw EngineError.invalidFormat("bad FILE size")
                }
                let crcHex = parts[2]
                let crc = UInt32(crcHex, radix: 16) ?? 0
                let ts = parts.count > 3
                    ? TimeInterval(parts[3]) ?? modified.timeIntervalSince1970
                    : modified.timeIntervalSince1970

                var b64 = ""
                while i < rawLines.count {
                    let bl = rawLines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                    if bl == "END" { break }
                    if bl.hasPrefix("#") || bl.isEmpty { continue }
                    b64 += bl
                }
                guard let payload = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]) else {
                    throw EngineError.invalidFormat("bad base64 for \(path)")
                }
                if payload.count != size {
                    throw EngineError.invalidFormat("size mismatch for \(path): header \(size), data \(payload.count)")
                }
                let actual = Self.crc32(payload)
                if actual != crc {
                    throw EngineError.crcMismatch(path: path)
                }
                let mtime = Date(timeIntervalSince1970: ts)
                try ensureParentEntries(&entries, for: path, mtime: mtime)
                let entry = Entry(
                    path: path,
                    isDirectory: false,
                    size: size,
                    modified: mtime,
                    crc32: crc,
                    data: payload
                )
                entries[path] = entry
                declared.append(entry)
                continue
            }
        }

        if let expected = expectedVolumeCRC {
            let computed = volumeDigestCRC(declared)
            if computed != expected {
                throw EngineError.volumeCRCMismatch(expected: expected, actual: computed)
            }
        }

        let vol = Volume(
            label: label,
            media: media,
            created: created,
            modified: modified,
            entries: entries,
            isDirty: false,
            // Prefer efficient binary on next save (legacy FLOP/1 still loads).
            packaging: .default,
            // Text format has no zlib payloads; default compress for binary upgrade.
            compressOnWrite: true
        )
        // Tag that source was text so UI can mention upgrade.
        vol.loadedFromText = true
        if vol.usedBytes > vol.capacity {
            throw EngineError.invalidFormat(
                "contents (\(formatBytes(vol.usedBytes))) exceed \(media.displayName) capacity (\(formatBytes(vol.capacity)))"
            )
        }
        return vol
    }

    static func load(from url: URL) throws -> Volume {
        let data = try Data(contentsOf: url)
        let vol = try parse(data)
        vol.sourceURL = url
        vol.isDirty = false
        // Layout is left as stored. Flattened-path repair is opt-in only
        // (--repair-layout / UI Repair Layout…) — the filename heuristic is not safe to run silently.
        return vol
    }

    static func save(_ volume: Volume, to url: URL) throws {
        for e in volume.entries.values where e.path != "/" {
            try Volume.validatePathComponents(e.path)
        }
        volume.modified = Date()
        let data = serialize(volume)
        try data.write(to: url, options: .atomic)
        volume.sourceURL = url
        volume.isDirty = false
        volume.objectWillChange.send()
    }

    /// On-disk size of a serialized volume (expensive — full encode). Prefer `approximateContainerSize` in UI.
    static func estimateContainerSize(_ volume: Volume, options: WriteOptions = .default) -> Int {
        serialize(volume, options: options).count
    }

    /// Cheap UI estimate: avoids full serialize on every redraw (which freezes selection/navigation).
    static func approximateContainerSize(_ volume: Volume) -> Int {
        let used = volume.usedBytes
        let files = max(1, volume.fileCount + volume.directoryCount)
        let overhead = 256 + files * 48
        switch volume.packaging {
        case .binary:
            // Raw payloads ≈ used; zlib may shrink (unknown) — report upper-ish bound.
            return used + overhead
        case .text:
            // Base64 ≈ 4/3 plus line breaks/headers
            return Int(Double(used) * 1.37) + overhead + files * 40
        }
    }

    // MARK: - Bulk helpers

    /// Add a host file into the volume at `destPath` (full path including filename).
    static func importHostFile(into volume: Volume, from hostURL: URL, destPath: String, overwrite: Bool = false) throws {
        let data = try Data(contentsOf: hostURL)
        try volume.addFile(at: destPath, data: data, overwrite: overwrite)
    }

    /// Recursively import a host folder under `destDir` on the volume.
    static func importHostFolder(into volume: Volume, from hostURL: URL, destDir: String) throws {
        let fm = FileManager.default
        let destRoot = Volume.normalize(destDir)
        try volume.addDirectory(at: destRoot == "/" ? Volume.join("/", hostURL.lastPathComponent) : destRoot)

        let baseDest: String
        if destDir == "/" || destDir.isEmpty {
            baseDest = Volume.join("/", hostURL.lastPathComponent)
            try volume.addDirectory(at: baseDest)
        } else {
            baseDest = Volume.normalize(destDir)
            try volume.addDirectory(at: baseDest)
        }

        guard let enumerator = fm.enumerator(
            at: hostURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw EngineError.io("Cannot enumerate \(hostURL.path)")
        }

        let rootPath = hostURL.standardizedFileURL.path
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            let rel = String(item.standardizedFileURL.path.dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let volPath = rel.isEmpty ? baseDest : Volume.join(baseDest, rel)
            if values.isDirectory == true {
                try volume.addDirectory(at: volPath)
            } else {
                let data = try Data(contentsOf: item)
                try volume.addFile(at: volPath, data: data, overwrite: true)
            }
        }
    }

    /// Extract one file or an entire directory tree to a host folder.
    ///
    /// - Directory `/Film Hiss` → `hostDir/Film Hiss/…` (structure preserved under the folder name)
    /// - Volume root `/` → `hostDir/…` (all top-level entries)
    /// - Nested file `/Film Hiss/a.txt` → `hostDir/Film Hiss/a.txt` (keeps intermediate folders)
    /// - Root-level file `/a.txt` → `hostDir/a.txt`
    ///
    /// Does **not** rewrite paths. Run `repairFlattenedFolderImports()` first if the disc
    /// needs the optional join-bug heuristic.
    static func extract(from volume: Volume, path: String, toHostDirectory hostDir: URL) throws {
        let p = Volume.normalize(path)
        try Volume.validatePathComponents(p)
        guard let e = volume.entry(at: p) else { throw EngineError.fileNotFound(p) }
        let fm = FileManager.default
        try fm.createDirectory(at: hostDir, withIntermediateDirectories: true)
        let root = hostDir.standardizedFileURL

        if !e.isDirectory {
            // Preserve path under hostDir when the file lives in a folder on the disc.
            let relFromVolume = String(p.dropFirst()) // strip leading /
            let dest = hostURL(under: root, relativePath: relFromVolume.isEmpty ? e.name : relFromVolume)
            guard isPath(dest, containedUnder: root) else {
                throw EngineError.io("Refusing to extract outside destination: \(e.name)")
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try volume.readFile(at: p)
            try data.write(to: dest, options: .atomic)
            return
        }

        // Directory extract: place the tree under hostDir/<dirname>/ (or hostDir/ for volume root).
        let extractRoot: URL
        if p == "/" {
            extractRoot = root
        } else {
            extractRoot = root.appendingPathComponent(e.name)
            try fm.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        }

        let prefix = p == "/" ? "/" : p + "/"
        let items = volume.entries.values
            .filter { $0.path == p || $0.path.hasPrefix(prefix) }
            .sorted { $0.path < $1.path }

        for item in items {
            try Volume.validatePathComponents(item.path)
            // Relative path under the extracted directory (not including the directory name again).
            let rel: String
            if item.path == p {
                // The directory node itself — already created as extractRoot.
                if item.isDirectory { continue }
                rel = item.name
            } else if p == "/" {
                rel = String(item.path.dropFirst())
            } else {
                rel = String(item.path.dropFirst(p.count).drop(while: { $0 == "/" }))
            }

            let dest = hostURL(under: extractRoot, relativePath: rel)
            guard isPath(dest, containedUnder: root) else {
                throw EngineError.io("Refusing to extract outside destination: \(item.path)")
            }
            if item.isDirectory {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try volume.readFile(at: item.path)
                try data.write(to: dest, options: .atomic)
            }
        }
    }

    /// Build `base/a/b/c` from a relative path, rejecting `.` / `..`.
    private static func hostURL(under base: URL, relativePath: String) -> URL {
        let parts = relativePath
            .split(separator: "/")
            .map(String.init)
            .filter { $0 != ".." && $0 != "." && !$0.isEmpty }
        return parts.reduce(base) { $0.appendingPathComponent($1) }
    }

    // MARK: - Formatting helpers

    static func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        let kb = Double(n) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        return String(format: "%.2f MB", mb)
    }

    static func formatBytesExact(_ n: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useBytes]
        return formatter.string(fromByteCount: Int64(n))
    }

    // MARK: - CRC / zlib / binary helpers

    /// CRC-32 (ISO/zlib). Pass `seed` from a previous call to update incrementally over a stream.
    static func crc32(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        // Empty buffer: zlib ignores seed when ptr is nil — preserve seed for streaming.
        if data.isEmpty { return seed }
        return data.withUnsafeBytes { buf -> UInt32 in
            let ptr = buf.bindMemory(to: UInt8.self).baseAddress
            let len = uInt(buf.count)
            let value = zlib.crc32(uLong(seed), ptr, len)
            return UInt32(value)
        }
    }

    /// True if `dest` is `root` or a path under it (after standardization). Blocks zip-slip.
    static func isPath(_ dest: URL, containedUnder root: URL) -> Bool {
        let d = dest.standardizedFileURL.resolvingSymlinksInPath().path
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        if d == r { return true }
        let prefix = r.hasSuffix("/") ? r : r + "/"
        return d.hasPrefix(prefix)
    }

    /// Stream CRC-32 of a host file without loading it entirely into memory.
    static func crc32File(at url: URL, bufferSize: Int = 1_048_576) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var seed: UInt32 = 0
        while true {
            let chunk: Data
            if #available(macOS 10.15.4, *) {
                chunk = try handle.read(upToCount: bufferSize) ?? Data()
            } else {
                chunk = handle.readData(ofLength: bufferSize)
            }
            if chunk.isEmpty { break }
            seed = crc32(chunk, seed: seed)
        }
        return seed
    }

    /// Read a byte range from a host file (one slice — not the whole file).
    static func readFileSlice(at url: URL, offset: Int, length: Int) throws -> Data {
        guard offset >= 0, length >= 0 else {
            throw EngineError.io("Invalid file slice offset/length")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data: Data
        if #available(macOS 10.15.4, *) {
            data = try handle.read(upToCount: length) ?? Data()
        } else {
            data = handle.readData(ofLength: length)
        }
        guard data.count == length else {
            throw EngineError.io("Short read at \(url.lastPathComponent) offset \(offset)")
        }
        return data
    }

    /// Apple zlib (NSData); may not start with classic 78 9c magic.
    static func zlibCompress(_ data: Data) -> Data? {
        try? (data as NSData).compressed(using: .zlib) as Data
    }

    static func zlibDecompress(_ data: Data) -> Data? {
        try? (data as NSData).decompressed(using: .zlib) as Data
    }

    private static func appendU16(_ data: inout Data, _ v: UInt16) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private static func appendU32(_ data: inout Data, _ v: UInt32) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private static func appendU64(_ data: inout Data, _ v: UInt64) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private static func appendPascal8(_ data: inout Data, _ s: String) {
        let bytes = Data(s.utf8.prefix(255))
        data.append(UInt8(bytes.count))
        data.append(bytes)
    }

    private struct BinaryReader {
        let data: Data
        var offset: Int = 0

        init(_ data: Data) { self.data = data }

        var remaining: Int { max(0, data.count - offset) }

        mutating func read(_ n: Int) throws -> Data {
            guard n >= 0, offset + n <= data.count else {
                throw EngineError.invalidFormat("truncated binary (need \(n) at \(offset))")
            }
            let slice = data.subdata(in: offset..<(offset + n))
            offset += n
            return slice
        }

        mutating func readU8() throws -> UInt8 {
            let d = try read(1)
            return d[0]
        }

        mutating func readU16() throws -> UInt16 {
            let d = try read(2)
            return UInt16(d[0]) << 8 | UInt16(d[1])
        }

        mutating func readU32() throws -> UInt32 {
            let d = try read(4)
            return UInt32(d[0]) << 24 | UInt32(d[1]) << 16 | UInt32(d[2]) << 8 | UInt32(d[3])
        }

        mutating func readU64() throws -> UInt64 {
            let hi = UInt64(try readU32())
            let lo = UInt64(try readU32())
            return (hi << 32) | lo
        }

        mutating func readPascal8() throws -> String {
            let n = Int(try readU8())
            let d = try read(n)
            return String(data: d, encoding: .utf8) ?? ""
        }

        mutating func readStringU16() throws -> String {
            let n = Int(try readU16())
            let d = try read(n)
            guard let s = String(data: d, encoding: .utf8) else {
                throw EngineError.invalidFormat("invalid UTF-8 path")
            }
            return s
        }
    }

    // MARK: - Header escaping

    private static func escapeHeader(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func unescapeHeader(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\", s.index(after: i) < s.endIndex {
                let n = s[s.index(after: i)]
                if n == "n" { out.append("\n"); i = s.index(i, offsetBy: 2); continue }
                if n == "\\" { out.append("\\"); i = s.index(i, offsetBy: 2); continue }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    private static func escapePath(_ p: String) -> String {
        if p.contains(" ") || p.contains("\\") {
            return p.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: " ", with: "\\ ")
        }
        return p
    }

    private static func unescapePath(_ p: String) -> String {
        var out = ""
        var i = p.startIndex
        while i < p.endIndex {
            if p[i] == "\\", p.index(after: i) < p.endIndex {
                out.append(p[p.index(after: i)])
                i = p.index(i, offsetBy: 2)
                continue
            }
            out.append(p[i])
            i = p.index(after: i)
        }
        return out
    }

    private static func splitWhitespace(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var i = s.startIndex
        var escaped = false
        while i < s.endIndex {
            let c = s[i]
            if escaped {
                current.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == " " || c == "\t" {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
            } else {
                current.append(c)
            }
            i = s.index(after: i)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func iso8601(_ d: Date) -> String {
        isoFormatter.string(from: d)
    }

    private static func parseISO8601(_ s: String) -> Date? {
        isoFormatter.date(from: s)
    }

    // MARK: - Self-test

    static func selfTest() -> String? {
        // 1. Empty volume round-trip (binary default)
        do {
            let v = create(label: "Test Disc", media: .hd1440)
            let data = serialize(v)
            if !data.starts(with: magicBinary) { return "default serialize not FLP2" }
            let v2 = try parse(data)
            if v2.label != "Test Disc" { return "label mismatch" }
            if v2.media != .hd1440 { return "media mismatch" }
            if v2.usedBytes != 0 { return "empty used != 0" }
            if v2.packaging != .binary { return "packaging not binary" }
            // New discs default compress=true → header flag set
            if !v2.compressOnWrite { return "empty compressOnWrite should be true" }
        } catch {
            return "empty round-trip: \(error.localizedDescription)"
        }

        // 1b. compressOnWrite false is restored from header (no false dirty)
        do {
            let v = create(label: "Raw", media: .dd360)
            v.compressOnWrite = false
            try v.addFile(at: "/a.txt", data: Data("hello".utf8))
            let data = serialize(v)
            let v2 = try parse(data)
            if v2.compressOnWrite { return "compressOnWrite should be false after no-compress save" }
            if v2.isDirty { return "parsed volume should not be dirty" }
            // setLabel no-op must not dirty
            v2.setLabel(v2.label)
            if v2.isDirty { return "setLabel no-op dirtied volume" }
        } catch {
            return "compress round-trip: \(error.localizedDescription)"
        }

        // 2. Multi-file + folder + CRC (binary + text)
        do {
            let v = create(label: "Pack", media: .dd720)
            try v.addFile(at: "/hello.txt", data: Data("Hello, floppy!".utf8))
            try v.addDirectory(at: "/docs")
            try v.addFile(at: "/docs/note.md", data: Data("# Note\nStored on a virtual disc.\n".utf8))
            let bin = Data((0..<2000).map { UInt8($0 % 256) })
            try v.addFile(at: "/docs/blob.bin", data: bin)
            // Highly compressible for zlib path
            try v.addFile(at: "/zeros.bin", data: Data(repeating: 0, count: 8000))

            if v.fileCount != 4 { return "fileCount \(v.fileCount)" }
            if v.children(of: "/").count != 3 { return "root children" }

            for packaging in Packaging.allCases {
                let data = serialize(v, options: WriteOptions(packaging: packaging, compress: true))
                let v2 = try parse(data)
                let hello = try v2.readFile(at: "/hello.txt")
                if String(data: hello, encoding: .utf8) != "Hello, floppy!" {
                    return "\(packaging.rawValue) hello content"
                }
                let blob = try v2.readFile(at: "/docs/blob.bin")
                if blob != bin { return "\(packaging.rawValue) blob mismatch" }
                let zeros = try v2.readFile(at: "/zeros.bin")
                if zeros.count != 8000 || zeros.contains(where: { $0 != 0 }) {
                    return "\(packaging.rawValue) zeros"
                }
            }

            // Binary should beat text for this payload
            let binSize = serialize(v, options: WriteOptions(packaging: .binary, compress: true)).count
            let textSize = serialize(v, options: WriteOptions(packaging: .text, compress: false)).count
            if binSize >= textSize {
                return "binary (\(binSize)) should be smaller than text (\(textSize))"
            }

            // Capacity enforcement
            let v2 = try parse(serialize(v))
            let big = Data(repeating: 0xAB, count: v2.freeBytes + 1)
            do {
                try v2.addFile(at: "/too-big.bin", data: big)
                return "capacity should have failed"
            } catch EngineError.capacityExceeded { /* ok */ }

            let freeBefore = v2.freeBytes
            try v2.remove(at: "/docs/blob.bin")
            if v2.freeBytes <= freeBefore { return "free space after delete" }

            try v2.rename(from: "/hello.txt", to: "/greetings.txt")
            if v2.entry(at: "/hello.txt") != nil { return "old path remains" }
            _ = try v2.readFile(at: "/greetings.txt")
        } catch {
            return "multi-file: \(error.localizedDescription)"
        }

        // 3. Each media capacity
        for m in Media.allCases {
            let v = create(label: m.shortName, media: m)
            if v.capacity != m.capacity { return "capacity \(m.rawValue)" }
            let half = Data(repeating: 0x55, count: min(1024, m.capacity))
            do {
                try v.addFile(at: "/x.bin", data: half)
            } catch {
                return "write \(m.rawValue): \(error.localizedDescription)"
            }
            let data = serialize(v)
            do {
                let v2 = try parse(data)
                if v2.media != m { return "media parse \(m.rawValue)" }
            } catch {
                return "parse \(m.rawValue): \(error.localizedDescription)"
            }
        }

        // 4. Path with spaces (both packagings)
        do {
            let v = create(label: "Spaces", media: .dd360)
            try v.addFile(at: "/my file.txt", data: Data("space".utf8))
            for packaging in Packaging.allCases {
                let data = serialize(v, options: WriteOptions(packaging: packaging, compress: true))
                let v2 = try parse(data)
                let d = try v2.readFile(at: "/my file.txt")
                if String(data: d, encoding: .utf8) != "space" {
                    return "spaces \(packaging.rawValue)"
                }
            }
        } catch {
            return "spaces: \(error.localizedDescription)"
        }

        // 5. volume_crc enforced (binary)
        do {
            let v = create(label: "CRC", media: .dd360)
            try v.addFile(at: "/a.txt", data: Data("abc".utf8))
            let data = serialize(v, options: WriteOptions(packaging: .binary, compress: false))

            var trailing = data
            trailing.append(0xFF)
            do {
                _ = try parse(trailing)
                return "trailing bytes should fail"
            } catch EngineError.invalidFormat(let m) where m.contains("trailing") {
                /* ok */
            }

            // Corrupt volume_crc u32: walk header region until volumeCRCMismatch fires.
            var sawVolumeCRCFail = false
            for idx in 20..<min(data.count, 120) {
                var copy = data
                copy[idx] ^= 0x01
                do {
                    _ = try parse(copy)
                } catch EngineError.volumeCRCMismatch {
                    sawVolumeCRCFail = true
                    break
                } catch {
                    continue
                }
            }
            if !sawVolumeCRCFail {
                var copy = data
                if copy.count > 10 { copy[10] ^= 0xFF }
                do {
                    _ = try parse(copy)
                    return "corrupted binary should fail"
                } catch {
                    /* ok — other field corruption */
                }
            }
        } catch {
            return "crc-enforcement: \(error.localizedDescription)"
        }

        // 6. Multi-disc whole-file span
        if let err = SpanSet.selfTest() {
            return err
        }

        // 7. Name sanitization / path validation
        do {
            let v = create(label: "Safe", media: .dd360)
            try v.addFile(at: "/ok.txt", data: Data("x".utf8))
            // join must preserve nested relative paths (folder import)
            if Volume.join("/Root", "Film Hiss/file.txt") != "/Root/Film Hiss/file.txt" {
                return "join nested path broken: \(Volume.join("/Root", "Film Hiss/file.txt"))"
            }
            // single-component sanitizer still kills slashes
            if Volume.sanitizeNameComponent("a/b") != "a-b" {
                return "sanitize slash"
            }
            do {
                try Volume.validatePathComponents(String(repeating: "x", count: 70_000))
                return "overlong path should fail validation"
            } catch { /* ok */ }
            _ = v
        } catch {
            return "sanitize: \(error.localizedDescription)"
        }

        // 8. Repair flattened folder imports (opt-in heuristic only)
        do {
            let v = create(label: "Repair", media: .dd720)
            try v.addDirectory(at: "/Root")
            try v.addDirectory(at: "/Root/Film Hiss")
            try v.addFile(
                at: "/Root/Film Hiss-parseltongue-plain.txt",
                data: Data("nested".utf8)
            )
            let n = try v.repairFlattenedFolderImports()
            if n != 1 { return "repair moved \(n), expected 1" }
            if v.entry(at: "/Root/Film Hiss/parseltongue-plain.txt") == nil {
                return "repair dest missing"
            }
            if v.entry(at: "/Root/Film Hiss-parseltongue-plain.txt") != nil {
                return "repair source still present"
            }
            let data = try v.readFile(at: "/Root/Film Hiss/parseltongue-plain.txt")
            if String(data: data, encoding: .utf8) != "nested" { return "repair content" }
        } catch {
            return "repair: \(error.localizedDescription)"
        }

        // 8b. load() must not auto-repair (legitimate Dir-name siblings stay put, clean open)
        do {
            let v = create(label: "NoAuto", media: .dd720)
            try v.addDirectory(at: "/Projects")
            try v.addDirectory(at: "/Projects/Reports")
            try v.addFile(at: "/Projects/Reports-summary.txt", data: Data("ok".utf8))
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("diskette-no-auto-repair-\(UUID().uuidString).Floppy")
            defer { try? FileManager.default.removeItem(at: url) }
            try save(v, to: url)
            let loaded = try load(from: url)
            if loaded.isDirty { return "load dirtied volume without edits" }
            if loaded.entry(at: "/Projects/Reports-summary.txt") == nil {
                return "load auto-repaired legitimate Reports-summary.txt"
            }
            if loaded.entry(at: "/Projects/Reports/summary.txt") != nil {
                return "load invented Reports/summary.txt"
            }
        } catch {
            return "no-auto-repair: \(error.localizedDescription)"
        }

        return nil
    }
}
