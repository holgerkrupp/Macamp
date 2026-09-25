import AppKit
import Foundation

enum RegionParser {
    static func parse(_ data: Data) -> NSBezierPath? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let numbers = text.split { !$0.isNumber && $0 != "-" }.compactMap { Int($0) }
        // Region files contain some counts before the point list. Locate a plausible polygon.
        guard numbers.count >= 8 else { return nil }
        let coordinates = Array(numbers.suffix(numbers.count.isMultiple(of: 2) ? numbers.count : numbers.count - 1))
        guard coordinates.count >= 8 else { return nil }
        let path = NSBezierPath()
        path.move(to: CGPoint(x: coordinates[0], y: coordinates[1]))
        for index in stride(from: 2, to: coordinates.count - 1, by: 2) {
            path.line(to: CGPoint(x: coordinates[index], y: coordinates[index + 1]))
        }
        path.close()
        return path.bounds.isEmpty ? nil : path
    }
}
