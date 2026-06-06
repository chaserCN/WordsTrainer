import Foundation

/// On-device content layout under Documents.
///
/// ```
/// Documents/Data/
///   flashgame.db
///   media/
///   <deck-uuid>/
///     media/
/// ```
nonisolated enum AppDataPaths {
    static let dataDirectoryName = "Data"
    static let databaseFileName = "flashgame.db"
    static let deckMediaFolderName = "media"
    nonisolated(unsafe) static var dataDirectoryOverride: URL?

    static func dataDirectoryURL() throws -> URL {
        if let dataDirectoryOverride {
            try FileManager.default.createDirectory(at: dataDirectoryOverride, withIntermediateDirectories: true)
            return dataDirectoryOverride
        }
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let data = documents.appendingPathComponent(dataDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        return data
    }

    static func databaseURL() throws -> URL {
        try dataDirectoryURL().appendingPathComponent(databaseFileName)
    }

    static func deckFolderURL(deckID: UUID) throws -> URL {
        try dataDirectoryURL().appendingPathComponent(deckID.databaseString, isDirectory: true)
    }

    static func appMediaRootURL() throws -> URL {
        try dataDirectoryURL()
    }

    /// Renames deck media folders whose names used uppercase UUIDs.
    static func normalizeDeckMediaFolders() throws {
        let dataDir = try dataDirectoryURL()
        let contents = try FileManager.default.contentsOfDirectory(
            at: dataDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for url in contents {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let name = url.lastPathComponent
            if name == databaseFileName { continue }
            let lower = name.lowercased()
            guard lower != name else { continue }
            let destination = dataDir.appendingPathComponent(lower, isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                for item in items {
                    try FileManager.default.moveItem(
                        at: item,
                        to: destination.appendingPathComponent(item.lastPathComponent)
                    )
                }
                try FileManager.default.removeItem(at: url)
            } else {
                try FileManager.default.moveItem(at: url, to: destination)
            }
        }
    }

    static func mediaFileURL(deckID: UUID, relativePath: String) throws -> URL? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let deckRoot = try deckFolderURL(deckID: deckID)
        let url = deckRoot.appendingPathComponent(trimmed)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func appMediaFileURL(relativePath: String) throws -> URL? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let root = try appMediaRootURL()
        let url = root.appendingPathComponent(trimmed)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
