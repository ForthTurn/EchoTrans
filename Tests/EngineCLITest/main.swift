//
//  main.swift — 本地转写引擎 CLI 冒烟测试
//
//  用法: enginetest <whisper|sensevoice> <模型路径> <tokens路径或-> <wav路径>
//
//  读取 16-bit PCM WAV → Float32 → 调用桥接层 → 打印转写文本与耗时
//

import Foundation

func readWavSamples(path: String) -> (samples: [Float], sampleRate: Int32) {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count > 44, String(data: data.prefix(4), encoding: .ascii) == "RIFF" else {
        fatalError("不是 RIFF/WAV 文件: \(path)")
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

    guard bitsPerSample == 16 else { fatalError("仅支持 16-bit PCM，实际 \(bitsPerSample)-bit") }

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

let args = CommandLine.arguments
guard args.count >= 5 else {
    print("用法: enginetest <whisper|sensevoice> <模型路径> <tokens路径或-> <wav路径>")
    exit(2)
}

let engine = args[1], modelPath = args[2], tokensPath = args[3], wavPath = args[4]
let (samples, sampleRate) = readWavSamples(path: wavPath)
print("音频: \(samples.count) 采样 @ \(sampleRate)Hz (\(String(format: "%.1f", Double(samples.count) / Double(sampleRate)))s)")

var out: UnsafeMutablePointer<CChar>?
var rc: Int32
let start = Date()

switch engine {
case "whisper":
    rc = et_whisper_transcribe(modelPath, "auto", samples, Int32(samples.count), &out)
case "sensevoice":
    rc = et_sensevoice_transcribe(modelPath, tokensPath, "", samples, Int32(samples.count), sampleRate, &out)
default:
    print("未知引擎: \(engine)")
    exit(2)
}

let elapsed = Date().timeIntervalSince(start)
guard rc == 0, let out else {
    print("❌ 转写失败 rc=\(rc)")
    exit(1)
}

let text = String(cString: out)
et_free_string(out)
let audioSec = Double(samples.count) / Double(sampleRate)
print("✅ [\(engine)] 耗时 \(String(format: "%.1f", elapsed))s（实时率 \(String(format: "%.2f", elapsed / audioSec))）")
print("---- 转写结果 ----")
print(text)
