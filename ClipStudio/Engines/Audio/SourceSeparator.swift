//
//  SourceSeparator.swift
//  ClipStudio — Engines/Audio (Part 4)
//
//  Splits a sound into two stems — "voice" and "background" — on device:
//  • stereo: centre-channel extraction. Per STFT bin, the in-phase coherence of
//    left and right (2·Re(L·R*) / (|L|²+|R|²)) tells how "centred" the sound is;
//    dialogue and lead vocals are usually centred, music and ambience are wide.
//    The mask is limited to the speech band (≈120 Hz–8 kHz).
//  • voice focus (mono sources): separates speech from steady background noise
//    with a noise-floor Wiener mask in the speech band.
//  • Core ML (optional): a user-imported mask model (see VoiceSeparationModel).
//  Background = original − voice, so the two stems always add up to the original.
//  STFT 2048 / hop 512 with √Hann windows (perfect reconstruction), streamed —
//  memory stays flat for long files. Output: two AAC (.m4a) files.
//

import Foundation
import AVFoundation
import Accelerate
import CoreML

enum SeparationMethod: String, CaseIterable, Identifiable, Hashable {
    case automatic, stereo, voiceFocus, coreML

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "تلقائي"
        case .stereo: "فصل المنتصف (ستيريو)"
        case .voiceFocus: "عزل الكلام عن الضوضاء"
        case .coreML: "نموذج Core ML المستورد"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "يختار الطريقة المناسبة حسب الملف."
        case .stereo: "مناسب للأغاني والفيديوهات المسجلة بالستيريو: الصوت الموجود في المنتصف (الكلام والغناء) يُفصل عن الموسيقى العريضة."
        case .voiceFocus: "للتسجيلات الأحادية: يفصل الكلام عن الضوضاء الثابتة (مكيف، هواء، همهمة). لا يفصل الموسيقى."
        case .coreML: "أدق نتيجة عند استيراد نموذج فصل متوافق من الإعدادات."
        }
    }
}

enum SeparationError: LocalizedError {
    case noAudio
    case readFailed
    case writeFailed
    case modelMissing
    case invalidModel(String)

    var errorDescription: String? {
        switch self {
        case .noAudio: "هذا المقطع بدون صوت."
        case .readFailed: "تعذرت قراءة الصوت."
        case .writeFailed: "تعذرت كتابة ملفات الصوت الناتجة."
        case .modelMissing: "لم يتم استيراد نموذج فصل بعد — استورده من «الإعدادات» أو اختر طريقة أخرى."
        case .invalidModel(let reason): "النموذج غير متوافق: " + reason
        }
    }
}

struct SeparationResult {
    var voiceURL: URL
    var backgroundURL: URL
    var method: SeparationMethod
    var duration: Double
}

// MARK: - Streaming STFT separator

final class SpectralVoiceSeparator {
    static let fftSize = 2048
    static let hop = 512
    static var bins: Int { fftSize / 2 + 1 }
    private static let log2n = vDSP_Length(11)

    let channels: Int
    let sampleRate: Double
    let method: SeparationMethod
    private let model: VoiceSeparationModel?
    private let n = SpectralVoiceSeparator.fftSize
    private let half = SpectralVoiceSeparator.fftSize / 2
    private let hop = SpectralVoiceSeparator.hop
    private let setup: FFTSetup?
    private let window: [Float]

    private var fifo: [[Float]]
    private var analysisPosition = 0
    private var synthesisPosition = 0
    private var accumulator: [[Float]]
    private var queue: [[(re: [Float], im: [Float])]] = []

    // Mask state.
    private var smoothedCoherence: [Float]
    private var smoothedPower: [Float]
    private var noiseFloor: [Float]
    private var previousMask: [Float]
    private var framesSeen = 0
    private let bandWeights: [Float]

    /// Separated samples ready to be written (per channel).
    private(set) var voiceOut: [[Float]]
    private(set) var backgroundOut: [[Float]]
    /// Leading samples to drop (the analysis padding).
    private var toSkip: Int

