import Foundation

enum VieNeuV3NpzError: Error {
    case eocdNotFound
    case badEntry(String)
    case entryNotFound(String)
    case badNpyHeader(String)
    case unsupportedDtype(String)
}

/// Minimal reader for `vieneu_v3_heads.npz` — a plain ZIP (STORED/uncompressed
/// entries, confirmed via `zipfile.ZipFile(...).infolist()` on the real file:
/// every entry is `compress_type=0`) of `.npy` arrays, all `<f4` (little-
/// endian float32) C-order. Only what that one file actually needs: no
/// DEFLATE, no Zip64, no dtype other than float32 — a general-purpose ZIP/
/// npy reader would be a lot more code for cases this bundle never hits.
struct VieNeuV3Npz {
    struct Array1D { let data: [Float] }
    struct ArrayND { let data: [Float]; let shape: [Int] }

    private let bytes: Data
    /// name -> (data offset from start of file, element count)
    private let entries: [String: (offset: Int, count: Int, shape: [Int])]

    init(contentsOf url: URL) throws {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        self.bytes = bytes
        self.entries = try Self.parseEntries(bytes)
    }

    func floatArray(_ name: String) throws -> [Float] {
        guard let e = entries[name] else { throw VieNeuV3NpzError.entryNotFound(name) }
        return Self.readFloats(bytes, offset: e.offset, count: e.count)
    }

    func shape(_ name: String) throws -> [Int] {
        guard let e = entries[name] else { throw VieNeuV3NpzError.entryNotFound(name) }
        return e.shape
    }

    func scalarFloat(_ name: String) throws -> Float {
        let a = try floatArray(name)
        guard let v = a.first else { throw VieNeuV3NpzError.badEntry(name) }
        return v
    }

    // MARK: - ZIP central directory

    private static func parseEntries(_ bytes: Data) throws -> [String: (offset: Int, count: Int, shape: [Int])] {
        // End Of Central Directory record: fixed 22-byte tail (no comment,
        // which is true for every writer that produces this file) — scan
        // backward for its 4-byte signature instead of assuming a fixed
        // offset, still cheap for a file this size.
        let sig = Data([0x50, 0x4B, 0x05, 0x06])
        guard let eocdRange = bytes.range(of: sig, options: .backwards) else {
            throw VieNeuV3NpzError.eocdNotFound
        }
        let eocd = eocdRange.lowerBound
        let entryCount = Int(readU16(bytes, eocd + 10))
        let cdOffset = Int(readU32(bytes, eocd + 16))

        var result: [String: (offset: Int, count: Int, shape: [Int])] = [:]
        var p = bytes.startIndex + cdOffset
        for _ in 0..<entryCount {
            guard readU32(bytes, p) == 0x0201_4B50 else {
                throw VieNeuV3NpzError.badEntry("central directory signature mismatch")
            }
            let compressionMethod = readU16(bytes, p + 10)
            let nameLen = Int(readU16(bytes, p + 28))
            let extraLen = Int(readU16(bytes, p + 30))
            let commentLen = Int(readU16(bytes, p + 32))
            let localHeaderOffset = Int(readU32(bytes, p + 42))
            let nameStart = p + 46
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLen)], as: UTF8.self)

            guard compressionMethod == 0 else {
                throw VieNeuV3NpzError.badEntry("\(name): compressed entries not supported")
            }

            let (dataOffset, shape, dtype) = try readLocalEntry(bytes, headerOffset: localHeaderOffset)
            guard dtype == "<f4" else { throw VieNeuV3NpzError.unsupportedDtype("\(name): \(dtype)") }
            let count = shape.reduce(1, *)
            let key = name.hasSuffix(".npy") ? String(name.dropLast(4)) : name
            result[key] = (dataOffset, count, shape)

            p = nameStart + nameLen + extraLen + commentLen
        }
        return result
    }

    /// Reads one local file header + its `.npy` header, returns the byte
    /// offset the raw float payload starts at, plus the shape/dtype string
    /// parsed out of the npy header dict (e.g. `{'descr': '<f4',
    /// 'fortran_order': False, 'shape': (419, 768), }`).
    private static func readLocalEntry(_ bytes: Data, headerOffset: Int) throws -> (dataOffset: Int, shape: [Int], dtype: String) {
        let base = bytes.startIndex + headerOffset
        guard readU32(bytes, base) == 0x0403_4B50 else {
            throw VieNeuV3NpzError.badEntry("local file header signature mismatch")
        }
        let nameLen = Int(readU16(bytes, base + 26))
        let extraLen = Int(readU16(bytes, base + 28))
        let npyStart = base + 30 + nameLen + extraLen

        guard bytes[npyStart..<(npyStart + 6)].elementsEqual([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]) else {
            throw VieNeuV3NpzError.badNpyHeader("bad magic")
        }
        let major = bytes[npyStart + 6]
        let headerLenSize = major >= 2 ? 4 : 2
        let headerLen: Int = headerLenSize == 2
            ? Int(readU16(bytes, npyStart + 8))
            : Int(readU32(bytes, npyStart + 8))
        let dictStart = npyStart + 8 + headerLenSize
        let dictRange = dictStart..<(dictStart + headerLen)
        let dict = String(decoding: bytes[dictRange], as: UTF8.self)

        guard let descrRange = dict.range(of: "'descr': '"),
              let descrEnd = dict.range(of: "'", range: descrRange.upperBound..<dict.endIndex)
        else { throw VieNeuV3NpzError.badNpyHeader("no descr") }
        let dtype = String(dict[descrRange.upperBound..<descrEnd.lowerBound])

        guard let shapeOpen = dict.range(of: "'shape': (")?.upperBound,
              let shapeClose = dict.range(of: ")", range: shapeOpen..<dict.endIndex)?.lowerBound
        else { throw VieNeuV3NpzError.badNpyHeader("no shape") }
        let shapeInner = dict[shapeOpen..<shapeClose]
        let shape: [Int] = shapeInner
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { Int($0) }
        // A 0-d array ("shape': (), ") — treat as a single-element array.
        let effectiveShape = shape.isEmpty ? [1] : shape

        return (dictRange.upperBound, effectiveShape, dtype)
    }

    private static func readFloats(_ bytes: Data, offset: Int, count: Int) -> [Float] {
        let start = bytes.startIndex + offset
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBytes { dst in
            bytes.copyBytes(to: dst.bindMemory(to: UInt8.self), from: start..<(start + count * 4))
        }
        return out
    }

    private static func readU16(_ bytes: Data, _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
    }

    private static func readU32(_ bytes: Data, _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
    }
}
