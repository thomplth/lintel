import Foundation
import Testing
@testable import LintelCore

@Suite struct FileSnapshotting {
    func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Modules"), withIntermediateDirectories: true)
        try "clock".write(to: root.appending(path: "Modules/clock.js"), atomically: true, encoding: .utf8)
        try "battery".write(to: root.appending(path: "Modules/battery.js"), atomically: true, encoding: .utf8)
        try "kit".write(to: root.appending(path: "kit.css"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func filesStayReadableAfterTheFolderIsDeleted() throws {
        let root = try makeFolder()
        let snapshot = FileSnapshot(of: root)
        try FileManager.default.removeItem(at: root)
        #expect(snapshot.text(at: "Modules/clock.js") == "clock")
        #expect(snapshot.text(at: "kit.css") == "kit")
    }

    @Test func aFolderListsItsFilesOfOneExtensionInNameOrder() throws {
        let root = try makeFolder()
        let snapshot = FileSnapshot(of: root)
        try FileManager.default.removeItem(at: root)
        #expect(snapshot.files(in: "Modules", extension: "js").map(\.path) == ["Modules/battery.js", "Modules/clock.js"])
        #expect(snapshot.files(in: "Modules", extension: "css").isEmpty)
    }

    @Test func aFileKeepsTheModificationDateItHadWhenTaken() throws {
        let root = try makeFolder()
        let file = root.appending(path: "Modules/clock.js")
        let taken = try #require(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let snapshot = FileSnapshot(of: root)
        try FileManager.default.removeItem(at: root)
        #expect(snapshot.files(in: "Modules", extension: "js").last?.modified == taken)
    }

    @Test func aMissingFolderGivesAnEmptySnapshot() {
        let snapshot = FileSnapshot(of: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(snapshot.files(in: "Modules", extension: "js").isEmpty)
        #expect(snapshot.text(at: "kit.css") == nil)
    }
}