    init(channels: Int, sampleRate: Double, method: SeparationMethod, model: VoiceSeparationModel?) {
        let n = SpectralVoiceSeparator.fftSize
        let half = n / 2
        self.channels = max(1, channels)
        self.sampleRate = sampleRate
        self.method = method
        self.model = model
        setup = vDSP_create_fftsetup(SpectralVoiceSeparator.log2n, FFTRadix(kFFTRadix2))
        window = (0..<n).map { Float(sqrt(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)))) }
        let padding = n - SpectralVoiceSeparator.hop
        fifo = Array(repeating: [Float](repeating: 0, count: padding), count: max(1, channels))
        accumulator = Array(repeating: [Float](repeating: 0, count: n), count: max(1, channels))
        smoothedCoherence = [Float](repeating: 0, count: half + 1)
        smoothedPower = [Float](repeating: 0, count: half + 1)
        noiseFloor = [Float](repeating: 0, count: half + 1)
        previousMask = [Float](repeating: 0, count: half + 1)
        voiceOut = Array(repeating: [], count: max(1, channels))
        backgroundOut = Array(repeating: [], count: max(1, channels))
        toSkip = padding
        // Speech band with soft edges: 120–200 Hz rise, 6–8 kHz fall.
        bandWeights = (0...half).map { k in
            let f = Double(k) * sampleRate / Double(n)
            if f < 120 || f > 8_000 { return 0 }
            if f < 200 { return Float((f - 120) / 80) }
            if f > 6_000 { return Float((8_000 - f) / 2_000) }
            return 1
        }
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    /// Interleaved float input.
    func append(interleaved samples: UnsafeBufferPointer<Float>) throws {
        let frames = samples.count / channels
        for c in 0..<channels {
            fifo[c].reserveCapacity(fifo[c].count + frames)
            for i in 0..<frames { fifo[c].append(samples[i * channels + c]) }
        }
        try run()
    }

    /// Pads the end and processes everything left.
    func finish() throws {
        for c in 0..<channels { fifo[c].append(contentsOf: [Float](repeating: 0, count: n)) }
        try run()
        try resolveQueue()
    }

    func drainOutput() -> (voice: [[Float]], background: [[Float]]) {
        let result = (voiceOut, backgroundOut)
        voiceOut = Array(repeating: [], count: channels)
        backgroundOut = Array(repeating: [], count: channels)
        return result
    }

    private var batchSize: Int { method == .coreML ? (model?.frames ?? 1) : 1 }

    private func run() throws {
        while fifo[0].count - analysisPosition >= n {
            queue.append(analyze(at: analysisPosition))
            analysisPosition += hop
            if queue.count >= batchSize { try resolveQueue() }
        }
        if synthesisPosition > 131_072 {
            for c in 0..<channels { fifo[c].removeFirst(synthesisPosition) }
            analysisPosition -= synthesisPosition
            synthesisPosition = 0
        }
    }

    private func analyze(at position: Int) -> [(re: [Float], im: [Float])] {
        guard let setup else { return [] }
        var spectra: [(re: [Float], im: [Float])] = []
        let count = n
        let halfCount = half
        for c in 0..<channels {
            var windowed = [Float](repeating: 0, count: count)
            fifo[c].withUnsafeBufferPointer { input in
                vDSP_vmul(input.baseAddress! + position, 1, window, 1, &windowed, 1, vDSP_Length(count))
            }
            var re = [Float](repeating: 0, count: halfCount)
            var im = [Float](repeating: 0, count: halfCount)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfCount) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfCount))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, SpectralVoiceSeparator.log2n, FFTDirection(FFT_FORWARD))
                }
            }
            spectra.append((re, im))
        }
        return spectra
    }

    private func resolveQueue() throws {
        guard !queue.isEmpty else { return }
        let masks: [[Float]]
        switch method {
        case .coreML:
            guard let model else { throw SeparationError.modelMissing }
            masks = try model.masks(for: queue.map(midMagnitude))
        case .stereo where channels >= 2:
            masks = queue.map(stereoMask)
        default:
            masks = queue.map(voiceFocusMask)
        }
        for (frame, mask) in zip(queue, masks) { synthesize(frame, mask: mask) }
        queue.removeAll(keepingCapacity: true)
    }

    // MARK: Masks (bins 0…half; bin `half` = Nyquist, stored in im[0])

    private func value(_ spectrum: (re: [Float], im: [Float]), _ k: Int) -> (Float, Float) {
        if k == 0 { return (spectrum.re[0], 0) }
        if k == half { return (spectrum.im[0], 0) }
        return (spectrum.re[k], spectrum.im[k])
    }

    private func midMagnitude(_ frame: [(re: [Float], im: [Float])]) -> [Float] {
        (0...half).map { k in
            var r: Float = 0, i: Float = 0
            for spectrum in frame {
                let v = value(spectrum, k)
                r += v.0
                i += v.1
            }
            let scale = 1 / Float(max(1, frame.count)) / Float(n)
            return sqrt(r * r + i * i) * scale
        }
    }

    private func stereoMask(_ frame: [(re: [Float], im: [Float])]) -> [Float] {
        let left = frame[0], right = frame[1]
        var mask = [Float](repeating: 0, count: half + 1)
        for k in 0...half {
            let (lr, li) = value(left, k)
            let (rr, ri) = value(right, k)
            let power = lr * lr + li * li + rr * rr + ri * ri
            let coherence = power > 1e-12 ? max(0, 2 * (lr * rr + li * ri) / power) : 0
            smoothedCoherence[k] = framesSeen == 0 ? coherence : 0.55 * smoothedCoherence[k] + 0.45 * coherence
            // Smoothstep 0.55 → 0.95: only clearly centred energy counts as voice.
            let x = min(1, max(0, (smoothedCoherence[k] - 0.55) / 0.4))
            mask[k] = x * x * (3 - 2 * x) * bandWeights[k]
        }
        framesSeen += 1
        return smoothed(mask)
    }

    private func voiceFocusMask(_ frame: [(re: [Float], im: [Float])]) -> [Float] {
        var mask = [Float](repeating: 0, count: half + 1)
        // Noise floor may rise ~3 dB per second (minimum statistics).
        let rise = Float(pow(10, 3.0 * Double(hop) / sampleRate / 10))
        for k in 0...half {
            var power: Float = 0
            for spectrum in frame {
                let v = value(spectrum, k)
                power += v.0 * v.0 + v.1 * v.1
            }
            power /= Float(frame.count)
            if framesSeen == 0 {
                smoothedPower[k] = power
                noiseFloor[k] = power
            } else {
                smoothedPower[k] = 0.7 * smoothedPower[k] + 0.3 * power
                noiseFloor[k] = min(noiseFloor[k] * rise, smoothedPower[k])
            }
            let gain = max(0, 1 - 1.8 * noiseFloor[k] / max(power, 1e-12))
            mask[k] = gain * bandWeights[k]
        }
        framesSeen += 1
        return smoothed(mask)
    }

    /// Frequency (3-bin) and time (fast attack, slower release) smoothing against musical noise.
    private func smoothed(_ raw: [Float]) -> [Float] {
        var result = raw
        for k in 0...half {
            let a = raw[max(0, k - 1)], b = raw[k], c = raw[min(half, k + 1)]
            let g = 0.25 * a + 0.5 * b + 0.25 * c
            let p = previousMask[k]
            result[k] = g > p ? 0.4 * p + 0.6 * g : 0.75 * p + 0.25 * g
            previousMask[k] = result[k]
        }
        return result
    }

    // MARK: Synthesis

    private func synthesize(_ frame: [(re: [Float], im: [Float])], mask: [Float]) {
        guard let setup else { return }
        let count = n
        let halfCount = half
        // zrip round trip scales by 2n; √Hann² at 75 % overlap sums to 2.
        let scale = Float(1.0 / (2.0 * Double(count))) * 0.5
        for c in 0..<channels {
            var re = frame[min(c, frame.count - 1)].re
            var im = frame[min(c, frame.count - 1)].im
            re[0] *= mask[0]
            im[0] *= mask[halfCount]
            for k in 1..<halfCount {
                re[k] *= mask[k]
                im[k] *= mask[k]
            }
            var output = [Float](repeating: 0, count: count)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, SpectralVoiceSeparator.log2n, FFTDirection(FFT_INVERSE))
                    output.withUnsafeMutableBufferPointer { op in
                        op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfCount) {
                            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(halfCount))
                        }
                    }
                }
            }
            for i in 0..<count { accumulator[c][i] += output[i] * window[i] * scale }
            // The first hop is final: voice = accumulated, background = original − voice.
            let start = synthesisPosition
            for i in 0..<hop {
                let voice = accumulator[c][i]
                let original = fifo[c][start + i]
                if i >= toSkip {
                    voiceOut[c].append(voice)
                    backgroundOut[c].append(original - voice)
                }
            }
            accumulator[c].removeFirst(hop)
            accumulator[c].append(contentsOf: [Float](repeating: 0, count: hop))
        }
        toSkip = max(0, toSkip - hop)
        synthesisPosition += hop
    }
}

