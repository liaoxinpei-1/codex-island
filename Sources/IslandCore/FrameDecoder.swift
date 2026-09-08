import Foundation

public struct IPCFrameDecoder {
    public enum FrameError: Error { case tooLarge }
    public static let maxBytes = 32 * 1024 * 1024
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        var cursor = 0
        while buffer.count - cursor >= 4 {
            let i = buffer.startIndex + cursor
            let size = (0..<4).reduce(0) { $0 | Int(buffer[i + $1]) << ($1 * 8) }
            guard size <= Self.maxBytes else { throw FrameError.tooLarge }
            guard buffer.count - cursor >= size + 4 else { break }
            frames.append(buffer.subdata(in: (i + 4)..<(i + 4 + size)))
            cursor += size + 4
        }
        if cursor > 0 { buffer.removeFirst(cursor) }
        return frames
    }
    public static func encode(_ data: Data) -> Data {
        var size = UInt32(data.count).littleEndian
        var result = withUnsafeBytes(of: &size) { Data($0) }
        result.append(data); return result
    }
}
