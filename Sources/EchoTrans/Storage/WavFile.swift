import Foundation
import AVFoundation

/// 增量写入 16kHz 单声道 16-bit PCM WAV 文件（采集过程中持续落盘，供本地引擎在会话结束时重新转写）
final class WavFileWriter {
    let fileURL: URL
    private let fileHandle: FileHandle?
    private var totalFrames = 0
    private(set) var isFinalized = false

    init?(url: URL, sampleRate: Int32 = 16000) {
        fileURL = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        fileHandle = handle
        try? handle.write(contentsOf: Self.makeHeader(sampleRate: sampleRate, dataBytes: 0))
    }

    /// 追加一帧 AVAudioPCMBuffer 的声道 0 数据
    func append(buffer: AVAudioPCMBuffer) {
        guard !isFinalized, let channel = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let source = UnsafeBufferPointer(start: channel[0], count: frames)
        var int16 = [Int16]()
        int16.reserveCapacity(frames)
        for sample in source {
            let clamped = max(-1.0, min(1.0, sample))
            int16.append(Int16(clamped * 32767.0))
        }
        let data = int16.withUnsafeBufferPointer { Data(buffer: $0) }
        try? fileHandle?.write(contentsOf: data)
        totalFrames += frames
    }

    /// 回填 WAV 头并关闭文件
    func finalize() {
        guard !isFinalized else { return }
        isFinalized = true
        let dataBytes = totalFrames * 2
        try? fileHandle?.seek(toOffset: 0)
        try? fileHandle?.write(contentsOf: Self.makeHeader(sampleRate: 16000, dataBytes: dataBytes))
        try? fileHandle?.close()
    }

    deinit { finalize() }

    private static func makeHeader(sampleRate: Int32, dataBytes: Int) -> Data {
        var header = Data()
        func ascii(_ s: String) { header.append(Data(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }

        let byteRate = UInt32(sampleRate) * 2  // 单声道 16-bit
        ascii("RIFF"); u32(UInt32(36 + dataBytes)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(byteRate)
        u16(2); u16(16)
        ascii("data"); u32(UInt32(dataBytes))
        return header
    }
}

/// 读取 WAV 文件为 Float32 采样（16-bit PCM，多声道取平均）
enum WavFileReader {
    struct WavError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func readSamples(url: URL) throws -> (samples: [Float], sampleRate: Int32) {
        let data = try Data(contentsOf: url)
        guard data.count > 44, String(data: data.prefix(4), encoding: .ascii) == "RIFF" else {
            throw WavError(message: "无效的 WAV 文件：\(url.lastPathComponent)")
        }

        var offset = 12
        var sampleRate: Int32 = 16000
        var bitsPerSample: Int16 = 16
        var channels: Int16 = 1
        var audioData = Data()

        while offset + 8 <= data.count {
            let chunkId = String(data: data.subdata(in: offset..<offset+4), encoding: .ascii) ?? ""
            let chunkSize = data.subdata(in: offset+4..<offset+8).withUnsafeBytes {
                $0.load(as: UInt32.self)
            }
            let bodyStart = offset + 8
            switch chunkId {
            case "fmt ":
                let fmt = data.subdata(in: bodyStart..<bodyStart+16)
                fmt.withUnsafeBytes { raw in
                    channels = raw.load(fromByteOffset: 2, as: Int16.self)
                    sampleRate = raw.load(fromByteOffset: 4, as: Int32.self)
                    bitsPerSample = raw.load(fromByteOffset: 14, as: Int16.self)
                }
            case "data":
                audioData = data.subdata(in: bodyStart..<bodyStart+Int(chunkSize))
            default:
                break
            }
            offset = bodyStart + Int(chunkSize)
            if chunkSize % 2 == 1 { offset += 1 }
        }

        guard bitsPerSample == 16 else {
            throw WavError(message: "仅支持 16-bit PCM，实际 \(bitsPerSample)-bit")
        }

        let bytes = [UInt8](audioData)
        let ch = Int(max(channels, 1))
        var samples = [Float]()
        samples.reserveCapacity(bytes.count / 2 / ch)

        var i = 0
        while i + 1 < bytes.count {
            var sum: Float = 0
            var read = 0
            while read < ch && i + 1 < bytes.count {
                let v = Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i+1]) << 8))
                sum += Float(v)
                i += 2
                read += 1
            }
            samples.append(Float(sum / Float(ch)) / 32768.0)
        }
        return (samples, sampleRate)
    }
}