// MARK: - Optional Core ML model

/// A user-imported mask model.
/// Contract: input "magnitude" Float32 [1, 1025, T] (STFT 2048 / hop 512 at 44.1 kHz,
/// mid channel, linear magnitude), output "mask" [1, 1025, T] with values 0…1 (voice).
final class VoiceSeparationModel {
    static let inputName = "magnitude"
    static let outputName = "mask"

    let model: MLModel
    let frames: Int

    init(model: MLModel) throws {
        self.model = model
        guard let input = model.modelDescription.inputDescriptionsByName[Self.inputName],
              let constraint = input.multiArrayConstraint else {
            throw SeparationError.invalidModel("يجب أن يكون للنموذج مدخل مصفوفة باسم «magnitude».")
        }
        guard model.modelDescription.outputDescriptionsByName[Self.outputName]?.type == .multiArray else {
            throw SeparationError.invalidModel("يجب أن يكون للنموذج مخرج مصفوفة باسم «mask».")
        }
        let shape = constraint.shape.map(\.intValue)
        guard shape.count == 3, shape[0] == 1, shape[1] == SpectralVoiceSeparator.bins, shape[2] > 0 else {
            throw SeparationError.invalidModel("شكل المدخل يجب أن يكون [1, 1025, T].")
        }
        frames = min(shape[2], 1024)
    }

