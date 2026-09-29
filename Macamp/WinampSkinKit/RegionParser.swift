import AppKit
import Foundation

enum RegionParser {
    static func parse(_ data: Data, section requestedSection: String = "Normal") -> NSBezierPath? {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1) else { return nil }

        // REGION.TXT is an INI-like file. In particular, examples in comments and
        // the WindowShade/Equalizer sections contain perfectly plausible integers,
        // so treating the whole file as one coordinate stream creates bad masks.
        let requestedSection = requestedSection.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var inRequestedSection = false
        var foundRequestedSection = false
        var pointList: [Int] = []
        var pointCounts: [Int]?
        var readingPointList = false

        for rawLine in text.components(separatedBy: .newlines) {
            let uncommented = rawLine.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let line = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.first == "[", line.last == "]" {
                let section = line.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                inRequestedSection = !foundRequestedSection && section == requestedSection
                if inRequestedSection { foundRequestedSection = true }
                readingPointList = false
                continue
            }
            guard inRequestedSection else { continue }

            guard let separator = line.firstIndex(of: "=") else {
                if readingPointList { pointList.append(contentsOf: integers(in: line)) }
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...]
            switch key {
            case "numpoints":
                let counts = integers(in: String(value))
                guard !counts.isEmpty else { return nil }
                pointCounts = counts
                readingPointList = false
            case "pointlist":
                pointList.append(contentsOf: integers(in: String(value)))
                readingPointList = true
            default:
                readingPointList = false
            }
        }

        guard foundRequestedSection,
              let pointCounts,
              !pointCounts.isEmpty,
              pointCounts.count <= 64,
              pointCounts.allSatisfy({ (3...2_048).contains($0) }),
              pointList.count == pointCounts.reduce(0, +) * 2 else { return nil }

        let path = NSBezierPath()
        var coordinateIndex = 0
        for pointCount in pointCounts {
            let polygon = Array(pointList[coordinateIndex..<(coordinateIndex + pointCount * 2)])
            coordinateIndex += pointCount * 2
            guard polygon.allSatisfy({ (-2_048...4_096).contains($0) }) else { return nil }
            path.move(to: CGPoint(x: polygon[0], y: polygon[1]))
            for index in stride(from: 2, to: polygon.count, by: 2) {
                path.line(to: CGPoint(x: polygon[index], y: polygon[index + 1]))
            }
            path.close()
        }
        guard !path.isEmpty, path.bounds.width <= 4_096, path.bounds.height <= 4_096 else { return nil }
        path.windingRule = .nonZero
        return path
    }

    private static func integers(in value: String) -> [Int] {
        value.split { !$0.isNumber && $0 != "-" }
            .compactMap { Int($0) }
    }
}
