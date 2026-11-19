import Foundation

extension FileHandle {
    /// Delivers each chunk that arrives, then stops reading once the writer closes its end.
    public func readChunksUntilEnd(
        onChunk: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable () -> Void = {}
    ) {
        readabilityHandler = { handle in
            let chunk = handle.availableData
            guard chunk.isEmpty else { return onChunk(chunk) }
            // A readabilityHandler left installed at end of file is called again immediately and forever, keeping
            // one core busy for as long as the app runs.
            handle.readabilityHandler = nil
            onEnd()
        }
    }
}
