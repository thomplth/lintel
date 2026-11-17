import Foundation

/// The text files under a folder, read into memory once so they outlive the folder itself.
public struct FileSnapshot: Sendable {
    public struct File: Equatable, Sendable {
        public let path: String
        public let text: String
        public let modified: Date
    }

    private let files: [String: File]

    public init(of root: URL) {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        var files: [String: File] = [:]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
        while let url = walker?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            files[path] = File(path: path, text: text, modified: values.contentModificationDate ?? .distantPast)
        }
        self.files = files
    }

    public func text(at path: String) -> String? {
        files[path]?.text
    }

    public func file(at path: String) -> File? {
        files[path]
    }

    public func files(in folder: String, extension fileExtension: String) -> [File] {
        files.values
            .filter { $0.path.hasPrefix(folder + "/") && ($0.path as NSString).pathExtension == fileExtension }
            .sorted { $0.path < $1.path }
    }
}
