import Foundation
import AVFoundation
import VideoToolbox

/// Production implementation of ExportSessionFactory that wraps AVAssetExportSession
/// for standard quality, and AVAssetReader/Writer for high/max quality tiers.
struct RealExportSessionFactory: ExportSessionFactory {
    func export(
        source: URL,
        destination: URL,
        fileType: AVFileType,
        quality: Quality
    ) async throws {
        switch quality {
        case .standard:
            try await exportWithSession(source: source, destination: destination, fileType: fileType)
        case .high, .veryHigh, .max:
            try await exportWithWriter(
                source: source,
                destination: destination,
                fileType: fileType,
                compressionQuality: quality.compressionQuality!
            )
        }
    }

    // MARK: - AVAssetExportSession path (standard quality)

    private func exportWithSession(
        source: URL,
        destination: URL,
        fileType: AVFileType
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHEVCHighestQuality
        ) else {
            throw EncodingError.exportSessionCreation
        }
        session.outputURL = destination
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = false

        await session.export()

        guard session.status == .completed else {
            throw EncodingError.exportFailed(session.error)
        }
    }

    // MARK: - AVAssetReader/Writer path (high/very-high/max quality)

    private func exportWithWriter(
        source: URL,
        destination: URL,
        fileType: AVFileType,
        compressionQuality: Double
    ) async throws {
        let asset = AVURLAsset(url: source)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)

        // Each reader output paired with the writer input it feeds. A track that
        // cannot be added fails the encode instead of being skipped.
        var pairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        func addPair(_ output: AVAssetReaderTrackOutput, _ input: AVAssetWriterInput, _ name: String) throws {
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw EncodingError.exportFailed(TrackError(message: "cannot write the \(name) track to \(fileType.rawValue)"))
            }
            reader.add(output)
            writer.add(input)
            pairs.append((output, input))
        }

        // Video track
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        if let videoTrack = videoTracks.first {
            let readerOutput = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ]
            )
            readerOutput.alwaysCopiesSampleData = false

            let naturalSize = try await videoTrack.load(.naturalSize)
            let writerInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: Int(naturalSize.width),
                    AVVideoHeightKey: Int(naturalSize.height),
                    AVVideoCompressionPropertiesKey: [
                        AVVideoQualityKey: compressionQuality
                    ]
                ]
            )
            writerInput.expectsMediaDataInRealTime = false

            let transform = try await videoTrack.load(.preferredTransform)
            writerInput.transform = transform

            try addPair(readerOutput, writerInput, "video")
        }

        // Audio track (passthrough — nil outputSettings = copy).
        // A passthrough input needs the source format hint: without it the writer
        // refuses some formats, such as camera PCM audio in an .mp4.
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let audioTrack = audioTracks.first {
            let audioReaderOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            audioReaderOutput.alwaysCopiesSampleData = false

            let audioWriterInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: try await audioTrack.load(.formatDescriptions).first
            )
            audioWriterInput.expectsMediaDataInRealTime = false

            try addPair(audioReaderOutput, audioWriterInput, "audio")
        }

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Process all inputs concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (i, pair) in pairs.enumerated() {
                let writerInput = pair.input
                let readerOutput = pair.output
                group.addTask {
                    await withCheckedContinuation { continuation in
                        writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "vcompress.writer.\(i)")) {
                            while writerInput.isReadyForMoreMediaData {
                                if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                                    writerInput.append(sampleBuffer)
                                } else {
                                    writerInput.markAsFinished()
                                    continuation.resume()
                                    return
                                }
                            }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        await writer.finishWriting()

        if reader.status == .failed {
            throw EncodingError.exportFailed(reader.error)
        }
        if writer.status == .failed {
            throw EncodingError.exportFailed(writer.error)
        }
    }
}

private struct TrackError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
