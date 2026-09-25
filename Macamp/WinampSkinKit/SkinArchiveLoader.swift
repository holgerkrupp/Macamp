import Compression
import Foundation

actor SkinArchiveLoader {
    struct Limits: Sendable {
        var maximumFileCount = 512
        var maximumIndividualSize = 16 * 1_024 * 1_024
        var maximumTotalSize = 64 * 1_024 * 1_024
    }

    private let limits: Limits
    init(limits: Limits = .init()) { self.limits = limits }

    func load(url: URL) throws -> LoadedSkinArchive {
        let fileExtension = url.pathExtension.lowercased()
        guard ["wsz", "wal", "zip"].contains(fileExtension) else {
            throw invalid("Skins must be .wsz, .wal, or .zip archives.")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let unpacked = try parseZIP(data)
        var files = unpacked.files
        let hasClassicMain = containsBasename("main.bmp", files: files)
        let hasModernManifest = containsBasename("skin.xml", files: files)
        let format: SkinFormat
        switch fileExtension {
        case "wsz": format = .classic
        case "wal": format = .modern
        default:
            guard hasClassicMain || hasModernManifest else {
                throw invalid("The ZIP archive contains neither a classic main.bmp nor a Modern skin.xml manifest.")
            }
            format = hasModernManifest ? .modern : .classic
        }

        var report = SkinValidationReport()
        switch format {
        case .classic:
            files = files.filter { ($0.key as NSString).pathExtension.lowercased() != "maki" }
            if !hasClassicMain { report.errors.append("The classic archive does not contain main.bmp.") }
            let expected = ["cbuttons.bmp", "titlebar.bmp", "numbers.bmp", "text.bmp", "volume.bmp", "posbar.bmp"]
            for name in expected where !containsBasename(name, files: files) { report.warnings.append("Optional classic asset \(name) is missing.") }
            if hasModernManifest { report.warnings.append("Modern XML files are ignored because this archive was imported as a classic .wsz skin.") }
            return LoadedSkinArchive(format: format, files: files, report: report, modern: nil)
        case .modern:
            guard hasModernManifest else {
                report.errors.append("The Modern archive does not contain skin.xml.")
                return LoadedSkinArchive(format: format, files: files, report: report, modern: nil)
            }
            var acceptedScripts = 0
            var rejectedScripts = 0
            let makiPaths = files.keys.filter { ($0 as NSString).pathExtension.lowercased() == "maki" }
            for path in makiPaths {
                guard let data = files[path] else { continue }
                do {
                    _ = try MakiDecoder.decode(data, path: path)
                    acceptedScripts += 1
                } catch {
                    files.removeValue(forKey: path)
                    rejectedScripts += 1
                    report.warnings.append("Rejected \(path): \(error.localizedDescription)")
                }
            }
            let parsed = ModernSkinParser.parse(files: files)
            report.warnings.append(contentsOf: parsed.warnings)
            if acceptedScripts > 0 {
                report.warnings.append("Validated \(acceptedScripts) compiled MAKI script file(s) for the sandboxed compatibility runtime.")
            }
            if rejectedScripts > 0 {
                report.warnings.append("Rejected \(rejectedScripts) invalid or unsupported MAKI script file(s).")
            }
            if parsed.descriptor.layers.isEmpty,
               parsed.descriptor.screenshotPath.flatMap({ files[$0.lowercased()] }) == nil {
                report.errors.append("The Modern skin has no safely renderable layout or screenshot.")
            }
            if parsed.descriptor.controls.isEmpty { report.warnings.append("No supported transport controls were found in the selected Modern layout.") }
            report.warnings.append("MAKI runs with instruction limits and a restricted Wasabi host API; unsupported calls are ignored.")
            return LoadedSkinArchive(format: format, files: files, report: report, modern: parsed.descriptor)
        }
    }

    private func containsBasename(_ name: String, files: [String: Data]) -> Bool {
        files.keys.contains { $0 == name || $0.hasSuffix("/\(name)") }
    }

    private func parseZIP(_ data: Data) throws -> (files: [String: Data], makiFileCount: Int) {
        guard let eocd = findSignature(0x06054b50, in: data), eocd + 22 <= data.count else { throw invalid("The skin is not a valid ZIP-compatible archive.") }
        let entryCount = Int(try u16(data, eocd + 10))
        let centralOffset = Int(try u32(data, eocd + 16))
        guard entryCount <= limits.maximumFileCount else { throw invalid("The skin contains too many files.") }
        var cursor = centralOffset
        var totalSize = 0
        var result: [String: Data] = [:]
        var makiFileCount = 0
        let executableExtensions: Set<String> = ["exe", "dll", "com", "bat", "cmd", "app", "dylib", "sh"]

        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count, try u32(data, cursor) == 0x02014b50 else { throw invalid("The ZIP directory is malformed.") }
            let flags = try u16(data, cursor + 8)
            guard flags & 0x1 == 0 else { throw invalid("Encrypted skin archives are unsupported.") }
            let method = try u16(data, cursor + 10)
            let compressedSize = Int(try u32(data, cursor + 20))
            let uncompressedSize = Int(try u32(data, cursor + 24))
            let nameLength = Int(try u16(data, cursor + 28))
            let extraLength = Int(try u16(data, cursor + 30))
            let commentLength = Int(try u16(data, cursor + 32))
            let localOffset = Int(try u32(data, cursor + 42))
            guard cursor + 46 + nameLength + extraLength + commentLength <= data.count else { throw invalid("A ZIP entry is truncated.") }
            let nameData = data[(cursor + 46)..<(cursor + 46 + nameLength)]
            guard let rawName = String(data: nameData, encoding: flags & 0x800 != 0 ? .utf8 : .isoLatin1) else { throw invalid("A skin filename is not readable.") }
            cursor += 46 + nameLength + extraLength + commentLength
            let normalizedRawName = rawName.replacingOccurrences(of: "\\", with: "/")
            if normalizedRawName.hasSuffix("/") { continue }
            let name = try validatedName(normalizedRawName)
            let fileExtension = URL(fileURLWithPath: name).pathExtension.lowercased()
            if executableExtensions.contains(fileExtension) {
                continue
            }
            if fileExtension == "maki" {
                makiFileCount += 1
                guard makiFileCount <= 64 else { throw invalid("The skin contains too many MAKI scripts.") }
            }
            guard uncompressedSize <= limits.maximumIndividualSize else { throw invalid("A skin asset exceeds the size limit.") }
            totalSize += uncompressedSize
            guard totalSize <= limits.maximumTotalSize else { throw invalid("The uncompressed skin exceeds the total size limit.") }
            guard localOffset + 30 <= data.count, try u32(data, localOffset) == 0x04034b50 else { throw invalid("A ZIP entry has an invalid local header.") }
            let localNameLength = Int(try u16(data, localOffset + 26))
            let localExtraLength = Int(try u16(data, localOffset + 28))
            let start = localOffset + 30 + localNameLength + localExtraLength
            guard start + compressedSize <= data.count else { throw invalid("A compressed skin asset is truncated.") }
            let compressed = Data(data[start..<(start + compressedSize)])
            let decoded: Data
            switch method {
            case 0: decoded = compressed
            case 8: decoded = try inflate(compressed, expectedSize: uncompressedSize)
            default: throw invalid("ZIP compression method \(method) is unsupported.")
            }
            guard decoded.count == uncompressedSize else { throw invalid("A skin asset has an invalid uncompressed size.") }
            let key = name.lowercased()
            guard result[key] == nil else { throw invalid("The skin contains duplicate case-insensitive paths.") }
            result[key] = decoded
        }
        return (result, makiFileCount)
    }

    private func validatedName(_ raw: String) throws -> String {
        guard !raw.hasPrefix("/"), !raw.contains(":"), !raw.contains("\0") else { throw invalid("The skin contains an unsafe path.") }
        let components = raw.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains("..") else { throw invalid("The skin contains an unsafe path.") }
        return components.filter { $0 != "." }.joined(separator: "/")
    }

    private func inflate(_ input: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let count = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, expectedSize, source.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard count == expectedSize else { throw invalid("A compressed skin asset could not be decoded.") }
        return output
    }

    private func findSignature(_ signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        let range = max(0, data.count - 65_557)...(data.count - 4)
        for index in range.reversed() where (try? u32(data, index)) == signature { return index }
        return nil
    }

    private func u16(_ data: Data, _ offset: Int) throws -> UInt16 {
        guard offset + 2 <= data.count else { throw invalid("Unexpected end of archive.") }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func u32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset + 4 <= data.count else { throw invalid("Unexpected end of archive.") }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private func invalid(_ message: String) -> ProviderError { ProviderError(code: .invalidResponse, message: message) }
}