    /// Masks for a batch of mid-channel magnitude frames (≤ `frames`).
    func masks(for magnitudes: [[Float]]) throws -> [[Float]] {
        let bins = SpectralVoiceSeparator.bins
        let input = try MLMultiArray(shape: [1, NSNumber(value: bins), NSNumber(value: frames)], dataType: .float32)
        let inStrides = input.strides.map(\.intValue)
        let inPointer = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        for i in 0..<input.count { inPointer[i] = 0 }
        for (t, frame) in magnitudes.enumerated() where t < frames {
            for k in 0..<min(bins, frame.count) { inPointer[k * inStrides[1] + t * inStrides[2]] = frame[k] }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [Self.inputName: MLFeatureValue(multiArray: input)])
        let output = try model.prediction(from: provider)
        guard let mask = output.featureValue(for: Self.outputName)?.multiArrayValue, mask.shape.count == 3 else {
            throw SeparationError.invalidModel("لم يُرجع النموذج «mask».")
        }
        let strides = mask.strides.map(\.intValue)
        let outFrames = mask.shape[2].intValue
        let outBins = mask.shape[1].intValue
        func read(_ index: Int) -> Float {
            switch mask.dataType {
            case .float32: return mask.dataPointer.bindMemory(to: Float.self, capacity: mask.count)[index]
            case .double: return Float(mask.dataPointer.bindMemory(to: Double.self, capacity: mask.count)[index])
            default: return mask[index].floatValue
            }
        }
        return magnitudes.indices.map { t in
            (0..<bins).map { k in
                guard k < outBins, t < outFrames else { return 0 }
                return min(1, max(0, read(k * strides[1] + t * strides[2])))
            }
        }
    }
}

/// Imports, validates and loads the optional separation model (Application Support/Models).
enum VoiceSeparationModelStore {
    static var directory: URL { StorageManager.shared.appSupport.appendingPathComponent("Models", isDirectory: true) }
    static var compiledURL: URL { directory.appendingPathComponent("VoiceSeparation.mlmodelc", isDirectory: true) }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: compiledURL.path) }

    static func load() throws -> VoiceSeparationModel {
        guard isInstalled else { throw SeparationError.modelMissing }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try VoiceSeparationModel(model: MLModel(contentsOf: compiledURL, configuration: configuration))
    }

    /// Compiles an .mlmodel / .mlpackage picked by the user, validates it and installs it.
    static func install(from source: URL) async throws {
        let compiled = try await MLModel.compileModel(at: source)
        _ = try VoiceSeparationModel(model: MLModel(contentsOf: compiled))
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: compiledURL.path) { try fm.removeItem(at: compiledURL) }
        try fm.moveItem(at: compiled, to: compiledURL)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: compiledURL)
    }
}

// MARK: - File driver

enum SourceSeparator {
    static let sampleRate: Double = 44_100

    /// Picks the method for `automatic` (stereo with real width → stereo, otherwise voice focus).
    static func resolvedMethod(_ requested: SeparationMethod, channels: Int, sideRatio: Double) -> SeparationMethod {
        switch requested {
        case .automatic:
            if VoiceSeparationModelStore.isInstalled { return .coreML }
            return channels >= 2 && sideRatio > 0.002 ? .stereo : .voiceFocus
        case .stereo:
            return channels >= 2 && sideRatio > 0.002 ? .stereo : .voiceFocus
        default:
            return requested
        }
    }

