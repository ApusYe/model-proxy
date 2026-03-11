import Foundation

protocol LineageStoring: Sendable {
    func loadLineages() throws -> [String: ConversationLineage]
    func saveLineages(_ lineages: [String: ConversationLineage]) throws
}

struct FileLineageStore: LineageStoring {
    let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadLineages() throws -> [String: ConversationLineage] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([String: ConversationLineage].self, from: data)
    }

    func saveLineages(_ lineages: [String: ConversationLineage]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        let data = try encoder.encode(lineages)
        try data.write(to: fileURL, options: [.atomic])
    }
}

enum LineageStoreFactory {
    static func makeDefaultStore() -> any LineageStoring {
        FileLineageStore(fileURL: defaultFileURL())
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseURL
            .appendingPathComponent("ModelProxy", isDirectory: true)
            .appendingPathComponent("lineages.json", isDirectory: false)
    }
}
