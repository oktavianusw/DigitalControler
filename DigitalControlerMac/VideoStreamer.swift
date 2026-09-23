//
//  VideoStreamer.swift
//  DigitalControlerMac
//

import CoreMedia
import ScreenCaptureKit
import VideoToolbox

/// Hands bytes to the connection; the callback says whether they went out.
typealias Transmit = @Sendable (Data, @escaping @Sendable (Bool) -> Void) -> Void

/// Streams one display as low-latency H.264: ScreenCaptureKit delivers a frame whenever the screen
/// changes (up to 30 fps), the Mac's hardware encoder compresses it, and it's sent straight away.
/// Runs off the main thread: frames arrive on a capture queue and leave from the encoder's thread.
nonisolated final class VideoStreamer: NSObject, SCStreamOutput, @unchecked Sendable {
    private let index: UInt8
    private let transmit: Transmit
    private let stream: SCStream
    private let session: VTCompressionSession
    private let captureQueue = DispatchQueue(label: "VideoStreamer.capture")
    private let lock = NSLock()
    private var inFlight = 0 // frames encoding or on the wire

    /// More than this many frames not yet sent means the network is behind: skip new frames
    /// (before encoding, so the video stays decodable) instead of queueing them up.
    private static let maxInFlight = 2

    init(filter: SCContentFilter, width: Int, height: Int, index: Int, transmit: @escaping Transmit) throws {
        self.index = UInt8(index)
        self.transmit = transmit
        let (w, h) = (width & ~1, height & ~1) // H.264 wants even dimensions

        var session: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false, // no B-frames: each frame decodes as it lands
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            // ~3 bits per pixel per second: about 5 Mbit/s at 1600×1038, scaling with the size the iPhone asked for.
            kVTCompressionPropertyKey_AverageBitRate: max(1_000_000, w * h * 3),
            kVTCompressionPropertyKey_ExpectedFrameRate: 30,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2, // a fresh full picture every 2 s at most
        ]
        for (key, value) in properties { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session

        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // what the encoder eats, no conversion
        config.showsCursor = true
        config.queueDepth = 4
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
    }

    func start() async throws {
        try await stream.startCapture()
    }

    func stop() {
        stream.stopCapture { _ in }
        VTCompressionSessionInvalidate(session)
    }

    // MARK: Capture → encode

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        // SCStream also sends "nothing changed" frames without pixels; skip those.
        guard type == .screen, sample.isValid, let pixels = sample.imageBuffer, Self.isComplete(sample) else { return }
        guard reserveSlot() else { return }
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: sample.presentationTimeStamp,
                                                     duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, encoded in
            self?.encoded(status == noErr ? encoded : nil)
        }
        if status != noErr { releaseSlot() }
    }

    private static func isComplete(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }

    // MARK: Encode → network

    private func encoded(_ sample: CMSampleBuffer?) {
        guard let sample, let block = sample.dataBuffer, let frame = try? block.dataBytes() else { return releaseSlot() }
        if Self.isKeyframe(sample), let format = sample.formatDescription {
            // Parameter sets ride along with every keyframe, so a viewer can start from any keyframe.
            transmit(Downstream.videoFormat.packet(Data([index]) + ParameterSets.encode(Self.parameterSets(format)))) { _ in }
        }
        transmit(Downstream.videoFrame.packet(Data([index]) + frame)) { [weak self] _ in self?.releaseSlot() }
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]] else { return true }
        return !(attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private static func parameterSets(_ format: CMFormatDescription) -> [Data] {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        return (0..<count).compactMap { i in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                               parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            return pointer.map { Data(bytes: $0, count: size) }
        }
    }

    // MARK: Backpressure

    private func reserveSlot() -> Bool {
        lock.withLock {
            guard inFlight < Self.maxInFlight else { return false }
            inFlight += 1
            return true
        }
    }

    private func releaseSlot() {
        lock.withLock { inFlight -= 1 }
    }
}
