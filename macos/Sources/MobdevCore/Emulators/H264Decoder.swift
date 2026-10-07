import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Decodes an H.264 stream in Annex B form (as scrcpy sends it) with VideoToolbox and keeps the
/// newest picture only. `decode` is called from one thread, the stream's reader; `image` and
/// `size` from any.
final class H264Decoder: @unchecked Sendable {
    // Only touched by the reader thread.
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    /// After a failure or new parameter sets, pictures wait for the next key frame.
    private var waitingForKeyFrame = true

    /// The newest decoded picture, numbered, and the image made from it on demand.
    private let newest = Locked<(buffer: CVPixelBuffer, number: Int)?>(nil)
    private let made = Locked<(number: Int, image: CGImage)?>(nil)
    private let shown = Locked<(width: Int, height: Int)?>(nil)

    /// Pictures decoded so far.
    var frameCount: Int { newest.get()?.number ?? 0 }

    /// The picture size the parameter sets describe, cropping applied: the video's pixels, which
    /// touches are given in. Nil before the first parameter sets.
    var size: (width: Int, height: Int)? { shown.get() }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// One packet: parameter sets (`config`) or a picture. False when the decoder needs a key frame
    /// it cannot wait 10 seconds for, e.g. after VideoToolbox lost its session: ask the encoder to
    /// start over.
    @discardableResult
    func decode(_ packet: Data, config: Bool, keyFrame: Bool) -> Bool {
        var pictures: [Data] = []
        var newParameters = false
        for unit in ScrcpyProtocol.nalUnits(packet) {
            switch unit.first.map({ $0 & 0x1f }) {
            case 7: if unit != sps { sps = unit; newParameters = true }
            case 8: if unit != pps { pps = unit; newParameters = true }
            case 9, nil: continue  // Access unit delimiters carry nothing to decode.
            default: pictures.append(unit)
            }
        }
        if newParameters || format == nil, let sps, let pps {
            guard makeFormat(sps: sps, pps: pps) else { return false }
        }
        guard !pictures.isEmpty, format != nil else { return true }
        if waitingForKeyFrame {
            guard keyFrame else { return true }
            waitingForKeyFrame = false
        }
        guard let sample = Self.sample(pictures, format: format) else { return true }
        if session == nil, !makeSession() { return false }
        guard let session else { return false }
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image, let self else { return }
            self.newest.withLock { $0 = (image, ($0?.number ?? 0) + 1) }
        }
        guard status == noErr else {
            Log.error("VideoToolbox could not decode a frame (\(status)); waiting for a key frame")
            if status == kVTInvalidSessionErr {
                VTDecompressionSessionInvalidate(session)
                self.session = nil
            }
            waitingForKeyFrame = true
            return false
        }
        return true
    }

    /// The newest picture as an image, made once per picture.
    func image() -> CGImage? {
        guard let newest = newest.get() else { return nil }
        if let made = made.get(), made.number == newest.number { return made.image }
        guard let image = Self.image(newest.buffer, size: size) else { return nil }
        made.set((newest.number, image))
        return image
    }

    private func makeFormat(sps: Data, pps: Data) -> Bool {
        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [
                    spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                ]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else {
            Log.error("scrcpy sent parameter sets VideoToolbox does not take (\(status))")
            return false
        }
        if let session, !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: description) {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        format = description
        // The coded size is a multiple of 16; the clean aperture is what the encoder was given.
        let presented = CMVideoFormatDescriptionGetPresentationDimensions(
            description, usePixelAspectRatio: false, useCleanAperture: true)
        shown.set((Int(presented.width.rounded()), Int(presented.height.rounded())))
        waitingForKeyFrame = true
        return true
    }

    private func makeSession() -> Bool {
        guard let format else { return false }
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else {
            Log.error("VideoToolbox could not start an H.264 decoder (\(status))")
            return false
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        return true
    }

    /// NAL units with 4-byte lengths in place of start codes, as one sample.
    private static func sample(_ units: [Data], format: CMVideoFormatDescription?) -> CMSampleBuffer? {
        var bytes = Data(capacity: units.reduce(0) { $0 + $1.count + 4 })
        for unit in units {
            let length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: length) { bytes.append(contentsOf: $0) }
            bytes.append(unit)
        }
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block,
            bytes.withUnsafeBytes({
                CMBlockBufferReplaceDataBytes(
                    with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
            }) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        var sizes = [bytes.count]
        guard
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
                sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }

    /// A copy of a BGRA picture, so VideoToolbox can reuse its buffer, cropped to `size`.
    static func image(_ buffer: CVPixelBuffer, size: (width: Int, height: Int)?) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = min(size?.width ?? .max, CVPixelBufferGetWidth(buffer))
        let height = min(size?.height ?? .max, CVPixelBufferGetHeight(buffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0,
            let provider = CGDataProvider(data: Data(bytes: base, count: bytesPerRow * height) as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
