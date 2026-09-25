import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class SkinLibraryStore {
    private enum Keys {
        static let activeSkinID = "activeSkinID"
        static let fallback = "__fallback__"
    }

    private(set) var skins: [ImportedSkin] = []
    private(set) var activeCatalog: SkinAssetCatalog = .fallback()
    private(set) var activeSkinID: String?
    private(set) var lastError: String?
    private let loader = SkinArchiveLoader()
    private let root: URL
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private var didRestore = false

    init(fileManager: FileManager = .default, defaults: UserDefaults = .standard, root: URL? = nil) {
        self.fileManager = fileManager
        self.defaults = defaults
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.root = root ?? support.appending(path: "Macamp/Skins", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func restoreLibrary() async {
        guard !didRestore else { return }
        didRestore = true
        let storedSelection = defaults.string(forKey: Keys.activeSkinID)
        let requestedActiveID = storedSelection == Keys.fallback ? nil : storedSelection
        let shouldMigratePreviousImports = storedSelection == nil
        let directories = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var restored: [ImportedSkin] = []
        var restoredActiveCatalog: SkinAssetCatalog?

        let newestFirst = directories.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        var restoredActiveID: String?
        for directory in newestFirst {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let archive = archivedSkin(in: directory) else { continue }
            do {
                let loaded = try await loader.load(url: archive)
                let imported = importedSkin(id: directory.lastPathComponent, directory: directory, archive: archive, loaded: loaded)
                restored.append(imported)
                if imported.id == requestedActiveID, loaded.report.isValid {
                    restoredActiveCatalog = makeCatalog(for: imported, loaded: loaded)
                    restoredActiveID = imported.id
                } else if shouldMigratePreviousImports, restoredActiveCatalog == nil, loaded.report.isValid {
                    // Older builds copied skins but did not persist an active ID.
                    // Their most recently imported skin was the active one.
                    restoredActiveCatalog = makeCatalog(for: imported, loaded: loaded)
                    restoredActiveID = imported.id
                }
            } catch {
                // Keep scanning: one damaged import must not hide the remaining skins.
                lastError = "Could not restore \(archive.lastPathComponent): \(error.localizedDescription)"
            }
        }

        skins = restored.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let restoredActiveCatalog, let restoredActiveID {
            activeCatalog = restoredActiveCatalog
            activeSkinID = restoredActiveID
            defaults.set(restoredActiveID, forKey: Keys.activeSkinID)
        } else {
            activeCatalog = .fallback()
            activeSkinID = nil
            defaults.set(Keys.fallback, forKey: Keys.activeSkinID)
        }
    }

    func importSkin(from sourceURL: URL) async {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            let loaded = try await loader.load(url: sourceURL)
            let id = UUID().uuidString
            let destination = root.appending(path: id, directoryHint: .isDirectory)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let archiveDirectory = destination.appending(path: "Original", directoryHint: .isDirectory)
            let contentsDirectory = destination.appending(path: "Contents", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: contentsDirectory, withIntermediateDirectories: true)
            let archive = archiveDirectory.appending(path: sourceURL.lastPathComponent)
            try fileManager.copyItem(at: sourceURL, to: archive)
            for (name, data) in loaded.files {
                let assetURL = contentsDirectory.appending(path: name)
                try fileManager.createDirectory(at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: assetURL, options: .atomic)
            }
            let imported = importedSkin(id: id, directory: destination, archive: archive, loaded: loaded)
            skins.append(imported)
            if loaded.report.isValid {
                activeCatalog = makeCatalog(for: imported, loaded: loaded)
                activeSkinID = imported.id
                defaults.set(imported.id, forKey: Keys.activeSkinID)
                lastError = nil
            } else {
                lastError = loaded.report.errors.joined(separator: " ")
            }
        } catch { lastError = error.localizedDescription }
    }

    func use(_ skin: ImportedSkin) async {
        do {
            let loaded = try await loader.load(url: skin.originalArchive)
            guard loaded.report.isValid else {
                lastError = loaded.report.errors.joined(separator: " ")
                return
            }
            activeCatalog = makeCatalog(for: skin, loaded: loaded)
            activeSkinID = skin.id
            defaults.set(skin.id, forKey: Keys.activeSkinID)
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func useFallback() {
        activeCatalog = .fallback()
        activeSkinID = nil
        defaults.set(Keys.fallback, forKey: Keys.activeSkinID)
    }

    func delete(_ skin: ImportedSkin) {
        try? fileManager.removeItem(at: skin.directory)
        skins.removeAll { $0.id == skin.id }
        if activeSkinID == skin.id { useFallback() }
    }

    private func archivedSkin(in directory: URL) -> URL? {
        let archiveDirectory = directory.appending(path: "Original", directoryHint: .isDirectory)
        return (try? fileManager.contentsOfDirectory(at: archiveDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
            .first { ["wsz", "wal", "zip"].contains($0.pathExtension.lowercased()) }
    }

    private func importedSkin(id: String, directory: URL, archive: URL, loaded: LoadedSkinArchive) -> ImportedSkin {
        ImportedSkin(
            id: id,
            name: loaded.modern?.name ?? archive.deletingPathExtension().lastPathComponent,
            directory: directory,
            originalArchive: archive,
            format: loaded.format,
            report: loaded.report
        )
    }

    private func makeCatalog(for skin: ImportedSkin, loaded: LoadedSkinArchive) -> SkinAssetCatalog {
        SkinAssetCatalog(
            name: skin.name,
            files: loaded.files,
            report: loaded.report,
            format: loaded.format,
            modern: loaded.modern
        )
    }
}
