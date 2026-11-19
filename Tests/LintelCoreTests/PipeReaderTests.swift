import Foundation
import Testing
@testable import LintelCore

@Suite struct PipeReading {
    @Test func chunksArriveInOrderAndTheEndIsReportedOnce() async throws {
        let pipe = Pipe()
        let seen = CallbackLog()
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            pipe.fileHandleForReading.readChunksUntilEnd(
                onChunk: { seen.append($0) },
                onEnd: { seen.end(); finished.resume() }
            )
            pipe.fileHandleForWriting.write(Data("one\n".utf8))
            pipe.fileHandleForWriting.write(Data("two\n".utf8))
            try? pipe.fileHandleForWriting.close()
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(String(decoding: seen.data, as: UTF8.self) == "one\ntwo\n")
        #expect(seen.ends == 1)
        #expect(pipe.fileHandleForReading.readabilityHandler == nil)
    }

    @Test func noChunkCallbacksFollowTheEnd() async throws {
        let pipe = Pipe()
        let seen = CallbackLog()
        pipe.fileHandleForReading.readChunksUntilEnd(onChunk: { seen.append($0) }, onEnd: { seen.end() })
        try pipe.fileHandleForWriting.close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(seen.chunks == 0)
        #expect(seen.ends == 1)
    }
}

private final class CallbackLog: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()
    private var chunkCount = 0
    private var endCount = 0

    func append(_ chunk: Data) { lock.withLock { collected.append(chunk); chunkCount += 1 } }
    func end() { lock.withLock { endCount += 1 } }
    var data: Data { lock.withLock { collected } }
    var chunks: Int { lock.withLock { chunkCount } }
    var ends: Int { lock.withLock { endCount } }
}
