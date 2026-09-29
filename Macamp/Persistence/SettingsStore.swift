import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    enum Keys {
        static let provider = "activeProvider"
        static let skinScale = "skinScale"
        static let playerOnLaunch = "showPlayerOnLaunch"
        static let playerFloating = "playerFloating"
        static let playerShadow = "playerShadow"
        static let clickThrough = "clickThroughTransparentPixels"
        static let frameRate = "visualizationFrameRate"
        static let intensity = "visualizationIntensity"
        static let visualization = "selectedVisualization"
        static let playerFrame = "classicPlayerFrame"
        static let playerLogicalFrame = "classicPlayerLogicalFrame"
    }

    private let defaults: UserDefaults
    var activeProviderID: String { didSet { defaults.set(activeProviderID, forKey: Keys.provider) } }
    var skinScale: Int { didSet { defaults.set(skinScale, forKey: Keys.skinScale) } }
    var showPlayerOnLaunch: Bool { didSet { defaults.set(showPlayerOnLaunch, forKey: Keys.playerOnLaunch) } }
    var playerFloating: Bool { didSet { defaults.set(playerFloating, forKey: Keys.playerFloating) } }
    var playerShadow: Bool { didSet { defaults.set(playerShadow, forKey: Keys.playerShadow) } }
    var clickThroughTransparentPixels: Bool { didSet { defaults.set(clickThroughTransparentPixels, forKey: Keys.clickThrough) } }
    var visualizationFrameRate: Int { didSet { defaults.set(visualizationFrameRate, forKey: Keys.frameRate) } }
    var visualizationIntensity: Double { didSet { defaults.set(visualizationIntensity, forKey: Keys.intensity) } }
    var selectedVisualization: String { didSet { defaults.set(selectedVisualization, forKey: Keys.visualization) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        activeProviderID = defaults.string(forKey: Keys.provider) ?? PlaybackProviderID.appleMusic.rawValue
        skinScale = defaults.object(forKey: Keys.skinScale) as? Int ?? 2
        showPlayerOnLaunch = defaults.object(forKey: Keys.playerOnLaunch) as? Bool ?? true
        playerFloating = defaults.object(forKey: Keys.playerFloating) as? Bool ?? false
        playerShadow = defaults.object(forKey: Keys.playerShadow) as? Bool ?? true
        clickThroughTransparentPixels = defaults.object(forKey: Keys.clickThrough) as? Bool ?? true
        visualizationFrameRate = defaults.object(forKey: Keys.frameRate) as? Int ?? 30
        visualizationIntensity = defaults.object(forKey: Keys.intensity) as? Double ?? 0.7
        selectedVisualization = defaults.string(forKey: Keys.visualization) ?? "spectrum"
    }

    func savePlayerFrame(_ frame: CGRect) { defaults.set(NSStringFromRect(frame), forKey: Keys.playerFrame) }
    func restoredPlayerFrame() -> CGRect? {
        guard let value = defaults.string(forKey: Keys.playerFrame) else { return nil }
        let rect = NSRectFromString(value)
        return rect.isEmpty ? nil : rect
    }

    func savePlayerLogicalFrame(_ frame: CGRect) {
        defaults.set(NSStringFromRect(frame), forKey: Keys.playerLogicalFrame)
    }

    func restoredPlayerLogicalFrame() -> CGRect? {
        guard let value = defaults.string(forKey: Keys.playerLogicalFrame) else { return nil }
        let rect = NSRectFromString(value)
        return rect.isEmpty ? nil : rect
    }
}
