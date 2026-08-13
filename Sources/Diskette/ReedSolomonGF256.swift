import Foundation

/// Galois field GF(2⁸) with AES polynomial `x⁸ + x⁴ + x³ + x + 1` (0x11d).
/// Used for Cauchy Reed–Solomon erasure coding of span recovery discs.
enum GF256 {
    private static let expTable: [UInt8] = {
        var exp = [UInt8](repeating: 0, count: 512)
        var x: Int = 1
        for i in 0..<255 {
            exp[i] = UInt8(x)
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11d }
        }
        for i in 255..<512 {
            exp[i] = exp[i - 255]
        }
        return exp
    }()

    private static let logTable: [Int] = {
        var log = [Int](repeating: 0, count: 256)
        for i in 0..<255 {
            log[Int(expTable[i])] = i
        }
        log[0] = -1
        return log
    }()

    @inline(__always) static func add(_ a: UInt8, _ b: UInt8) -> UInt8 { a ^ b }

    @inline(__always) static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return expTable[logTable[Int(a)] + logTable[Int(b)]]
    }

    @inline(__always) static func inv(_ a: UInt8) -> UInt8 {
        precondition(a != 0, "GF256 inverse of 0")
        return expTable[255 - logTable[Int(a)]]
    }

    @inline(__always) static func div(_ a: UInt8, _ b: UInt8) -> UInt8 {
        precondition(b != 0, "GF256 divide by 0")
        if a == 0 { return 0 }
        return expTable[logTable[Int(a)] - logTable[Int(b)] + 255]
    }
}

/// Systematic Cauchy Reed–Solomon over GF(256) for multi-disc recovery.
///
/// - **n** data shards + **m** parity shards
/// - Parity row `j`, data column `i`: `C[j][i] = 1 / (x_i ⊕ y_j)`
/// - At each byte offset: `P_j = ⊕_i (C[j][i] · D_i)`
///
/// Any **m** erasures among the n+m shards can be repaired when **n** shards remain
/// (here we typically recover missing **data** discs using surviving data + recovery discs).
struct CauchyReedSolomon {
    let dataCount: Int
    let parityCount: Int
    /// `parityCount × dataCount` Cauchy coefficients.
    private let matrix: [[UInt8]]

    /// Maximum total shards (data + parity) we allow (distinct GF elements).
    static let maxTotalShards = 64
    static let maxParityShards = 16

    enum RSError: Error, LocalizedError {
        case invalidDimensions(String)
        case singular
        case insufficientShards(need: Int, have: Int)
        case badShardIndex

        var errorDescription: String? {
            switch self {
            case .invalidDimensions(let m): return m
            case .singular: return "Reed–Solomon matrix is singular"
            case .insufficientShards(let need, let have):
                return "Need \(need) shards to decode, have \(have)"
            case .badShardIndex: return "Invalid shard index"
            }
        }
    }

    init(dataCount n: Int, parityCount m: Int) throws {
        guard n >= 1, m >= 1 else {
            throw RSError.invalidDimensions("Reed–Solomon needs n≥1 data and m≥1 parity")
        }
        guard m <= Self.maxParityShards else {
            throw RSError.invalidDimensions("At most \(Self.maxParityShards) recovery discs supported")
        }
        guard n + m <= Self.maxTotalShards else {
            throw RSError.invalidDimensions(
                "data+recovery discs (\(n)+\(m)) exceed \(Self.maxTotalShards)"
            )
        }
        // Distinct x_i, y_j in 1...255
        guard n + m < 255 else {
            throw RSError.invalidDimensions("Too many shards for GF(256)")
        }
        self.dataCount = n
        self.parityCount = m
        var mat = [[UInt8]](repeating: [UInt8](repeating: 0, count: n), count: m)
        for j in 0..<m {
            let y = UInt8(n + 1 + j) // n+1 .. n+m
            for i in 0..<n {
                let x = UInt8(i + 1) // 1 .. n
                mat[j][i] = GF256.inv(x ^ y)
            }
        }
        self.matrix = mat
    }

    func coefficient(parity j: Int, data i: Int) -> UInt8 {
        matrix[j][i]
    }

    // MARK: - Encode

