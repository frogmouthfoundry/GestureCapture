//
//  GestureStore.swift
//  GestureKit
//
//  A gesture is a bundle of sibling files in Documents/Gestures:
//  <uuid>.gesture.json (+ <uuid>.png thumbnail, <uuid>.mp4 replay).
//

import Foundation

@Observable
@MainActor
public final class GestureStore {

    public private(set) var gestures: [GestureFile] = []

    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? URL.documentsDirectory.appending(path: "Gestures", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        reload()
    }

    public func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        gestures = files
            .filter { $0.lastPathComponent.hasSuffix(".gesture.json") }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? GestureFile.decode(from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func save(_ gesture: GestureFile) throws {
        try gesture.encoded().write(to: jsonURL(for: gesture.id), options: .atomic)
        reload()
    }

    public func delete(_ gesture: GestureFile) {
        for url in [jsonURL(for: gesture.id), thumbnailURL(for: gesture.id), videoURL(for: gesture.id)] {
            try? FileManager.default.removeItem(at: url)
        }
        reload()
    }

    public func jsonURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).gesture.json")
    }

    public func thumbnailURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).png")
    }

    public func videoURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).mp4")
    }

    public func hasThumbnail(_ gesture: GestureFile) -> Bool {
        FileManager.default.fileExists(atPath: thumbnailURL(for: gesture.id).path)
    }

    public func hasVideo(_ gesture: GestureFile) -> Bool {
        FileManager.default.fileExists(atPath: videoURL(for: gesture.id).path)
    }
}
