import Darwin
import Foundation
import MiraCore

enum LibraryArchiveIO {
    static let invalid = MiraError(.storage, "The library archive is invalid or unsupported.")

    static func validatePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 512 else { throw invalid }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 8,
            components.allSatisfy({ component in
                !component.isEmpty && component.first != "." && component.utf8.count <= 128
                    && component.utf8.allSatisfy { byte in
                        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                            || byte == 46 || byte == 45 || byte == 95
                    }
            })
        else { throw invalid }
    }

    static func file(_ path: String, under root: URL, createParents: Bool = false) throws -> URL {
        try validatePath(path)
        try FileSessionIO.checkDirectory(root)
        var parent = root
        let parts = path.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            parent.appendPathComponent(part, isDirectory: true)
            if createParents {
                try FileSessionIO.ensureDirectory(parent)
            } else {
                try FileSessionIO.checkDirectory(parent)
            }
        }
        return parent.appendingPathComponent(parts.last!)
    }

    static func requireSingleFile(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
            value.st_nlink == 1, value.st_size >= 0
        else { throw invalid }
    }

    static func byteCount(_ url: URL, limit: Int) throws -> Int64 {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw invalid }
        defer { Darwin.close(fd) }
        try FileSessionIO.requireRegular(fd)
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_size >= 0, value.st_size <= limit else { throw invalid }
        return value.st_size
    }

    static func write(_ bytes: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw invalid }
        defer { Darwin.close(fd) }
        try FileSessionIO.requireRegular(fd)
        try FileSessionIO.write(bytes, fd: fd)
        try FileSessionIO.sync(fd)
    }

    /// The caller owns this newly created stage until exclusive publication succeeds.
    static func createStage(for destination: URL) throws -> (stage: URL, destination: URL) {
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty,
            destination.lastPathComponent != ".", destination.lastPathComponent != ".."
        else { throw invalid }
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        try FileSessionIO.checkDirectory(parent)
        let target = parent.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        var existing = stat()
        guard lstat(target.path, &existing) != 0, errno == ENOENT else {
            throw MiraError(.conflict, "The archive destination already exists.")
        }
        let stage = parent.appendingPathComponent(".mira-archive-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(stage.path, 0o700) == 0 else { throw invalid }
        do { try FileSessionIO.syncDirectory(parent) } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
        return (stage, target)
    }

    /// Iterate canonical files in full-path order, retaining only the active directory stack.
    /// Empty directories are valid only for the required session layout.
    final class FileIterator {
        private struct Entry { let path: String; let url: URL; let isDirectory: Bool }
        private final class Frame {
            let entries: [Entry]
            let depth: Int
            var index = 0
            init(entries: [Entry], depth: Int) { self.entries = entries; self.depth = depth }
        }
        private let required: Set<String> = ["Sessions", "Sessions/sessions", "Sessions/payloads"]
        private var seenRequired: Set<String> = []
        private var remaining = LibraryArchiveLimits.maximumDirectoryEntries
        private var fileCount = 0
        private var stack: [Frame] = []

        init(directory root: URL) throws { try push(root, prefix: "", depth: 0) }

        private func push(_ directory: URL, prefix: String, depth: Int) throws {
            guard depth <= 8 else { throw LibraryArchiveIO.invalid }
            let urls = try FileSessionIO.directoryEntries(directory, limit: remaining)
            remaining -= urls.count
            if urls.isEmpty, !required.contains(String(prefix.dropLast())) { throw LibraryArchiveIO.invalid }
            var entries: [Entry] = []
            for url in urls {
                let path = prefix + url.lastPathComponent
                try LibraryArchiveIO.validatePath(path)
                var value = stat()
                guard lstat(url.path, &value) == 0 else { throw LibraryArchiveIO.invalid }
                let isDirectory = value.st_mode & S_IFMT == S_IFDIR
                if isDirectory { try FileSessionIO.checkDirectory(url) }
                else { try LibraryArchiveIO.requireSingleFile(url) }
                entries.append(.init(path: path, url: url, isDirectory: isDirectory))
            }
            entries.sort { ($0.path + ($0.isDirectory ? "/" : "")) < ($1.path + ($1.isDirectory ? "/" : "")) }
            stack.append(Frame(entries: entries, depth: depth))
        }

        func next() throws -> String? {
            while let frame = stack.last {
                guard frame.index < frame.entries.count else { stack.removeLast(); continue }
                let entry = frame.entries[frame.index]
                frame.index += 1
                if entry.isDirectory {
                    if required.contains(entry.path) { seenRequired.insert(entry.path) }
                    try push(entry.url, prefix: entry.path + "/", depth: frame.depth + 1)
                } else {
                    guard fileCount < LibraryArchiveLimits.maximumPhysicalFiles else { throw LibraryArchiveIO.invalid }
                    fileCount += 1
                    return entry.path
                }
            }
            guard seenRequired == required else { throw LibraryArchiveIO.invalid }
            return nil
        }
    }

    static func forEachFile(_ root: URL, _ visit: (String) throws -> Void) throws {
        let iterator = try FileIterator(directory: root)
        while let path = try iterator.next() { try visit(path) }
    }

    static func inventory(_ root: URL) throws -> [String] {
        var paths: [String] = []
        try forEachFile(root) { paths.append($0) }
        return paths
    }

    static func syncTree(_ root: URL) throws {
        var directories: Set<URL> = [root]
        try forEachFile(root) { path in
            let file = try file(path, under: root)
            try FileSessionIO.syncFile(file)
            var parent = file.deletingLastPathComponent()
            while parent.path != root.path {
                directories.insert(parent)
                parent.deleteLastPathComponent()
            }
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            try FileSessionIO.syncDirectory(directory)
        }
    }

    /// Source adapters may create their empty blob directories while opening.
    /// Only a privately owned, closed restoration stage may use this operation.
    static func removeEmptyStageDirectories(_ root: URL) throws {
        let required: Set<String> = ["", "Sessions", "Sessions/sessions", "Sessions/payloads"]
        var visited = 0
        func visit(_ directory: URL, relative: String, depth: Int) throws {
            guard depth <= 8 else { throw invalid }
            try FileSessionIO.checkDirectory(directory)
            let children = try FileSessionIO.directoryEntries(
                directory, limit: LibraryArchiveLimits.maximumDirectoryEntries - visited)
            visited += children.count
            for child in children {
                let path = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                try validatePath(path)
                var value = stat()
                guard lstat(child.path, &value) == 0 else { throw invalid }
                if value.st_mode & S_IFMT == S_IFDIR { try visit(child, relative: path, depth: depth + 1) }
                else { try requireSingleFile(child) }
            }
            if !required.contains(relative), rmdir(directory.path) != 0, errno != ENOTEMPTY { throw invalid }
        }
        try visit(root, relative: "", depth: 0)
    }
}