    private static func pcmSettings(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// Energy of (L−R) relative to (L+R) over the first 20 s — near 0 for dual-mono files.
    static func sideRatio(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange?) throws -> Double {
        let reader = try AVAssetReader(asset: asset)
        let start = range?.start ?? .zero
        let length = min(range?.duration.seconds ?? 20, 20)
        reader.timeRange = CMTimeRange(start: start, duration: CMTime(seconds: max(0.5, length), preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings(channels: 2))
        guard reader.canAdd(output) else { return 0 }
        reader.add(output)
        guard reader.startReading() else { return 0 }
        var side = 0.0, mid = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= MemoryLayout<Float>.size * 2 else { continue }
            let sampleCount = length / MemoryLayout<Float>.size
            var samples = [Float](repeating: 0, count: sampleCount)
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: sampleCount * MemoryLayout<Float>.size,
                                           destination: raw.baseAddress!)
            }
            guard status == noErr else { continue }
            var i = 0
            while i + 1 < samples.count {
                let l = Double(samples[i]), r = Double(samples[i + 1])
                side += (l - r) * (l - r)
                mid += (l + r) * (l + r)
                i += 2
            }
        }
        return mid > 1e-9 ? side / mid : 0
    }

    /// Separates `range` of the file into two .m4a stems in the staging folder.
    static func separate(url: URL, range: CMTimeRange?, method requested: SeparationMethod, control: RenderControl?,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> SeparationResult {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw SeparationError.noAudio }
        var sourceChannels = 2
        if let description = try await track.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            sourceChannels = Int(basic.mChannelsPerFrame)
        }
        let assetDuration = try await asset.load(.duration).seconds
        let duration = range?.duration.seconds ?? assetDuration
        let channels = sourceChannels >= 2 ? 2 : 1
        var ratio = 0.0
        if channels == 2 { ratio = try sideRatio(asset: asset, track: track, range: range) }
        var method = resolvedMethod(requested, channels: channels, sideRatio: ratio)
        var model: VoiceSeparationModel?
        if method == .coreML {
            do {
                model = try VoiceSeparationModelStore.load()
            } catch {
                // An automatic choice falls back to the built-in methods instead of failing.
                guard requested == .automatic else { throw error }
                method = channels >= 2 && ratio > 0.002 ? .stereo : .voiceFocus
            }
        }

        let reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings(channels: channels))
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SeparationError.readFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SeparationError.readFailed }

        let voiceURL = StorageManager.shared.stagingURL(extension: "m4a")
        let backgroundURL = StorageManager.shared.stagingURL(extension: "m4a")
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 2 ? 192_000 : 128_000
        ]
        let voiceFile: AVAudioFile
        let backgroundFile: AVAudioFile
        do {
            voiceFile = try AVAudioFile(forWriting: voiceURL, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            backgroundFile = try AVAudioFile(forWriting: backgroundURL, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw SeparationError.writeFailed
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false) else {
            throw SeparationError.writeFailed
        }

        let separator = SpectralVoiceSeparator(channels: channels, sampleRate: sampleRate, method: method, model: model)
        var inputFrames = 0
        var writtenFrames = 0
        let expected = max(1, duration * sampleRate)

        func write(final: Bool) throws {
            let (voice, background) = separator.drainOutput()
            var available = voice.first?.count ?? 0
            if final { available = min(available, max(0, inputFrames - writtenFrames)) }
            guard available > 0 else { return }
            for (file, stem) in [(voiceFile, voice), (backgroundFile, background)] {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(available)),
                      let data = buffer.floatChannelData else { throw SeparationError.writeFailed }
                buffer.frameLength = AVAudioFrameCount(available)
                for c in 0..<channels {
                    stem[c].withUnsafeBufferPointer { source in
                        data[c].update(from: source.baseAddress!, count: available)
                    }
                }
                try file.write(from: buffer)
            }
            writtenFrames += available
        }

        var scratch: [Float] = []
        do {
            while let buffer = output.copyNextSampleBuffer() {
                if control?.isCancelled == true || Task.isCancelled {
                    reader.cancelReading()
                    throw CancellationError()
                }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                let count = length / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                if scratch.count != count { scratch = [Float](repeating: 0, count: count) }
                let status = scratch.withUnsafeMutableBytes { raw -> OSStatus in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                               destination: raw.baseAddress!)
                }
                guard status == noErr else { continue }
                inputFrames += count / channels
                try scratch.withUnsafeBufferPointer { try separator.append(interleaved: $0) }
                try write(final: false)
                progress(min(0.98, Double(inputFrames) / expected))
            }
            if reader.status == .failed { throw reader.error ?? SeparationError.readFailed }
            try separator.finish()
            try write(final: true)
        } catch {
            try? FileManager.default.removeItem(at: voiceURL)
            try? FileManager.default.removeItem(at: backgroundURL)
            throw error
        }
        progress(1)
        return SeparationResult(voiceURL: voiceURL, backgroundURL: backgroundURL, method: method,
                                duration: Double(writtenFrames) / sampleRate)
    }
}