    /// Build `m` parity buffers of `length` bytes from `n` data file URLs (zero-padded).
    ///
    /// Streams each data file once; accumulates into contiguous `[UInt8]` slabs with
    /// stable pointers (no per-byte `withUnsafeMutableBytes`).
    static func encodeParityFiles(
        dataURLs: [URL],
        length: Int,
        parityCount m: Int,
        bufferSize: Int = 1_048_576
    ) throws -> [Data] {
        let n = dataURLs.count
        let rs = try CauchyReedSolomon(dataCount: n, parityCount: m)
        // One contiguous slab: parity j lives at [j * length ..< (j+1) * length]
        var slab = [UInt8](repeating: 0, count: m * length)
        // Coefficient column for each data disc (m entries)
        var colCoeffs = [UInt8](repeating: 0, count: m)

        try slab.withUnsafeMutableBufferPointer { slabBP in
            guard let slabBase = slabBP.baseAddress else { return }
            for (i, url) in dataURLs.enumerated() {
                for j in 0..<m {
                    colCoeffs[j] = rs.coefficient(parity: j, data: i)
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var offset = 0
                while offset < length {
                    let toRead = min(bufferSize, length - offset)
                    let chunk = try handle.read(upToCount: toRead) ?? Data()
                    // EOF → remainder is zero pad (no contribution)
                    if chunk.isEmpty { break }
                    chunk.withUnsafeBytes { srcRaw in
                        guard let sBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                        let count = chunk.count
                        for j in 0..<m {
                            let c = colCoeffs[j]
                            if c == 0 { continue }
                            let dBase = slabBase.advanced(by: j * length + offset)
                            // Scale-and-XOR this data chunk into parity j
                            if c == 1 {
                                for b in 0..<count {
                                    dBase[b] ^= sBase[b]
                                }
                            } else {
                                for b in 0..<count {
                                    dBase[b] ^= GF256.mul(c, sBase[b])
                                }
                            }
                        }
                    }
                    offset += chunk.count
                }
            }
        }

        return (0..<m).map { j in
            Data(slab[(j * length)..<((j + 1) * length)])
        }
    }

    // MARK: - Decode (erasure recovery of data shards)

    /// Recover missing **data** shards (indices in `0..<n`).
    ///
    /// - `knownData`: surviving data discs `i → bytes` (padded/truncated to `length` as needed)
    /// - `knownParity`: recovery discs `j → bytes` (j in `0..<m`)
    /// - `missingData`: data indices to reconstruct
    ///
    /// Requires `missingData.count ≤ m` and enough independent parity equations.
    ///
    /// Hot path pins all buffers once and runs a tight byte loop over stable pointers
    /// (avoids per-byte `withUnsafeMutableBytes`).
    func recoverMissingData(
        knownData: [Int: Data],
        knownParity: [Int: Data],
        missingData: [Int],
        length: Int
    ) throws -> [Int: Data] {
        let k = missingData.count
        guard k > 0 else { return [:] }
        guard k <= parityCount else {
            throw RSError.insufficientShards(need: dataCount, have: dataCount - k + knownParity.count)
        }
        for idx in missingData {
            guard idx >= 0, idx < dataCount else { throw RSError.badShardIndex }
        }
        // Pick k parity rows we have
        let availableParity = knownParity.keys.sorted()
        guard availableParity.count >= k else {
            throw RSError.insufficientShards(need: k, have: availableParity.count)
        }
        let useParity = Array(availableParity.prefix(k))

        // A[r][c] = C[useParity[r]][missingData[c]]
        var a = [[UInt8]](repeating: [UInt8](repeating: 0, count: k), count: k)
        for r in 0..<k {
            let j = useParity[r]
            for c in 0..<k {
                a[r][c] = coefficient(parity: j, data: missingData[c])
            }
        }
        let aInv = try Self.invertMatrix(a)

        let knownIdx = (0..<dataCount).filter { knownData[$0] != nil && !missingData.contains($0) }
        let knownCount = knownIdx.count

        // Pack into contiguous slabs so the inner loop uses stable pointers only.
        // known:  knownCount * length
        // parity: k * length
        // out:    k * length
        // coeffKnown: k * knownCount  (row-major: r * knownCount + t)
        // aInvFlat:   k * k           (row-major: c * k + r  for x[c] = sum_r Ainv[c][r]*b[r])
        var knownSlab = [UInt8](repeating: 0, count: max(1, knownCount) * length)
        var paritySlab = [UInt8](repeating: 0, count: k * length)
        var outSlab = [UInt8](repeating: 0, count: k * length)
        var coeffKnown = [UInt8](repeating: 0, count: max(1, k * knownCount))
        var aInvFlat = [UInt8](repeating: 0, count: k * k)

        for t in 0..<knownCount {
            Self.copyPadded(knownData[knownIdx[t]], into: &knownSlab, destOffset: t * length, length: length)
        }
        for r in 0..<k {
            Self.copyPadded(knownParity[useParity[r]], into: &paritySlab, destOffset: r * length, length: length)
            for t in 0..<knownCount {
                coeffKnown[r * knownCount + t] = coefficient(parity: useParity[r], data: knownIdx[t])
            }
        }
        // aInvFlat row-major: x[c] = Σ_r aInvFlat[c*k+r] * b[r]
        for c in 0..<k {
            for r in 0..<k {
                aInvFlat[c * k + r] = aInv[c][r]
            }
        }

        Self.decodeErasureHotPath(
            length: length,
            k: k,
            knownCount: knownCount,
            knownSlab: knownSlab,
            paritySlab: paritySlab,
            coeffKnown: coeffKnown,
            aInvFlat: aInvFlat,
            outSlab: &outSlab
        )

        var results: [Int: Data] = [:]
        for c in 0..<k {
            let mi = missingData[c]
            let start = c * length
            results[mi] = Data(outSlab[start..<(start + length)])
        }
        return results
    }

    /// Copy `src` into `dest[destOffset..<destOffset+length]`, zero-padding or truncating.
    private static func copyPadded(_ src: Data?, into dest: inout [UInt8], destOffset: Int, length: Int) {
        guard length > 0 else { return }
        let copyLen = min(length, src?.count ?? 0)
        if copyLen > 0, let src {
            src.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                dest.withUnsafeMutableBufferPointer { destBP in
                    guard let d = destBP.baseAddress else { return }
                    d.advanced(by: destOffset).update(from: base, count: copyLen)
                }
            }
        }
        // remainder already zero from allocation
    }

