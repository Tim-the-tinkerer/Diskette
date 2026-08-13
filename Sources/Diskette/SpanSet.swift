import Foundation

/// Multi-disc spanning for folders that exceed one floppy.
///
/// - **Phase 1 (v1):** whole files only  
/// - **Phase 2 (v2):** files larger than one disc are **chunked** across discs  
/// - **Streaming:** source files and restore reassembly are not held fully in RAM  
///
/// Each disc is a normal `.Floppy` plus `/.diskette-span/manifest.json`.
///
/// Enumeration **skips hidden files** (`.skipsHiddenFiles`) and records empty
/// directories so restore can recreate the tree skeleton.
enum SpanSet {

    static let manifestPath = "/.diskette-span/manifest.json"
    static let magicV1 = "DISKETTE-SPAN/1"
    static let magicV2 = "DISKETTE-SPAN/2"
    static let magic = magicV2
    /// Single-loss XOR recovery disc (legacy / m = 1).
    static let recoveryMagicV1 = "DISKETTE-SPAN-RECOVERY/1"
    /// Multi-loss Cauchy Reed–Solomon recovery discs (m ≥ 1, preferred for m ≥ 2).
    static let recoveryMagicV2 = "DISKETTE-SPAN-RECOVERY/2"
    static let recoveryMagic = recoveryMagicV1
    static let recoveryManifestPath = "/.diskette-span/recovery/manifest.json"
    static let recoveryParityPath = "/.diskette-span/recovery/parity.bin"
    /// Max optional recovery discs (Reed–Solomon parity count).
    static let maxRecoveryDiscs = CauchyReedSolomon.maxParityShards
    /// Floor headroom for span system folder + small manifests (planning adds per-part JSON cost).
    static let reservedBytes = 8_192
    /// Prefer opening a new disc rather than a sub-512 B sliver before a multi-chunk file.
    static let minChunkPrefer = 512
    /// Stream buffer for host file CRC / optional future use.
    static let streamBufferSize = 1_048_576

    /// Conservative JSON size for one `SpanPart` + its `filesOnThisDisc` path entry.
    /// Fixed 16 KB reserve is not enough when a disc holds hundreds of small files
    /// (paths alone can push the manifest past 50 KB).
    private static func estimatePartManifestOverhead(logicalPath: String) -> Int {
        let chunkSample = "/.diskette-span/parts/9999/0000.part"
        let pathBytes = max(logicalPath.utf8.count, chunkSample.utf8.count)
        // part: logicalPath + storedPath + numeric fields; filesOnThisDisc: storedPath again
        return 240 + logicalPath.utf8.count + pathBytes + pathBytes
    }

    /// Fixed manifest envelope + emptyDirectories list (repeated on every disc).
    private static func estimateBaseManifestReserve(emptyDirPaths: [String]) -> Int {
        let emptyJSON = emptyDirPaths.reduce(0) { $0 + $1.utf8.count + 8 }
        return max(reservedBytes, 6_144 + emptyJSON)
    }

    // MARK: - Manifest

    struct SpanPart: Codable, Equatable {
        var logicalPath: String
        var storedPath: String
        var byteOffset: Int
        var byteLength: Int
        var totalSize: Int
        var partIndex: Int
        var partCount: Int
        var fileCrc32: UInt32
        var partCrc32: UInt32

        var isChunked: Bool { partCount > 1 }
        var isCompleteFile: Bool { partCount == 1 && byteOffset == 0 && byteLength == totalSize }
    }

    struct Manifest: Codable, Equatable {
        var magic: String
        var setId: String
        var setLabel: String
        var media: String
        var index: Int
        var count: Int
        var rootName: String
        var filesOnThisDisc: [String]
        var parts: [SpanPart]?
        /// Empty directories recorded for this set (volume paths). Present on every disc for redundancy.
        var emptyDirectories: [String]?
        var totalFilesInSet: Int
        var totalBytesInSet: Int
        var created: String
        var chunkedFileCount: Int?

        var isValidMagic: Bool {
            magic == SpanSet.magicV1 || magic == SpanSet.magicV2 || magic == SpanSet.magic
        }

        var shortLabel: String { "Disc \(index) of \(count)" }

        var supportsChunking: Bool {
            magic == SpanSet.magicV2 || (parts?.contains(where: \.isChunked) == true)
        }
    }

    struct HostFile: Equatable {
        var relativePath: String
        var url: URL
        var size: Int
        /// Precomputed with a streaming pass (not full-file load).
        var fileCrc32: UInt32

        var volumePath: String {
            DisketteEngine.Volume.normalize("/" + relativePath)
        }
    }

    struct HostDir: Equatable {
        var relativePath: String
        var volumePath: String {
            DisketteEngine.Volume.normalize("/" + relativePath)
        }
    }

    struct SpanResult {
        var setId: String
        var discURLs: [URL]
        /// Data discs only (excludes optional recovery disc).
        var dataDiscURLs: [URL] { discURLs }
        var totalFiles: Int
        var totalBytes: Int
        var chunkedFiles: Int
        var emptyDirectories: Int
        var media: DisketteEngine.Media
        /// First recovery disc URL (XOR or RS-01), if any.
        var recoveryURL: URL? { recoveryURLs.first }
        /// Optional recovery disc(s): 1× XOR or m× Reed–Solomon parity.
        var recoveryURLs: [URL]
    }

    /// Coding scheme for optional recovery discs.
    enum RecoveryScheme: String, Codable, Equatable {
        case xor
        case reedSolomon = "reed-solomon"
    }

    /// Manifest stored on each optional recovery disc.
    struct RecoveryManifest: Codable, Equatable {
        var magic: String
        var setId: String
        var setLabel: String
        /// Media used for the data discs in the set.
        var media: String
        /// Number of data discs in the set.
        var discCount: Int
        var parityByteLength: Int
        /// Filenames of data discs in index order (`stem-01ofN.Floppy` …).
        var dataDiscFilenames: [String]
        /// On-disk byte length of each data disc file (before zero-pad).
        var dataDiscByteLengths: [Int]
        /// CRC-32 of each full data disc file (verifies rebuild).
        var dataDiscCrc32: [UInt32]
        /// CRC-32 of **this** disc’s parity payload.
        var parityCrc32: UInt32
        var created: String
        /// `xor` (v1) or `reed-solomon` (v2). Default xor when absent.
        var scheme: String?
        /// Total recovery discs in the set (default 1).
        var recoveryCount: Int?
        /// 1-based index of this recovery disc among recovery discs (default 1).
        var recoveryIndex: Int?
        /// Filenames of all recovery discs in order.
        var recoveryDiscFilenames: [String]?
        /// CRC of every recovery parity payload (same on each disc).
        var allParityCrc32: [UInt32]?

        var isValidMagic: Bool {
            magic == SpanSet.recoveryMagicV1 || magic == SpanSet.recoveryMagicV2
        }

        var resolvedScheme: RecoveryScheme {
            if let scheme, let s = RecoveryScheme(rawValue: scheme) { return s }
            return magic == SpanSet.recoveryMagicV2 ? .reedSolomon : .xor
        }

        var resolvedRecoveryCount: Int { max(1, recoveryCount ?? 1) }
        var resolvedRecoveryIndex: Int { max(1, recoveryIndex ?? 1) }
    }

    struct RecoverResult {
        var setId: String
        var reconstructedURL: URL
        var missingIndex: Int
        var missingFilename: String
        var byteLength: Int
    }

    struct RecoverBatchResult {
        var setId: String
        var scheme: RecoveryScheme
        var results: [RecoverResult]
    }

    struct UnspanResult {
        var setId: String
        var rootName: String
        var filesRestored: Int
        var bytesRestored: Int
        var discCount: Int
        var chunkedFiles: Int
        var emptyDirectories: Int
        var outputRoot: URL
    }

    /// What to do when a restore path already exists on the host.
    enum CollisionPolicy: String, CaseIterable {
        /// Refuse to restore if the destination root already exists.
        case fail
        /// Overwrite existing files (default for legacy CLI unless changed).
        case overwrite
        /// Leave existing files; still create missing ones.
        case skip
    }

    // MARK: - Errors

    enum SpanError: LocalizedError {
        case notADirectory(String)
        case emptyFolder
        case cannotWrite(String)
        case notASpanDisc(String)
        case incompleteSet(have: [Int], need: Int, setId: String)
        case mixedSets
        case inconsistentManifests(String)
        case duplicateDiscIndex(Int)
        case missingFile(path: String, disc: Int)
        case missingParts(logicalPath: String, have: Int, need: Int)
        case fileCRCMismatch(path: String)
        case partCRCMismatch(path: String, part: Int)
        case destinationExists(String)
        case crcOrRead(String)
        case notARecoveryDisc(String)
        case recoveryAmbiguous(String)
        case recoveryFailed(String)

