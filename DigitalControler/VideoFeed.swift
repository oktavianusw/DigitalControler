//
//  VideoFeed.swift
//  DigitalControler
//

import AVFoundation
import CoreMedia

/// Plays the Mac's H.264 screen stream: frames go straight to the system's hardware decoder via
/// `AVSampleBufferDisplayLayer`, shown the moment they arrive (no buffering, no clock).
final class VideoFeed {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?

    init() {
        layer.videoGravity = .resize // the surface sizes the layer to the picture's exact aspect
    }

    /// New SPS/PPS (sent before each keyframe). Returns the video's pixel size.
    func setFormat(_ parameterSets: [Data]) -> CGSize? {
        guard parameterSets.count >= 2, parameterSets.allSatisfy({ !$0.isEmpty }) else { return nil }
        var description: CMVideoFormatDescription?
        let status = withPointers(parameterSets) { pointers, sizes in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: parameterSets.count,
                                                                parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { return nil }
        format = description
        let d = CMVideoFormatDescriptionGetDimensions(description)
        return CGSize(width: Int(d.width), height: Int(d.height))
    }

    /// One frame, AVCC (4-byte length-prefixed NAL units), as the Mac's encoder produced it.
    func enqueue(_ frame: Data) {
        guard let format, !frame.isEmpty else { return }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frame.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: frame.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return }
        _ = frame.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: frame.count) }

        var sample: CMSampleBuffer?
        var size = frame.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() } // recover from a bad frame at the next keyframe
        renderer.enqueue(sample)
    }

    func reset() {
        format = nil
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    private func withPointers<R>(_ sets: [Data], _ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        let copies = sets.map { [UInt8]($0) }
        return copies.withUnsafeBufferPointers { body($0, copies.map(\.count)) }
    }
}

private extension Array where Element == [UInt8] {
    /// Stable pointers to every inner array at once (CoreMedia wants them all in one call).
    func withUnsafeBufferPointers<R>(_ body: ([UnsafePointer<UInt8>]) -> R) -> R {
        func go(_ i: Int, _ acc: [UnsafePointer<UInt8>]) -> R {
            guard i < count else { return body(acc) }
            return self[i].withUnsafeBufferPointer { go(i + 1, acc + [$0.baseAddress!]) }
        }
        return go(0, [])
    }
}