    /// Byte-wise Cauchy RS erasure solve with all pointers fixed for the full length.
    private static func decodeErasureHotPath(
        length: Int,
        k: Int,
        knownCount: Int,
        knownSlab: [UInt8],
        paritySlab: [UInt8],
        coeffKnown: [UInt8],
        aInvFlat: [UInt8],
        outSlab: inout [UInt8]
    ) {
        // k is at most maxParityShards (16); use a fixed stack buffer for b[].
        precondition(k <= CauchyReedSolomon.maxParityShards)
        precondition(k > 0)

        knownSlab.withUnsafeBufferPointer { knownBP in
            paritySlab.withUnsafeBufferPointer { parityBP in
                coeffKnown.withUnsafeBufferPointer { coeffBP in
                    aInvFlat.withUnsafeBufferPointer { invBP in
                        outSlab.withUnsafeMutableBufferPointer { outBP in
                            let knownBase = knownBP.baseAddress
                            let parityBase = parityBP.baseAddress!
                            let coeffBase = coeffBP.baseAddress
                            let invBase = invBP.baseAddress!
                            let outBase = outBP.baseAddress!

                            // Stack-ish b vector (max 16)
                            var b = [UInt8](repeating: 0, count: CauchyReedSolomon.maxParityShards)

                            for pos in 0..<length {
                                // b[r] = P_r[pos] ⊕ Σ_t C[r][t] · D_t[pos]
                                for r in 0..<k {
                                    var acc = parityBase[r * length + pos]
                                    if knownCount > 0, let knownBase, let coeffBase {
                                        for t in 0..<knownCount {
                                            let c = coeffBase[r * knownCount + t]
                                            if c == 0 { continue }
                                            let d = knownBase[t * length + pos]
                                            if c == 1 {
                                                acc ^= d
                                            } else {
                                                acc ^= GF256.mul(c, d)
                                            }
                                        }
                                    }
                                    b[r] = acc
                                }
                                // x = Ainv * b  →  out[c][pos]
                                for c in 0..<k {
                                    var x: UInt8 = 0
                                    let row = invBase.advanced(by: c * k)
                                    for r in 0..<k {
                                        let a = row[r]
                                        if a == 0 { continue }
                                        if a == 1 {
                                            x ^= b[r]
                                        } else {
                                            x ^= GF256.mul(a, b[r])
                                        }
                                    }
                                    outBase[c * length + pos] = x
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Matrix invert (Gaussian elimination over GF(256))

    /// Invert a square matrix; returns inverse.
    static func invertMatrix(_ matrix: [[UInt8]]) throws -> [[UInt8]] {
        let n = matrix.count
        guard n > 0, matrix.allSatisfy({ $0.count == n }) else {
            throw RSError.invalidDimensions("Matrix must be square")
        }
        // Augment with identity
        var a = matrix.map { row -> [UInt8] in
            var r = row
            r.append(contentsOf: [UInt8](repeating: 0, count: n))
            return r
        }
        for i in 0..<n {
            a[i][n + i] = 1
        }

        for col in 0..<n {
            // Pivot
            var pivot = col
            while pivot < n, a[pivot][col] == 0 { pivot += 1 }
            if pivot == n { throw RSError.singular }
            if pivot != col {
                a.swapAt(pivot, col)
            }
            let invPivot = GF256.inv(a[col][col])
            for j in 0..<(2 * n) {
                a[col][j] = GF256.mul(a[col][j], invPivot)
            }
            for row in 0..<n where row != col {
                let factor = a[row][col]
                if factor == 0 { continue }
                for j in 0..<(2 * n) {
                    a[row][j] ^= GF256.mul(factor, a[col][j])
                }
            }
        }

        var inv = [[UInt8]](repeating: [UInt8](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n {
                inv[i][j] = a[i][n + j]
            }
        }
        return inv
    }
}