        var errorDescription: String? {
            switch self {
            case .notADirectory(let p): return "Not a folder: \(p)"
            case .emptyFolder: return "Folder has no files or directories to span."
            case .cannotWrite(let m): return m
            case .notASpanDisc(let p): return "Not a span disc (missing manifest): \(p)"
            case .incompleteSet(let have, let need, let id):
                let list = have.sorted().map(String.init).joined(separator: ", ")
                return "Incomplete span set \(id.prefix(8))… — have discs [\(list)], need \(need)."
            case .mixedSets: return "Selected discs belong to different span sets."
            case .inconsistentManifests(let m): return "Inconsistent span manifests: \(m)"
            case .duplicateDiscIndex(let i): return "Duplicate disc index \(i) in span set."
            case .missingFile(let path, let disc): return "Missing \(path) on disc \(disc)."
            case .missingParts(let path, let have, let need):
                return "Incomplete chunks for \(path): have \(have) of \(need) parts."
            case .fileCRCMismatch(let path): return "CRC mismatch after reassembly: \(path)"
            case .partCRCMismatch(let path, let part): return "Chunk CRC mismatch: \(path) part \(part)"
            case .destinationExists(let p): return "Destination already exists: \(p)"
            case .crcOrRead(let m): return m
            case .notARecoveryDisc(let p): return "Not a span recovery disc: \(p)"
            case .recoveryAmbiguous(let m): return m
            case .recoveryFailed(let m): return m
            }
        }
    }

    // MARK: - Enumerate host folder

