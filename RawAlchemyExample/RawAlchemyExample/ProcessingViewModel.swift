import SwiftUI
import CoreGraphics

// MARK: - Processing state

enum ProcessingState {
    case idle
    case processing
    case success(preview: UIImage, result: RawToLogResult, elapsed: TimeInterval)
    case failure(Error)
}

// MARK: - ViewModel

/// Drives the processing pipeline on a background thread and publishes
/// state changes back to SwiftUI on the main actor.
@MainActor
final class ProcessingViewModel: ObservableObject {

    @Published private(set) var state: ProcessingState = .idle

    // MARK: Public API

    func process(url: URL, options: RawToLogOptions) async {
        state = .processing
        do {
            let (preview, result, elapsed) = try await Task.detached(priority: .userInitiated) {
                try Self.runPipeline(url: url, options: options)
            }.value
            state = .success(preview: preview, result: result, elapsed: elapsed)
        } catch {
            state = .failure(error)
        }
    }

    func reset() {
        state = .idle
    }

    // MARK: Background pipeline (runs off main actor)

    /// Performs the full RAW → Log pipeline on a background thread.
    /// Must be `static` so it is not actor-isolated and can run in a detached task.
    private static func runPipeline(
        url: URL,
        options: RawToLogOptions
    ) throws -> (UIImage, RawToLogResult, TimeInterval) {

        let start = CFAbsoluteTimeGetCurrent()

        // 1. Acquire the security-scoped resource granted by the file picker.
        //    This is required for URLs coming from UIDocumentPickerViewController
        //    / SwiftUI .fileImporter.
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        // 2. Copy to a stable temp path so the security scope doesn't need to
        //    stay open across suspension points inside CIRAWFilter / libraw.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // 3. Run the four-stage pipeline.
        let result = try RawToLogPipeline.process(rawPath: tempURL.path, options: options)

        // 4. Build an 8-bit preview from the log-encoded Float32 buffer.
        //    Values are already in [0, 1] after log encoding; images will look
        //    "flat" (correct for log material – needs a viewing LUT to display).
        let preview = try makePreview(result: result)

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        return (preview, result, elapsed)
    }

    // MARK: Preview image construction

    private static func makePreview(result: RawToLogResult) throws -> UIImage {
        let w = result.width
        let h = result.height
        let pixelCount = w * h

        // Scale Float32 [0, 1] → UInt8 [0, 255].
        var bytes = [UInt8](repeating: 0, count: pixelCount * 3)
        for i in 0 ..< pixelCount * 3 {
            bytes[i] = UInt8(max(0, min(255, Int(result.pixels[i] * 255.0))))
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bitsPerPixel: 24,
                  bytesPerRow: w * 3,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            throw NSError(
                domain: "com.rawalchemy.example",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to build 8-bit preview image."]
            )
        }

        return UIImage(cgImage: cgImage)
    }
}