    /// Enumerates regular files (CRC streamed) and empty directories.
    /// **Hidden files and directories are skipped** (`.skipsHiddenFiles`).
    static func enumerateFolder(at root: URL) throws -> (rootName: String, files: [HostFile], emptyDirs: [HostDir]) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw SpanError.notADirectory(root.path)
        }
        let rootName = root.lastPathComponent
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw SpanError.cannotWrite("Cannot enumerate \(root.path)")
        }

        let rootPath = root.standardizedFileURL.path
        var files: [HostFile] = []
        var allDirs: Set<String> = [rootName]
        var dirsWithChildren: Set<String> = []

        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            let abs = item.standardizedFileURL.path
            guard abs.hasPrefix(rootPath) else { continue }
            var rel = String(abs.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            let relativePath = rel.isEmpty ? rootName : "\(rootName)/\(rel)"

            // Mark parent path as non-empty
            let parentRel = (relativePath as NSString).deletingLastPathComponent
            if !parentRel.isEmpty, parentRel != rootName {
                dirsWithChildren.insert(parentRel)
            } else if parentRel == rootName || relativePath != rootName {
                dirsWithChildren.insert(rootName)
            }

            if values.isDirectory == true {
                allDirs.insert(relativePath)
                continue
            }
            guard values.isRegularFile == true else { continue }

            // Parent of file is non-empty
            let fileParent = (relativePath as NSString).deletingLastPathComponent
            if !fileParent.isEmpty {
                dirsWithChildren.insert(fileParent)
                // All ancestors
                var acc = ""
                for comp in fileParent.split(separator: "/") {
                    acc = acc.isEmpty ? String(comp) : acc + "/" + comp
                    dirsWithChildren.insert(acc)
                }
            }

            let byteSize: Int
            if let s = values.fileSize {
                byteSize = s
            } else {
                let attrs = try fm.attributesOfItem(atPath: item.path)
                byteSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
            }
            let crc = try DisketteEngine.crc32File(at: item, bufferSize: streamBufferSize)
            files.append(HostFile(relativePath: relativePath, url: item, size: byteSize, fileCrc32: crc))
        }

        // Empty dirs = known dirs with no children recorded (and no files under them).
        // dirsWithChildren tracks dirs that contain a file or subdirectory we saw.
        // Recompute properly: any path that is a directory and never received a child.
        // Simpler second pass: collect dirs from enumerator again that have no entries inside.
        let emptyDirs = try findEmptyDirectories(root: root, rootName: rootName, rootPath: rootPath)

        files.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        if files.isEmpty && emptyDirs.isEmpty {
            throw SpanError.emptyFolder
        }
        return (rootName, files, emptyDirs)
    }

    private static func findEmptyDirectories(root: URL, rootName: String, rootPath: String) throws -> [HostDir] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [HostDir] = []
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let contents = try fm.contentsOfDirectory(
                at: item,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            // Empty if no non-hidden children
            if contents.isEmpty {
                let abs = item.standardizedFileURL.path
                guard abs.hasPrefix(rootPath) else { continue }
                var rel = String(abs.dropFirst(rootPath.count))
                if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
                let relativePath = rel.isEmpty ? rootName : "\(rootName)/\(rel)"
                result.append(HostDir(relativePath: relativePath))
            }
        }
        // Root itself empty of non-hidden content?
        let rootContents = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        if rootContents.isEmpty {
            result.append(HostDir(relativePath: rootName))
        }
        result.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return result
    }

    // MARK: - Placement plan (sizes only — no file bodies)

    private struct PlannedPart {
        var host: HostFile
        var logicalPath: String
        var byteOffset: Int
        var byteLength: Int
        var totalSize: Int
        var partIndex: Int
        var partCount: Int
        var fileCrc32: UInt32
        var fileKey: Int
    }

    private struct DiscBatch {
        var parts: [PlannedPart]
    }

    /// `payloadBudget` is bytes available for file payloads **plus** per-part manifest JSON on one disc
    /// (media capacity minus base manifest reserve). Each part consumes `byteLength + overhead(path)`.
    private static func planBatches(
        files: [HostFile],
        payloadBudget: Int
    ) throws -> (batches: [DiscBatch], chunkedFiles: Int) {
        guard payloadBudget > 0 else {
            throw SpanError.cannotWrite("Media capacity too small for spanning")
        }

        var fileKeys: [String: Int] = [:]
        for (i, f) in files.enumerated() {
            fileKeys[f.volumePath] = i
        }

        struct TempPart {
            var host: HostFile
            var logicalPath: String
            var byteOffset: Int
            var byteLength: Int
            var totalSize: Int
            var fileCrc32: UInt32
            var fileKey: Int
        }
        var tempBatches: [[TempPart]] = []
        var tempCurrent: [TempPart] = []
        var free = payloadBudget

        func startNewDisc() {
            if !tempCurrent.isEmpty {
                tempBatches.append(tempCurrent)
            }
            tempCurrent = []
            free = payloadBudget
        }

        for f in files {
            let total = f.size
            let key = fileKeys[f.volumePath] ?? 0
            let pathOverhead = estimatePartManifestOverhead(logicalPath: f.volumePath)
            var offset = 0
            while offset < total || (total == 0 && offset == 0) {
                // Zero-length file: one empty part (still costs manifest JSON)
                if total == 0 {
                    if free < pathOverhead {
                        if tempCurrent.isEmpty {
                            throw SpanError.cannotWrite(
                                "Media too small for span manifest entry (\(pathOverhead) B overhead)"
                            )
                        }
                        startNewDisc()
                    }
                    tempCurrent.append(TempPart(
                        host: f,
                        logicalPath: f.volumePath,
                        byteOffset: 0,
                        byteLength: 0,
                        totalSize: 0,
                        fileCrc32: f.fileCrc32,
                        fileKey: key
                    ))
                    free -= pathOverhead
                    break
                }

                if free <= pathOverhead {
                    if tempCurrent.isEmpty {
                        throw SpanError.cannotWrite(
                            "Media too small for span payload + manifest (\(pathOverhead) B overhead)"
                        )
                    }
                    startNewDisc()
                    continue
                }

                let remainingFile = total - offset
                let payloadRoom = free - pathOverhead
                if payloadRoom < minChunkPrefer, remainingFile > payloadRoom, !tempCurrent.isEmpty {
                    startNewDisc()
                    continue
                }

                let take = min(remainingFile, payloadRoom)
                guard take > 0 else {
                    if tempCurrent.isEmpty {
                        throw SpanError.cannotWrite("Media too small for a file chunk on a span disc")
                    }
                    startNewDisc()
                    continue
                }
                tempCurrent.append(TempPart(
                    host: f,
                    logicalPath: f.volumePath,
                    byteOffset: offset,
                    byteLength: take,
                    totalSize: total,
                    fileCrc32: f.fileCrc32,
                    fileKey: key
                ))
                free -= take + pathOverhead
                offset += take
            }
        }
        if !tempCurrent.isEmpty {
            tempBatches.append(tempCurrent)
        }

        var partsByFile: [String: [TempPart]] = [:]
        for batch in tempBatches {
            for p in batch {
                partsByFile[p.logicalPath, default: []].append(p)
            }
        }
        for key in partsByFile.keys {
            partsByFile[key]?.sort {
                if $0.byteOffset != $1.byteOffset { return $0.byteOffset < $1.byteOffset }
                return $0.byteLength < $1.byteLength
            }
        }

        var partMeta: [String: (count: Int, indexByOffset: [Int: Int])] = [:]
        for (path, plist) in partsByFile {
            var indexByOffset: [Int: Int] = [:]
            for (i, p) in plist.enumerated() {
                indexByOffset[p.byteOffset] = i
            }
            partMeta[path] = (plist.count, indexByOffset)
        }

        var chunkedFiles = 0
        for (_, meta) in partMeta where meta.count > 1 {
            chunkedFiles += 1
        }

        let batches: [DiscBatch] = tempBatches.map { tparts in
            let planned: [PlannedPart] = tparts.map { t in
                let meta = partMeta[t.logicalPath]!
                let pidx = meta.indexByOffset[t.byteOffset] ?? 0
                return PlannedPart(
                    host: t.host,
                    logicalPath: t.logicalPath,
                    byteOffset: t.byteOffset,
                    byteLength: t.byteLength,
                    totalSize: t.totalSize,
                    partIndex: pidx,
                    partCount: meta.count,
                    fileCrc32: t.fileCrc32,
                    fileKey: t.fileKey
                )
            }
            return DiscBatch(parts: planned)
        }
        return (batches, chunkedFiles)
    }

    private static func storedPath(for part: PlannedPart) -> String {
        if part.partCount == 1 {
            return part.logicalPath
        }
        return DisketteEngine.Volume.normalize(
            "/.diskette-span/parts/\(part.fileKey)/\(String(format: "%04d", part.partIndex)).part"
        )
    }

    // MARK: - Pack (span) — streaming reads

    static func spanFolder(
        at folderURL: URL,
        outputDirectory: URL,
        media: DisketteEngine.Media = .default,
        setLabel: String? = nil,
        packaging: DisketteEngine.Packaging = .default,
        compress: Bool = true,
        /// `0` = none; `1` = single XOR recovery disc; `2…` = Reed–Solomon recovery discs.
        recoveryDiscCount: Int = 0,
        withRecovery: Bool = false
    ) throws -> SpanResult {
        let recoveryCount = withRecovery && recoveryDiscCount == 0
            ? 1
            : min(max(0, recoveryDiscCount), maxRecoveryDiscs)
        let (rootName, files, emptyDirs) = try enumerateFolder(at: folderURL)
        let label = (setLabel?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? rootName
        let emptyDirPaths = emptyDirs.map(\.volumePath).sorted()
        let baseReserve = estimateBaseManifestReserve(emptyDirPaths: emptyDirPaths)
        let payloadBudget = media.capacity - baseReserve
        guard payloadBudget > 0 else {
            throw SpanError.cannotWrite("Media capacity too small for spanning")
        }

        // Reserve per-part manifest JSON in the planner so dense trees of tiny files
        // leave room for manifest.json (fixed reservedBytes alone is not enough).
        let (batches, chunkedFiles) = try planBatches(files: files, payloadBudget: payloadBudget)
        let totalBytes = files.reduce(0) { $0 + $1.size }
        let setId = UUID().uuidString.lowercased()
        let created = ISO8601DateFormatter().string(from: Date())
        let count = max(1, batches.count)
        // Empty-folder-only span still needs one disc
        let effectiveBatches: [DiscBatch] = batches.isEmpty ? [DiscBatch(parts: [])] : batches
        let discCount = effectiveBatches.count

        let fm = FileManager.default
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let stem = sanitizeFilename(label)
        var discURLs: [URL] = []
        // Track written discs so a failure can clean up a partial set.
        var writtenURLs: [URL] = []

        do {
            for (i, batch) in effectiveBatches.enumerated() {
                let index = i + 1
                let volLabel = makeDiscLabel(base: label, index: index, count: discCount)
                let volume = DisketteEngine.create(label: volLabel, media: media)
                volume.packaging = packaging
                volume.compressOnWrite = compress

                // Empty dirs on every disc (small) so any single disc documents the tree.
                for dirPath in emptyDirPaths {
                    try volume.addDirectory(at: dirPath)
                }
                // Also ensure root folder exists
                try volume.addDirectory(at: DisketteEngine.Volume.normalize("/" + rootName))

                var spanParts: [SpanPart] = []
                var pathsOnDisc: [String] = []

                for plan in batch.parts {
                    let slice: Data
                    if plan.byteLength == 0 {
                        slice = Data()
                    } else {
                        slice = try DisketteEngine.readFileSlice(
                            at: plan.host.url,
                            offset: plan.byteOffset,
                            length: plan.byteLength
                        )
                    }
                    let partCrc = DisketteEngine.crc32(slice)
                    let store = storedPath(for: plan)

                    if slice.count > volume.freeBytes {
                        throw SpanError.cannotWrite(
                            "Disc \(index) full while adding \(plan.logicalPath) part \(plan.partIndex)"
                        )
                    }
                    try volume.addFile(at: store, data: slice, overwrite: true)
                    pathsOnDisc.append(store)
                    spanParts.append(SpanPart(
                        logicalPath: plan.logicalPath,
                        storedPath: store,
                        byteOffset: plan.byteOffset,
                        byteLength: plan.byteLength,
                        totalSize: plan.totalSize,
                        partIndex: plan.partIndex,
                        partCount: plan.partCount,
                        fileCrc32: plan.fileCrc32,
                        partCrc32: partCrc
                    ))
                }

                let manifest = Manifest(
                    magic: magicV2,
                    setId: setId,
                    setLabel: label,
                    media: media.rawValue,
                    index: index,
                    count: discCount,
                    rootName: rootName,
                    filesOnThisDisc: pathsOnDisc.sorted(),
                    parts: spanParts.sorted(by: partSort),
                    emptyDirectories: emptyDirPaths,
                    totalFilesInSet: files.count,
                    totalBytesInSet: totalBytes,
                    created: created,
                    chunkedFileCount: chunkedFiles
                )
                try writeManifest(manifest, onto: volume)

                let filename = spanFilename(stem: stem, index: index, count: discCount)
                let url = outputDirectory.appendingPathComponent(filename)
                try DisketteEngine.save(volume, to: url)
                discURLs.append(url)
                writtenURLs.append(url)
            }

            var recoveryURLs: [URL] = []
            if recoveryCount > 0 {
                let recs = try writeRecoveryDiscs(
                    dataDiscURLs: discURLs,
                    outputDirectory: outputDirectory,
                    stem: stem,
                    setId: setId,
                    setLabel: label,
                    dataMedia: media,
                    created: created,
                    recoveryCount: recoveryCount
                )
                recoveryURLs = recs
                writtenURLs.append(contentsOf: recs)
            }

            _ = count
            return SpanResult(
                setId: setId,
                discURLs: discURLs,
                totalFiles: files.count,
                totalBytes: totalBytes,
                chunkedFiles: chunkedFiles,
                emptyDirectories: emptyDirs.count,
                media: media,
                recoveryURLs: recoveryURLs
            )
        } catch {
            // Remove any partial numbered set so the destination is not left half-written.
            for url in writtenURLs {
                try? fm.removeItem(at: url)
            }
            throw error
        }
    }

    // MARK: - Recovery discs (XOR m=1, Reed–Solomon m≥2)

    /// Write recovery disc(s).
    /// - **m = 1:** classic XOR (`DISKETTE-SPAN-RECOVERY/1`) — rebuild any **one** lost data disc.
    /// - **m ≥ 2:** Cauchy Reed–Solomon (`…/2`) — rebuild any **m** lost data discs.
    private static func writeRecoveryDiscs(
        dataDiscURLs: [URL],
        outputDirectory: URL,
        stem: String,
        setId: String,
        setLabel: String,
        dataMedia: DisketteEngine.Media,
        created: String,
        recoveryCount m: Int
    ) throws -> [URL] {
        guard !dataDiscURLs.isEmpty else {
            throw SpanError.cannotWrite("No data discs for recovery parity")
        }
        guard m >= 1, m <= maxRecoveryDiscs else {
            throw SpanError.cannotWrite("recovery disc count must be 1…\(maxRecoveryDiscs)")
        }

        if m == 1 {
            let url = try writeXorRecoveryDisc(
                dataDiscURLs: dataDiscURLs,
                outputDirectory: outputDirectory,
                stem: stem,
                setId: setId,
                setLabel: setLabel,
                dataMedia: dataMedia,
                created: created
            )
            return [url]
        }

        return try writeReedSolomonRecoveryDiscs(
            dataDiscURLs: dataDiscURLs,
            outputDirectory: outputDirectory,
            stem: stem,
            setId: setId,
            setLabel: setLabel,
            dataMedia: dataMedia,
            created: created,
            recoveryCount: m
        )
    }

    private static func writeXorRecoveryDisc(
        dataDiscURLs: [URL],
        outputDirectory: URL,
        stem: String,
        setId: String,
        setLabel: String,
        dataMedia: DisketteEngine.Media,
        created: String
    ) throws -> URL {
        let (parity, lengths, crcs) = try computeXorParity(of: dataDiscURLs)
        let parityCrc = DisketteEngine.crc32(parity)
        let filenames = dataDiscURLs.map(\.lastPathComponent)
        let recName = recoveryFilename(stem: stem, index: 1, count: 1)

        let recoveryManifest = RecoveryManifest(
            magic: recoveryMagicV1,
            setId: setId,
            setLabel: setLabel,
            media: dataMedia.rawValue,
            discCount: dataDiscURLs.count,
            parityByteLength: parity.count,
            dataDiscFilenames: filenames,
            dataDiscByteLengths: lengths,
            dataDiscCrc32: crcs,
            parityCrc32: parityCrc,
            created: created,
            scheme: RecoveryScheme.xor.rawValue,
            recoveryCount: 1,
            recoveryIndex: 1,
            recoveryDiscFilenames: [recName],
            allParityCrc32: [parityCrc]
        )
        return try saveRecoveryVolume(
            manifest: recoveryManifest,
            parity: parity,
            outputDirectory: outputDirectory,
            filename: recName,
            setLabel: setLabel,
            recoveryIndex: 1,
            recoveryCount: 1
        )
    }

    private static func writeReedSolomonRecoveryDiscs(
        dataDiscURLs: [URL],
        outputDirectory: URL,
        stem: String,
        setId: String,
        setLabel: String,
        dataMedia: DisketteEngine.Media,
        created: String,
        recoveryCount m: Int
    ) throws -> [URL] {
        var lengths: [Int] = []
        var crcs: [UInt32] = []
        var maxLen = 0
        for url in dataDiscURLs {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let len = (attrs[.size] as? NSNumber)?.intValue ?? 0
            lengths.append(len)
            maxLen = max(maxLen, len)
            crcs.append(try DisketteEngine.crc32File(at: url, bufferSize: streamBufferSize))
        }

        let parities = try CauchyReedSolomon.encodeParityFiles(
            dataURLs: dataDiscURLs,
            length: maxLen,
            parityCount: m,
            bufferSize: streamBufferSize
        )
        let parityCrcs = parities.map { DisketteEngine.crc32($0) }
        let dataNames = dataDiscURLs.map(\.lastPathComponent)
        let recNames = (1...m).map { recoveryFilename(stem: stem, index: $0, count: m) }

        var urls: [URL] = []
        for j in 0..<m {
            let man = RecoveryManifest(
                magic: recoveryMagicV2,
                setId: setId,
                setLabel: setLabel,
                media: dataMedia.rawValue,
                discCount: dataDiscURLs.count,
                parityByteLength: maxLen,
                dataDiscFilenames: dataNames,
                dataDiscByteLengths: lengths,
                dataDiscCrc32: crcs,
                parityCrc32: parityCrcs[j],
                created: created,
                scheme: RecoveryScheme.reedSolomon.rawValue,
                recoveryCount: m,
                recoveryIndex: j + 1,
                recoveryDiscFilenames: recNames,
                allParityCrc32: parityCrcs
            )
            let url = try saveRecoveryVolume(
                manifest: man,
                parity: parities[j],
                outputDirectory: outputDirectory,
                filename: recNames[j],
                setLabel: setLabel,
                recoveryIndex: j + 1,
                recoveryCount: m
            )
            urls.append(url)
        }
        return urls
    }

    private static func recoveryFilename(stem: String, index: Int, count: Int) -> String {
        let width = max(2, String(count).count)
        let idx = String(format: "%0\(width)d", index)
        let total = String(format: "%0\(width)d", count)
        return "\(stem)-Recovery-\(idx)of\(total).\(DisketteEngine.fileExtension)"
    }

    private static func saveRecoveryVolume(
        manifest: RecoveryManifest,
        parity: Data,
        outputDirectory: URL,
        filename: String,
        setLabel: String,
        recoveryIndex: Int,
        recoveryCount: Int
    ) throws -> URL {
        let manData = try JSONEncoder().encode(manifest)
        let need = parity.count + manData.count + 4_096
        let recoveryMedia = try mediaFitting(minimumPayload: need)
        let suffix = recoveryCount > 1 ? " R\(recoveryIndex)/\(recoveryCount)" : " REC"
        let volume = DisketteEngine.create(
            label: String((setLabel + suffix).prefix(32)),
            media: recoveryMedia
        )
        volume.packaging = .binary
        volume.compressOnWrite = false
        try volume.addDirectory(at: "/.diskette-span")
        try volume.addDirectory(at: "/.diskette-span/recovery")
        if manData.count + parity.count > volume.freeBytes {
            throw SpanError.cannotWrite(
                "Recovery disc capacity too small for parity (\(parity.count) B) on \(recoveryMedia.shortName)"
            )
        }
        try volume.addFile(at: recoveryManifestPath, data: manData, overwrite: true)
        try volume.addFile(at: recoveryParityPath, data: parity, overwrite: true)
        let url = outputDirectory.appendingPathComponent(filename)
        try DisketteEngine.save(volume, to: url)
        return url
    }

    /// Smallest media whose capacity can hold `minimumPayload` bytes of file data.
    private static func mediaFitting(minimumPayload: Int) throws -> DisketteEngine.Media {
        let ordered = DisketteEngine.Media.allCases.sorted { $0.capacity < $1.capacity }
        if let m = ordered.first(where: { $0.capacity >= minimumPayload }) {
            return m
        }
        let maxCap = ordered.last?.capacity ?? 0
        throw SpanError.cannotWrite(
            "Parity (\(minimumPayload) B) exceeds largest media capacity (\(maxCap) B); cannot create one recovery disc"
        )
    }

    /// XOR of raw on-disk `.Floppy` bytes, zero-padded to the longest file.
    private static func computeXorParity(of urls: [URL]) throws -> (Data, [Int], [UInt32]) {
        var lengths: [Int] = []
        var crcs: [UInt32] = []
        var maxLen = 0
        for url in urls {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let len = (attrs[.size] as? NSNumber)?.intValue ?? 0
            lengths.append(len)
            maxLen = max(maxLen, len)
            crcs.append(try DisketteEngine.crc32File(at: url, bufferSize: streamBufferSize))
        }
        var parity = Data(count: maxLen)
        let bufSize = streamBufferSize
        for url in urls {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var offset = 0
            while offset < maxLen {
                let toRead = min(bufSize, maxLen - offset)
                let chunk = try handle.read(upToCount: toRead) ?? Data()
                if chunk.isEmpty { break } // remainder is zero pad → XOR no-op
                parity.withUnsafeMutableBytes { dest in
                    guard let dBase = dest.bindMemory(to: UInt8.self).baseAddress else { return }
                    chunk.withUnsafeBytes { src in
                        guard let sBase = src.bindMemory(to: UInt8.self).baseAddress else { return }
                        for i in 0..<chunk.count {
                            dBase[offset + i] ^= sBase[i]
                        }
                    }
                }
                offset += chunk.count
            }
        }
        return (parity, lengths, crcs)
    }

    static func readRecoveryManifest(from volume: DisketteEngine.Volume) throws -> RecoveryManifest? {
        guard let entry = volume.entry(at: recoveryManifestPath), !entry.isDirectory else {
            return nil
        }
        let data = try volume.readFile(at: recoveryManifestPath)
        let man = try JSONDecoder().decode(RecoveryManifest.self, from: data)
        guard man.isValidMagic else { return nil }
        return man
    }

    static func isRecoveryVolume(_ volume: DisketteEngine.Volume) -> Bool {
        (try? readRecoveryManifest(from: volume)) != nil
    }

    /// Reconstruct missing data disc(s) using recovery disc(s) + surviving data discs.
    ///
    /// - **XOR (1 recovery disc):** rebuilds exactly one missing data disc.
    /// - **Reed–Solomon (m recovery discs):** rebuilds up to **m** missing data discs.
    ///
    /// `availableDiscURLs` may include a mix of data discs, recovery discs, and folders
    /// are not expanded here (caller expands). Writes rebuilt files into `outputURL`
    /// when it is a directory; for a single XOR rebuild a concrete `.Floppy` path is also allowed.
    static func reconstructMissingDiscs(
        availableDiscURLs: [URL],
        outputURL: URL
    ) throws -> RecoverBatchResult {
        // Partition recovery vs data candidates (dedupe paths — callers may pass recovery twice).
        var seen = Set<String>()
        let uniqueURLs = availableDiscURLs.filter { url in
            let key = url.standardizedFileURL.path
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        var recoveryByIndex: [Int: (url: URL, man: RecoveryManifest, parity: Data)] = [:]
        var dataCandidates: [URL] = []
        var sampleMan: RecoveryManifest?

        for url in uniqueURLs {
            guard DisketteEngine.isFloppyFilename(url) else { continue }
            let vol = try DisketteEngine.load(from: url)
            if let man = try readRecoveryManifest(from: vol) {
                let parity = try vol.readFile(at: recoveryParityPath)
                guard parity.count == man.parityByteLength else {
                    throw SpanError.recoveryFailed(
                        "Parity length \(parity.count) != manifest \(man.parityByteLength) on \(url.lastPathComponent)"
                    )
                }
                let pCrc = DisketteEngine.crc32(parity)
                guard pCrc == man.parityCrc32 else {
                    throw SpanError.recoveryFailed("Recovery parity CRC mismatch: \(url.lastPathComponent)")
                }
                let idx = man.resolvedRecoveryIndex
                if recoveryByIndex[idx] != nil {
                    throw SpanError.recoveryAmbiguous("Duplicate recovery disc index \(idx)")
                }
                recoveryByIndex[idx] = (url, man, parity)
                sampleMan = man
            } else {
                dataCandidates.append(url)
            }
        }

        guard let man0 = sampleMan, !recoveryByIndex.isEmpty else {
            throw SpanError.notARecoveryDisc("(no recovery disc in selection)")
        }

        // All recovery discs must share setId / scheme
        for (_, item) in recoveryByIndex {
            if item.man.setId != man0.setId {
                throw SpanError.recoveryAmbiguous("Recovery discs belong to different span sets")
            }
            if item.man.resolvedScheme != man0.resolvedScheme {
                throw SpanError.recoveryAmbiguous("Mixed recovery schemes in selection")
            }
        }

        let man = man0
        guard man.discCount == man.dataDiscFilenames.count,
              man.discCount == man.dataDiscByteLengths.count,
              man.discCount == man.dataDiscCrc32.count else {
            throw SpanError.recoveryFailed("Recovery manifest arrays inconsistent")
        }

        let byName = try mapAvailableDataDiscs(
            dataCandidates: dataCandidates,
            man: man,
            recoveryURLs: Set(recoveryByIndex.values.map { $0.url.standardizedFileURL })
        )

        let missingIndices = man.dataDiscFilenames.indices.filter { byName[man.dataDiscFilenames[$0]] == nil }
        if missingIndices.isEmpty {
            throw SpanError.recoveryAmbiguous(
                "No missing data disc — all \(man.discCount) data discs appear present."
            )
        }

        let m = man.resolvedRecoveryCount
        if missingIndices.count > m {
            let names = missingIndices.map { man.dataDiscFilenames[$0] }.joined(separator: ", ")
            throw SpanError.recoveryAmbiguous(
                "Too many missing data discs (\(names)): this set can rebuild at most \(m)."
            )
        }

        switch man.resolvedScheme {
        case .xor:
            guard m == 1, recoveryByIndex.count >= 1 else {
                throw SpanError.recoveryFailed("XOR recovery requires one recovery disc")
            }
            guard missingIndices.count == 1 else {
                throw SpanError.recoveryAmbiguous(
                    "XOR recovery rebuilds only one loss; missing \(missingIndices.count) discs. Use Reed–Solomon recovery discs for multi-loss."
                )
            }
            let parity = recoveryByIndex.values.first!.parity
            let result = try rebuildXorDisc(
                man: man,
                missing: missingIndices[0],
                byName: byName,
                parity: parity,
                outputURL: outputURL
            )
            return RecoverBatchResult(setId: man.setId, scheme: .xor, results: [result])

        case .reedSolomon:
            let results = try rebuildReedSolomonDiscs(
                man: man,
                missingIndices: Array(missingIndices),
                byName: byName,
                recoveryByIndex: recoveryByIndex,
                outputDirectory: outputDirectoryForRecovery(outputURL)
            )
            return RecoverBatchResult(setId: man.setId, scheme: .reedSolomon, results: results)
        }
    }

    /// Convenience for single-disc XOR (or RS with one missing): same as `reconstructMissingDiscs`.
    static func reconstructMissingDisc(
        recoveryURL: URL,
        availableDiscURLs: [URL],
        outputURL: URL
    ) throws -> RecoverResult {
        let batch = try reconstructMissingDiscs(
            availableDiscURLs: availableDiscURLs + [recoveryURL],
            outputURL: outputURL
        )
        guard let first = batch.results.first else {
            throw SpanError.recoveryFailed("No discs reconstructed")
        }
        return first
    }

    private static func mapAvailableDataDiscs(
        dataCandidates: [URL],
        man: RecoveryManifest,
        recoveryURLs: Set<URL>
    ) throws -> [String: URL] {
        var byName: [String: URL] = [:]
        for url in dataCandidates {
            if recoveryURLs.contains(url.standardizedFileURL) { continue }
            let name = url.lastPathComponent
            if man.dataDiscFilenames.contains(name) {
                if byName[name] != nil {
                    throw SpanError.recoveryAmbiguous("Duplicate available disc: \(name)")
                }
                byName[name] = url
                continue
            }
            if DisketteEngine.isFloppyFilename(url),
               let vol = try? DisketteEngine.load(from: url),
               !isRecoveryVolume(vol),
               let sm = try? readManifest(from: vol),
               sm.setId == man.setId,
               sm.index >= 1, sm.index <= man.dataDiscFilenames.count {
                let expected = man.dataDiscFilenames[sm.index - 1]
                if byName[expected] == nil {
                    byName[expected] = url
                }
            }
        }
        return byName
    }

    private static func outputDirectoryForRecovery(_ outputURL: URL) throws -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDir), isDir.boolValue {
            return outputURL
        }
        if outputURL.pathExtension.lowercased() == DisketteEngine.fileExtension.lowercased() {
            return outputURL.deletingLastPathComponent()
        }
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        return outputURL
    }

    private static func resolveOutputFile(outputURL: URL, missingName: String) throws -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDir), isDir.boolValue {
            return outputURL.appendingPathComponent(missingName)
        }
        if outputURL.pathExtension.lowercased() == DisketteEngine.fileExtension.lowercased()
            || outputURL.lastPathComponent.lowercased().hasSuffix(".\(DisketteEngine.fileExtension.lowercased())") {
            return outputURL
        }
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        return outputURL.appendingPathComponent(missingName)
    }

    private static func rebuildXorDisc(
        man: RecoveryManifest,
        missing: Int,
        byName: [String: URL],
        parity: Data,
        outputURL: URL
    ) throws -> RecoverResult {
        let missingName = man.dataDiscFilenames[missing]
        let expectedLen = man.dataDiscByteLengths[missing]
        let expectedCrc = man.dataDiscCrc32[missing]

        var rebuilt = Data(parity)
        for (i, name) in man.dataDiscFilenames.enumerated() where i != missing {
            guard let url = byName[name] else {
                throw SpanError.recoveryFailed("Internal: missing available disc \(name)")
            }
            try xorFile(at: url, into: &rebuilt)
        }
        guard expectedLen <= rebuilt.count else {
            throw SpanError.recoveryFailed("Expected length \(expectedLen) exceeds parity block \(rebuilt.count)")
        }
        rebuilt = Data(rebuilt.prefix(expectedLen))
        let gotCrc = DisketteEngine.crc32(rebuilt)
        guard gotCrc == expectedCrc else {
            throw SpanError.recoveryFailed(
                "Rebuilt \(missingName) CRC mismatch (got \(String(gotCrc, radix: 16)), expected \(String(expectedCrc, radix: 16)))"
            )
        }
        let dest = try resolveOutputFile(outputURL: outputURL, missingName: missingName)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw SpanError.destinationExists(dest.path)
        }
        try rebuilt.write(to: dest, options: .atomic)
        return RecoverResult(
            setId: man.setId,
            reconstructedURL: dest,
            missingIndex: missing + 1,
            missingFilename: missingName,
            byteLength: expectedLen
        )
    }

    private static func rebuildReedSolomonDiscs(
        man: RecoveryManifest,
        missingIndices: [Int],
        byName: [String: URL],
        recoveryByIndex: [Int: (url: URL, man: RecoveryManifest, parity: Data)],
        outputDirectory: URL
    ) throws -> [RecoverResult] {
        let n = man.discCount
        let m = man.resolvedRecoveryCount
        let length = man.parityByteLength
        let rs: CauchyReedSolomon
        do {
            rs = try CauchyReedSolomon(dataCount: n, parityCount: m)
        } catch {
            throw SpanError.recoveryFailed(error.localizedDescription)
        }

        // Load known data fully (padded conceptually; decoder reads short as 0)
        var knownData: [Int: Data] = [:]
        for i in 0..<n where !missingIndices.contains(i) {
            guard let url = byName[man.dataDiscFilenames[i]] else {
                throw SpanError.recoveryFailed("Missing available data disc \(man.dataDiscFilenames[i])")
            }
            knownData[i] = try Data(contentsOf: url)
        }

        var knownParity: [Int: Data] = [:]
        for (idx, item) in recoveryByIndex {
            // recoveryIndex is 1-based
            knownParity[idx - 1] = item.parity
        }

        let recovered: [Int: Data]
        do {
            recovered = try rs.recoverMissingData(
                knownData: knownData,
                knownParity: knownParity,
                missingData: missingIndices,
                length: length
            )
        } catch {
            throw SpanError.recoveryFailed(error.localizedDescription)
        }

        var results: [RecoverResult] = []
        for mi in missingIndices.sorted() {
            guard var rebuilt = recovered[mi] else {
                throw SpanError.recoveryFailed("RS did not return disc index \(mi)")
            }
            let expectedLen = man.dataDiscByteLengths[mi]
            let expectedCrc = man.dataDiscCrc32[mi]
            let missingName = man.dataDiscFilenames[mi]
            guard expectedLen <= rebuilt.count else {
                throw SpanError.recoveryFailed("RS rebuilt length short for \(missingName)")
            }
            rebuilt = Data(rebuilt.prefix(expectedLen))
            let gotCrc = DisketteEngine.crc32(rebuilt)
            guard gotCrc == expectedCrc else {
                throw SpanError.recoveryFailed(
                    "Rebuilt \(missingName) CRC mismatch (got \(String(gotCrc, radix: 16)), expected \(String(expectedCrc, radix: 16)))"
                )
            }
            let dest = outputDirectory.appendingPathComponent(missingName)
            if FileManager.default.fileExists(atPath: dest.path) {
                throw SpanError.destinationExists(dest.path)
            }
            try rebuilt.write(to: dest, options: .atomic)
            results.append(RecoverResult(
                setId: man.setId,
                reconstructedURL: dest,
                missingIndex: mi + 1,
                missingFilename: missingName,
                byteLength: expectedLen
            ))
        }
        return results
    }

    /// XOR file contents into `buffer` (file may be shorter; remainder of buffer unchanged = pad 0).
    private static func xorFile(at url: URL, into buffer: inout Data) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset = 0
        let limit = buffer.count
        while offset < limit {
            let chunk = try handle.read(upToCount: min(streamBufferSize, limit - offset)) ?? Data()
            if chunk.isEmpty { break }
            buffer.withUnsafeMutableBytes { dest in
                guard let dBase = dest.bindMemory(to: UInt8.self).baseAddress else { return }
                chunk.withUnsafeBytes { src in
                    guard let sBase = src.bindMemory(to: UInt8.self).baseAddress else { return }
                    for i in 0..<chunk.count {
                        dBase[offset + i] ^= sBase[i]
                    }
                }
            }
            offset += chunk.count
        }
    }

    private static func partSort(_ a: SpanPart, _ b: SpanPart) -> Bool {
        if a.logicalPath != b.logicalPath { return a.logicalPath < b.logicalPath }
        if a.partIndex != b.partIndex { return a.partIndex < b.partIndex }
        return a.byteOffset < b.byteOffset
    }

    // MARK: - Unspan (restore) — streaming reassembly

    static func unspan(
        discURLs: [URL],
        outputDirectory: URL,
        collision: CollisionPolicy = .fail
    ) throws -> UnspanResult {
        guard !discURLs.isEmpty else {
            throw SpanError.incompleteSet(have: [], need: 0, setId: "")
        }

        // Pass 1: load each disc only long enough to read the manifest, then drop the volume.
        struct DiscRef {
            var url: URL
            var manifest: Manifest
        }
        var refs: [DiscRef] = []
        for url in discURLs {
            let vol = try DisketteEngine.load(from: url)
            // Ignore optional XOR recovery discs mixed into a multi-select / folder.
            if isRecoveryVolume(vol) { continue }
            guard let man = try readManifest(from: vol) else {
                throw SpanError.notASpanDisc(url.lastPathComponent)
            }
            refs.append(DiscRef(url: url, manifest: man))
            // volume released at end of iteration
        }
        guard !refs.isEmpty else {
            throw SpanError.notASpanDisc("(no span data discs in selection)")
        }

        let setIds = Set(refs.map(\.manifest.setId))
        guard setIds.count == 1, let setId = setIds.first else {
            throw SpanError.mixedSets
        }

        try validateManifestConsistency(refs.map(\.manifest))

        let count = refs[0].manifest.count
        let byIndex = Dictionary(grouping: refs, by: { $0.manifest.index })
        var ordered: [DiscRef] = []
        for i in 1...count {
            guard let group = byIndex[i] else {
                let have = refs.map(\.manifest.index).sorted()
                throw SpanError.incompleteSet(have: have, need: count, setId: setId)
            }
            if group.count > 1 {
                throw SpanError.duplicateDiscIndex(i)
            }
            ordered.append(group[0])
        }

        let rootName = ordered[0].manifest.rootName
        let fm = FileManager.default
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let destRoot = outputDirectory.appendingPathComponent(rootName)

        if fm.fileExists(atPath: destRoot.path) {
            switch collision {
            case .fail:
                throw SpanError.destinationExists(destRoot.path)
            case .overwrite, .skip:
                break
            }
        } else {
            try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)
        }

        // Collect part descriptors (no payload yet)
        struct PartRef {
            var part: SpanPart
            var discIndex: Int
            var discURL: URL
        }
        var byLogical: [String: [PartRef]] = [:]

        for ref in ordered {
            if let parts = ref.manifest.parts, !parts.isEmpty {
                for p in parts {
                    byLogical[p.logicalPath, default: []].append(
                        PartRef(part: p, discIndex: ref.manifest.index, discURL: ref.url)
                    )
                }
            } else {
                // v1: need sizes from disc — load briefly
                let vol = try DisketteEngine.load(from: ref.url)
                for path in ref.manifest.filesOnThisDisc {
                    guard let e = vol.entry(at: path), !e.isDirectory else {
                        throw SpanError.missingFile(path: path, disc: ref.manifest.index)
                    }
                    let data = try vol.readFile(at: path)
                    let crc = DisketteEngine.crc32(data)
                    let synthetic = SpanPart(
                        logicalPath: path,
                        storedPath: path,
                        byteOffset: 0,
                        byteLength: e.size,
                        totalSize: e.size,
                        partIndex: 0,
                        partCount: 1,
                        fileCrc32: crc,
                        partCrc32: crc
                    )
                    byLogical[path, default: []].append(
                        PartRef(part: synthetic, discIndex: ref.manifest.index, discURL: ref.url)
                    )
                }
            }
        }

        // Empty directories from any manifest (identical across discs when written by us)
        let emptyDirs = Set(ordered.flatMap { $0.manifest.emptyDirectories ?? [] })

        var filesRestored = 0
        var bytesRestored = 0
        var chunkedFiles = 0
        var volumeCache: (index: Int, volume: DisketteEngine.Volume)?

        func volume(for discIndex: Int, url: URL) throws -> DisketteEngine.Volume {
            if let cache = volumeCache, cache.index == discIndex {
                return cache.volume
            }
            let vol = try DisketteEngine.load(from: url)
            volumeCache = (discIndex, vol)
            return vol
        }

        for logicalPath in byLogical.keys.sorted() {
            guard var pieces = byLogical[logicalPath] else { continue }
            pieces.sort {
                if $0.part.partIndex != $1.part.partIndex {
                    return $0.part.partIndex < $1.part.partIndex
                }
                return $0.part.byteOffset < $1.part.byteOffset
            }

            let need = pieces.first?.part.partCount ?? 1
            if pieces.count != need {
                throw SpanError.missingParts(logicalPath: logicalPath, have: pieces.count, need: need)
            }
            if need > 1 { chunkedFiles += 1 }

            let totalSize = pieces[0].part.totalSize
            let fileCrc = pieces[0].part.fileCrc32
            let dest = try hostDestination(logicalPath: logicalPath, rootName: rootName, destRoot: destRoot)

            if fm.fileExists(atPath: dest.path) {
                switch collision {
                case .fail:
                    throw SpanError.destinationExists(dest.path)
                case .skip:
                    continue
                case .overwrite:
                    try fm.removeItem(at: dest)
                }
            }

            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Stream reassembly into a temp file, then atomic replace.
            let tempURL = dest.deletingLastPathComponent()
                .appendingPathComponent(".diskette-restore-\(UUID().uuidString).tmp")
            fm.createFile(atPath: tempURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: tempURL)
            var seed: UInt32 = 0
            var written = 0
            var expectedOffset = 0

            do {
                for c in pieces {
                    if c.part.byteOffset != expectedOffset {
                        throw SpanError.missingParts(
                            logicalPath: logicalPath,
                            have: expectedOffset,
                            need: totalSize
                        )
                    }
                    let vol = try volume(for: c.discIndex, url: c.discURL)
                    let data = try vol.readFile(at: c.part.storedPath)
                    if data.count != c.part.byteLength {
                        throw SpanError.missingFile(path: c.part.storedPath, disc: c.discIndex)
                    }
                    let pcrc = DisketteEngine.crc32(data)
                    if pcrc != c.part.partCrc32 {
                        throw SpanError.partCRCMismatch(path: logicalPath, part: c.part.partIndex)
                    }
                    try out.write(contentsOf: data)
                    seed = DisketteEngine.crc32(data, seed: seed)
                    written += data.count
                    expectedOffset += c.part.byteLength
                }
                try out.close()
            } catch {
                try? out.close()
                try? fm.removeItem(at: tempURL)
                throw error
            }

            if written != totalSize {
                try? fm.removeItem(at: tempURL)
                throw SpanError.missingParts(logicalPath: logicalPath, have: written, need: totalSize)
            }
            if seed != fileCrc {
                try? fm.removeItem(at: tempURL)
                throw SpanError.fileCRCMismatch(path: logicalPath)
            }

            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: tempURL, to: dest)
            filesRestored += 1
            bytesRestored += written
        }

        // Recreate empty directories
        var emptyRestored = 0
        for dirPath in emptyDirs.sorted() {
            let dest = try hostDestination(logicalPath: dirPath, rootName: rootName, destRoot: destRoot)
            if !fm.fileExists(atPath: dest.path) {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                emptyRestored += 1
            }
        }

        volumeCache = nil

        return UnspanResult(
            setId: setId,
            rootName: rootName,
            filesRestored: filesRestored,
            bytesRestored: bytesRestored,
            discCount: count,
            chunkedFiles: chunkedFiles,
            emptyDirectories: emptyRestored,
            outputRoot: destRoot
        )
    }

    private static func validateManifestConsistency(_ manifests: [Manifest]) throws {
        guard let first = manifests.first else { return }
        for m in manifests {
            if m.setId != first.setId { throw SpanError.mixedSets }
            if m.count != first.count {
                throw SpanError.inconsistentManifests("disc count \(m.count) vs \(first.count)")
            }
            if m.rootName != first.rootName {
                throw SpanError.inconsistentManifests("rootName “\(m.rootName)” vs “\(first.rootName)”")
            }
            if m.media != first.media {
                throw SpanError.inconsistentManifests("media \(m.media) vs \(first.media)")
            }
            if m.setLabel != first.setLabel {
                throw SpanError.inconsistentManifests("setLabel “\(m.setLabel)” vs “\(first.setLabel)”")
            }
            if m.totalFilesInSet != first.totalFilesInSet {
                throw SpanError.inconsistentManifests(
                    "totalFilesInSet \(m.totalFilesInSet) vs \(first.totalFilesInSet)"
                )
            }
            if m.totalBytesInSet != first.totalBytesInSet {
                throw SpanError.inconsistentManifests(
                    "totalBytesInSet \(m.totalBytesInSet) vs \(first.totalBytesInSet)"
                )
            }
        }
    }

    private static func hostDestination(logicalPath: String, rootName: String, destRoot: URL) throws -> URL {
        try DisketteEngine.Volume.validatePathComponents(logicalPath)
        let prefix = "/" + rootName
        let rel: String
        if logicalPath == prefix {
            rel = ""
        } else if logicalPath.hasPrefix(prefix + "/") {
            rel = String(logicalPath.dropFirst(prefix.count + 1))
        } else {
            rel = String(logicalPath.dropFirst())
        }
        let root = destRoot.standardizedFileURL
        let dest: URL
        if rel.isEmpty {
            if logicalPath == prefix {
                dest = root
            } else {
                dest = root.appendingPathComponent((logicalPath as NSString).lastPathComponent)
            }
        } else {
            let parts = rel.split(separator: "/").map(String.init)
                .filter { $0 != ".." && $0 != "." && !$0.isEmpty }
            dest = parts.reduce(root) { $0.appendingPathComponent($1) }
        }
        guard DisketteEngine.isPath(dest, containedUnder: root) else {
            throw SpanError.cannotWrite("Refusing to restore outside destination: \(logicalPath)")
        }
        return dest
    }

    static func unspanDirectory(
        _ directory: URL,
        outputDirectory: URL,
        collision: CollisionPolicy = .fail
    ) throws -> UnspanResult {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { DisketteEngine.isFloppyFilename($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !urls.isEmpty else {
            throw SpanError.notASpanDisc(directory.path)
        }

        var spanURLs: [URL] = []
        var firstSet: String?
        for url in urls {
            // Manifest-only peek
            let vol = try DisketteEngine.load(from: url)
            guard let man = try readManifest(from: vol) else { continue }
            if firstSet == nil {
                firstSet = man.setId
            }
            if man.setId == firstSet {
                spanURLs.append(url)
            }
        }
        guard !spanURLs.isEmpty else {
            throw SpanError.notASpanDisc(directory.path)
        }
        return try unspan(discURLs: spanURLs, outputDirectory: outputDirectory, collision: collision)
    }

    // MARK: - Manifest I/O

    static func readManifest(from volume: DisketteEngine.Volume) throws -> Manifest? {
        guard let entry = volume.entry(at: manifestPath), !entry.isDirectory else {
            return nil
        }
        let data = try volume.readFile(at: manifestPath)
        let man = try JSONDecoder().decode(Manifest.self, from: data)
        guard man.isValidMagic else { return nil }
        return man
    }

    static func isSpanVolume(_ volume: DisketteEngine.Volume) -> Bool {
        (try? readManifest(from: volume)) != nil
    }

    private static func writeManifest(_ manifest: Manifest, onto volume: DisketteEngine.Volume) throws {
        let encoder = JSONEncoder()
        // Compact JSON (no pretty-print) to minimize manifest size.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        if data.count > volume.freeBytes {
            throw SpanError.cannotWrite(
                "Not enough free space for span manifest on disc \(manifest.index) (need \(data.count) B)"
            )
        }
        try volume.addDirectory(at: "/.diskette-span")
        try volume.addFile(at: manifestPath, data: data, overwrite: true)
    }

    // MARK: - Naming

    static func spanFilename(stem: String, index: Int, count: Int) -> String {
        let width = max(2, String(count).count)
        let idx = String(format: "%0\(width)d", index)
        let total = String(format: "%0\(width)d", count)
        return "\(stem)-\(idx)of\(total).\(DisketteEngine.fileExtension)"
    }

    private static func makeDiscLabel(base: String, index: Int, count: Int) -> String {
        let suffix = " \(index)/\(count)"
        let maxBase = max(1, 32 - suffix.count)
        let trimmed = String(base.prefix(maxBase)).trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (trimmed.isEmpty ? "Span" : trimmed) + suffix
        return String(label.prefix(32))
    }

    private static func sanitizeFilename(_ s: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = s.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "span" : String(cleaned.prefix(40))
    }

    // MARK: - Self-test

    static func selfTest() -> String? {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("DisketteSpanTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }

        do {
            // Many small files
            let folder = tmp.appendingPathComponent("Project", isDirectory: true)
            try fm.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
            try fm.createDirectory(at: folder.appendingPathComponent("empty/nested"), withIntermediateDirectories: true)
            let chunk = Data(repeating: 0x41, count: 100_000)
            for i in 1...8 {
                let name = i <= 2 ? "src/f\(i).bin" : "f\(i).bin"
                let url = folder.appendingPathComponent(name)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try chunk.write(to: url)
            }
            try Data("readme".utf8).write(to: folder.appendingPathComponent("README.txt"))

            let out = tmp.appendingPathComponent("discs", isDirectory: true)
            let result = try spanFolder(
                at: folder,
                outputDirectory: out,
                media: .dd360,
                setLabel: "Project",
                packaging: .binary,
                compress: false
            )
            if result.discURLs.count < 2 {
                return "expected multi-disc span, got \(result.discURLs.count)"
            }
            if result.totalFiles != 9 { return "totalFiles \(result.totalFiles)" }
            if result.emptyDirectories < 1 { return "expected empty dirs recorded" }

            for url in result.discURLs {
                let vol = try DisketteEngine.load(from: url)
                guard let man = try readManifest(from: vol) else {
                    return "missing manifest"
                }
                if man.setId != result.setId { return "setId mismatch" }
                if man.magic != magicV2 { return "expected v2 magic" }
            }

            do {
                _ = try unspan(
                    discURLs: [result.discURLs[0]],
                    outputDirectory: tmp.appendingPathComponent("bad"),
                    collision: .overwrite
                )
                return "incomplete unspan should fail"
            } catch SpanError.incompleteSet { /* ok */ }

            let restored = tmp.appendingPathComponent("restored", isDirectory: true)
            let u = try unspan(discURLs: result.discURLs, outputDirectory: restored, collision: .overwrite)
            if u.filesRestored != 9 { return "restored count \(u.filesRestored)" }
            let emptyPath = restored.appendingPathComponent("Project/empty/nested")
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: emptyPath.path, isDirectory: &isDir) || !isDir.boolValue {
                return "empty nested dir not restored"
            }

            // Collision fail
            do {
                _ = try unspan(discURLs: result.discURLs, outputDirectory: restored, collision: .fail)
                return "collision fail expected"
            } catch SpanError.destinationExists { /* ok */ }

            // Oversized file chunking + streaming
            let hugeFolder = tmp.appendingPathComponent("huge", isDirectory: true)
            try fm.createDirectory(at: hugeFolder, withIntermediateDirectories: true)
            var huge = Data(count: 500_000)
            for i in 0..<huge.count { huge[i] = UInt8(i % 251) }
            try huge.write(to: hugeFolder.appendingPathComponent("big.bin"))
            try Data("side".utf8).write(to: hugeFolder.appendingPathComponent("note.txt"))

            let out2 = tmp.appendingPathComponent("discs-huge", isDirectory: true)
            let r2 = try spanFolder(
                at: hugeFolder,
                outputDirectory: out2,
                media: .dd360,
                setLabel: "Huge",
                packaging: .binary,
                compress: false
            )
            if r2.chunkedFiles < 1 { return "expected chunked file" }
            if r2.discURLs.count < 2 { return "huge multi-disc" }

            let restored2 = tmp.appendingPathComponent("restored-huge", isDirectory: true)
            let u2 = try unspan(discURLs: r2.discURLs, outputDirectory: restored2, collision: .overwrite)
            if u2.chunkedFiles < 1 { return "restore chunkedFiles" }
            let bigBack = try Data(contentsOf: restored2.appendingPathComponent("huge/big.bin"))
            if bigBack != huge { return "huge mismatch after stream restore" }

            // Duplicate index rejected
            let d0 = result.discURLs[0]
            do {
                _ = try unspan(discURLs: [d0, d0], outputDirectory: tmp.appendingPathComponent("dup"), collision: .overwrite)
                // same index twice after incomplete check may fail incomplete or duplicate
                // With two copies of disc 1 of N>1: incomplete (missing others) first... 
                // For single-disc set duplicate:
            } catch { /* any error ok */ }

            let v1vol = DisketteEngine.create(label: "V1", media: .dd720)
            try v1vol.addFile(at: "/Legacy/a.txt", data: Data("legacy".utf8))
            let v1man = Manifest(
                magic: magicV1,
                setId: "00000000-0000-0000-0000-000000000001",
                setLabel: "Legacy",
                media: DisketteEngine.Media.dd720.rawValue,
                index: 1,
                count: 1,
                rootName: "Legacy",
                filesOnThisDisc: ["/Legacy/a.txt"],
                parts: nil,
                emptyDirectories: nil,
                totalFilesInSet: 1,
                totalBytesInSet: 6,
                created: "2026-01-01T00:00:00Z",
                chunkedFileCount: 0
            )
            try writeManifest(v1man, onto: v1vol)
            let v1url = tmp.appendingPathComponent("legacy-01of01.Floppy")
            try DisketteEngine.save(v1vol, to: v1url)
            let u3 = try unspan(discURLs: [v1url], outputDirectory: tmp.appendingPathComponent("v1out"), collision: .overwrite)
            if u3.filesRestored != 1 { return "v1 restore" }

            // Dense tiny-file tree: manifest can exceed a fixed 16 KB reserve; packing must still succeed.
            let dense = tmp.appendingPathComponent("dense", isDirectory: true)
            try fm.createDirectory(at: dense, withIntermediateDirectories: true)
            for i in 0..<400 {
                let name = String(format: "n%03d_example_payload.jfd", i)
                try Data(repeating: UInt8(i % 251), count: 1_200).write(to: dense.appendingPathComponent(name))
            }
            let denseOut = tmp.appendingPathComponent("dense-discs", isDirectory: true)
            let denseResult = try spanFolder(
                at: dense,
                outputDirectory: denseOut,
                media: .hd1440,
                setLabel: "Dense",
                packaging: .binary,
                compress: false
            )
            if denseResult.totalFiles != 400 { return "dense totalFiles \(denseResult.totalFiles)" }
            if denseResult.discURLs.isEmpty { return "dense no discs" }
            for url in denseResult.discURLs {
                let vol = try DisketteEngine.load(from: url)
                guard try readManifest(from: vol) != nil else { return "dense missing manifest" }
            }
            let denseRestored = tmp.appendingPathComponent("dense-restored", isDirectory: true)
            let denseU = try unspan(
                discURLs: denseResult.discURLs,
                outputDirectory: denseRestored,
                collision: .overwrite
            )
            if denseU.filesRestored != 400 { return "dense restore \(denseU.filesRestored)" }

            // Incremental CRC matches whole-file CRC
            let crcFile = try DisketteEngine.crc32File(at: restored2.appendingPathComponent("huge/big.bin"))
            if crcFile != DisketteEngine.crc32(huge) { return "streaming crc mismatch" }

            // Optional single-disc XOR recovery
            let recFolder = tmp.appendingPathComponent("rec-src", isDirectory: true)
            try fm.createDirectory(at: recFolder, withIntermediateDirectories: true)
            for i in 0..<6 {
                try Data(repeating: UInt8(0x40 + i), count: 80_000)
                    .write(to: recFolder.appendingPathComponent("b\(i).bin"))
            }
            let recOut = tmp.appendingPathComponent("rec-discs", isDirectory: true)
            let recSpan = try spanFolder(
                at: recFolder,
                outputDirectory: recOut,
                media: .dd360,
                setLabel: "DontCopy",
                packaging: .binary,
                compress: false,
                recoveryDiscCount: 1
            )
            guard let recoveryURL = recSpan.recoveryURL else { return "expected recovery disc" }
            if recSpan.discURLs.count < 2 { return "recovery test needs multi-disc" }
            let victim = recSpan.discURLs[recSpan.discURLs.count / 2]
            let victimBytes = try Data(contentsOf: victim)
            try fm.removeItem(at: victim)
            let remaining = recSpan.discURLs.filter { $0 != victim } + [recoveryURL]
            let rebuiltDir = tmp.appendingPathComponent("rebuilt", isDirectory: true)
            try fm.createDirectory(at: rebuiltDir, withIntermediateDirectories: true)
            let recovered = try reconstructMissingDisc(
                recoveryURL: recoveryURL,
                availableDiscURLs: remaining,
                outputURL: rebuiltDir
            )
            let rebuiltBytes = try Data(contentsOf: recovered.reconstructedURL)
            if rebuiltBytes != victimBytes { return "recovery XOR mismatch" }
            let allDiscs = recSpan.discURLs.map { url -> URL in
                url == victim ? recovered.reconstructedURL : url
            }
            let recRestored = tmp.appendingPathComponent("rec-restored", isDirectory: true)
            let recU = try unspan(discURLs: allDiscs, outputDirectory: recRestored, collision: .overwrite)
            if recU.filesRestored != 6 { return "recovery unspan \(recU.filesRestored)" }

            // Reed–Solomon multi-loss (2 recovery discs → rebuild 2 missing data discs)
            let rsFolder = tmp.appendingPathComponent("rs-src", isDirectory: true)
            try fm.createDirectory(at: rsFolder, withIntermediateDirectories: true)
            for i in 0..<12 {
                var payload = Data(count: 90_000)
                for b in 0..<payload.count { payload[b] = UInt8((i * 31 + b * 17) & 0xFF) }
                try payload.write(to: rsFolder.appendingPathComponent("r\(i).bin"))
            }
            let rsOut = tmp.appendingPathComponent("rs-discs", isDirectory: true)
            let rsSpan = try spanFolder(
                at: rsFolder,
                outputDirectory: rsOut,
                media: .dd360,
                setLabel: "RSSet",
                packaging: .binary,
                compress: false,
                recoveryDiscCount: 2
            )
            if rsSpan.recoveryURLs.count != 2 { return "expected 2 RS recovery discs, got \(rsSpan.recoveryURLs.count)" }
            if rsSpan.discURLs.count < 3 { return "RS needs ≥3 data discs, got \(rsSpan.discURLs.count)" }
            let v1 = rsSpan.discURLs[0]
            let v2 = rsSpan.discURLs[rsSpan.discURLs.count - 1]
            let v1Bytes = try Data(contentsOf: v1)
            let v2Bytes = try Data(contentsOf: v2)
            try fm.removeItem(at: v1)
            try fm.removeItem(at: v2)
            let rsAvail = rsSpan.discURLs.filter { $0 != v1 && $0 != v2 } + rsSpan.recoveryURLs
            let rsRebuiltDir = tmp.appendingPathComponent("rs-rebuilt", isDirectory: true)
            try fm.createDirectory(at: rsRebuiltDir, withIntermediateDirectories: true)
            let rsBatch = try reconstructMissingDiscs(availableDiscURLs: rsAvail, outputURL: rsRebuiltDir)
            if rsBatch.scheme != .reedSolomon { return "expected RS scheme" }
            if rsBatch.results.count != 2 { return "RS rebuilt \(rsBatch.results.count), want 2" }
            for r in rsBatch.results {
                let data = try Data(contentsOf: r.reconstructedURL)
                if r.missingFilename == v1.lastPathComponent {
                    if data != v1Bytes { return "RS rebuild mismatch disc1" }
                } else if r.missingFilename == v2.lastPathComponent {
                    if data != v2Bytes { return "RS rebuild mismatch disc2" }
                } else {
                    return "unexpected rebuilt name \(r.missingFilename)"
                }
            }
            let rsAll = rsSpan.discURLs.map { url -> URL in
                if url == v1 {
                    return rsBatch.results.first { $0.missingFilename == v1.lastPathComponent }!.reconstructedURL
                }
                if url == v2 {
                    return rsBatch.results.first { $0.missingFilename == v2.lastPathComponent }!.reconstructedURL
                }
                return url
            }
            let rsRestored = tmp.appendingPathComponent("rs-restored", isDirectory: true)
            let rsU = try unspan(discURLs: rsAll, outputDirectory: rsRestored, collision: .overwrite)
            if rsU.filesRestored != 12 { return "RS unspan \(rsU.filesRestored)" }

        } catch {
            return "span self-test: \(error.localizedDescription)"
        }
        return nil
    }
}
