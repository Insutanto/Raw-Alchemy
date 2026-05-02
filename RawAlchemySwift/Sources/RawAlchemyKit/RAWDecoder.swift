/// RAWDecoder.swift
/// Decodes camera RAW files into a linear-light ProPhoto RGB Float32 image buffer.
///
/// Two platform-specific backends are provided:
///   • macOS  – wraps the libraw C library, mirroring rawpy.postprocess() from core.py
///              (gamma=(1,1), camera WB, ProPhoto output, AAHD demosaic, highlight blend)
///   • iOS    – uses Apple's CoreImage CIRAWFilter (available iOS 15+), rendering
///              to a linear ProPhoto (ROMM RGB Linear) float buffer via CIContext.
///
/// The public API (`RAWDecoder.decode(path:)`, `DecodedRAWImage`, `RAWDecoderError`)
/// is identical on both platforms.

import Foundation

// MARK: - Shared types (all platforms)

/// Errors thrown by `RAWDecoder.decode(path:)`.
public enum RAWDecoderError: Error, LocalizedError {
    case openFailed(Int32)
    case unpackFailed(Int32)
    case processFailed(Int32)
    case makeImageFailed(Int32)
    case unexpectedImageType

    public var errorDescription: String? {
        switch self {
        case .openFailed(let c):
            return "RAW open failed (code \(c))"
        case .unpackFailed(let c):
            return "RAW unpack failed (code \(c))"
        case .processFailed(let c):
            return "RAW process failed (code \(c))"
        case .makeImageFailed(let c):
            return "RAW make-image failed (code \(c))"
        case .unexpectedImageType:
            return "Unexpected RAW image format (expected 3-channel linear output)"
        }
    }
}

/// A decoded RAW image in linear-light ProPhoto RGB.
/// Pixel data is stored as a flat `[Float]` array in interleaved R G B order,
/// normalised to [0, 1] (highlights may exceed 1.0 in HDR-capable pipelines).
public struct DecodedRAWImage {
    /// Image width in pixels.
    public let width: Int
    /// Image height in pixels.
    public let height: Int
    /// Interleaved Float32 RGB pixel data, length = width × height × 3.
    public var pixels: [Float]

    /// Total number of pixels.
    public var pixelCount: Int { width * height }
}

// MARK: - RAWDecoder (macOS + Linux – libraw backend)

#if os(macOS) || os(Linux)
import CLibRaw

/// Decodes a camera RAW file to a linear-light ProPhoto RGB Float32 buffer.
/// On macOS and Linux this wraps the libraw C library.  Requires `libraw` to be
/// installed (`brew install libraw` on macOS or `apt install libraw-dev` on Linux).
public final class RAWDecoder {

    /// Decode the RAW file at `path` and return a `DecodedRAWImage`.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the RAW file.
    ///   - highlightMode: libraw highlight recovery mode (0=clip, 2=blend, …).
    ///   - demosaicQuality: libraw user_qual parameter (11=AAHD recommended).
    /// - Returns: A `DecodedRAWImage` with pixel values in [0, 1].
    public static func decode(path: String,
                               highlightMode: Int32 = 2,
                               demosaicQuality: Int32 = 11) throws -> DecodedRAWImage {

        guard let data = libraw_init(0) else {
            throw RAWDecoderError.openFailed(LIBRAW_OUT_OF_ORDER_CALL.rawValue)
        }
        defer { libraw_close(data) }

        let openRet = path.withCString { libraw_open_file(data, $0) }
        guard openRet == LIBRAW_SUCCESS.rawValue else {
            throw RAWDecoderError.openFailed(openRet)
        }

        let unpackRet = libraw_unpack(data)
        guard unpackRet == LIBRAW_SUCCESS.rawValue else {
            throw RAWDecoderError.unpackFailed(unpackRet)
        }

        configureOutputParams(data, highlightMode: highlightMode,
                              demosaicQuality: demosaicQuality)

        let procRet = libraw_dcraw_process(data)
        guard procRet == LIBRAW_SUCCESS.rawValue else {
            throw RAWDecoderError.processFailed(procRet)
        }

        var errc: Int32 = 0
        guard let img = libraw_dcraw_make_mem_image(data, &errc) else {
            throw RAWDecoderError.makeImageFailed(errc)
        }
        defer { libraw_dcraw_clear_mem(img) }

        guard img.pointee.type == LIBRAW_IMAGE_BITMAP,
              img.pointee.bits == 16,
              img.pointee.colors == 3 else {
            throw RAWDecoderError.unexpectedImageType
        }

        let width      = Int(img.pointee.width)
        let height     = Int(img.pointee.height)
        let pixelCount = width * height

        // `img.pointee.data` is the first element of a C flexible array member.
        // Taking the address and rebinding as UInt16 gives the full pixel array.
        let floatPixels: [Float] = withUnsafePointer(to: &img.pointee.data) { rawPtr in
            rawPtr.withMemoryRebound(to: UInt16.self, capacity: pixelCount * 3) { ptr in
                var buf = [Float](repeating: 0, count: pixelCount * 3)
                for i in 0 ..< pixelCount * 3 {
                    buf[i] = Float(ptr[i]) / 65535.0
                }
                return buf
            }
        }

        return DecodedRAWImage(width: width, height: height, pixels: floatPixels)
    }

    private static func configureOutputParams(_ data: UnsafeMutablePointer<libraw_data_t>,
                                              highlightMode: Int32,
                                              demosaicQuality: Int32) {
        data.pointee.params.output_color   = 6    // ProPhoto RGB
        data.pointee.params.gamm.0         = 1.0  // linear gamma
        data.pointee.params.gamm.1         = 1.0
        data.pointee.params.use_camera_wb  = 1
        data.pointee.params.use_auto_wb    = 0
        data.pointee.params.no_auto_bright = 1
        data.pointee.params.bright         = 1.0
        data.pointee.params.output_bps     = 16
        data.pointee.params.highlight      = highlightMode
        data.pointee.params.user_qual      = demosaicQuality
        data.pointee.params.user_flip      = -1   // use EXIF orientation
    }
}

// MARK: - RAWDecoder (iOS / iPadOS – CoreImage CIRAWFilter backend)

#else  // !os(macOS) && !os(Linux): iOS, iPadOS, visionOS, tvOS
import CoreImage

/// Decodes a camera RAW file to a linear-light ProPhoto RGB Float32 buffer.
/// On iOS this uses `CIRAWFilter` (CoreImage) to decode the RAW and renders
/// the result into a ROMM-RGB-Linear (ProPhoto linear) float buffer via `CIContext`.
///
/// - `CIRAWFilter` requires iOS 15+.  This package targets iOS 16+.
/// - `CGColorSpace.rommrgbLinear` (ProPhoto linear) is available on iOS 12+.
/// - The `highlightMode` and `demosaicQuality` parameters are not used on iOS;
///   they are accepted to keep the cross-platform API identical.
public final class RAWDecoder {

    /// Decode the RAW file at `path` and return a `DecodedRAWImage`.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the RAW file (can be in the app sandbox or
    ///           a security-scoped URL after user grants file access).
    ///   - highlightMode: *Ignored on iOS.* Accepted for API compatibility.
    ///   - demosaicQuality: *Ignored on iOS.* Accepted for API compatibility.
    /// - Returns: A `DecodedRAWImage` with linear-light ProPhoto RGB values.
    public static func decode(path: String,
                               highlightMode: Int32 = 2,
                               demosaicQuality: Int32 = 11) throws -> DecodedRAWImage {

        let url = URL(fileURLWithPath: path)

        // 1. Create the CIRAWFilter from the file URL.
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw RAWDecoderError.openFailed(-1)
        }

        // 2. Configure for a neutral, unmodified decode that matches the
        //    rawpy settings used on macOS:
        //    - No exposure adjustment (equivalent to no_auto_bright + bright=1.0)
        //    - No HDR boost (equivalent to highlight_mode=2 blend ceiling)
        //    - No noise reduction (preserve raw data fidelity)
        //    CIRAWFilter uses the embedded camera white balance by default,
        //    which is equivalent to use_camera_wb=1.
        filter.boostAmount          = 0  // disable HDR dynamic range boost
        filter.exposureAdjust       = 0  // no auto-brightness adjustment (EV stops)
        filter.noiseReductionAmount = 0  // disable noise reduction

        // 3. Obtain the output CIImage.
        guard var ciImage = filter.outputImage else {
            throw RAWDecoderError.processFailed(-1)
        }

        // 4. Normalise the image origin to (0, 0) so that render bounds are clean.
        if ciImage.extent.origin != .zero {
            let tx = -ciImage.extent.origin.x
            let ty = -ciImage.extent.origin.y
            ciImage = ciImage.transformed(by: CGAffineTransform(translationX: tx, y: ty))
        }

        let extent = ciImage.extent
        let width  = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else {
            throw RAWDecoderError.unexpectedImageType
        }

        // 5. Build a CIContext that works in linear ProPhoto (ROMM RGB Linear)
        //    at full float32 precision.  `workingColorSpace` controls internal
        //    precision; `outputColorSpace` is overridden per-render call below.
        guard let prophotoLinear = CGColorSpace(name: CGColorSpace.rommrgbLinear) else {
            throw RAWDecoderError.unexpectedImageType
        }
        let context = CIContext(options: [
            .workingColorSpace: prophotoLinear,
            .workingFormat: CIFormat.RGBAf,       // 128-bit RGBA float internally
        ])

        // 6. Render into an RGBA Float32 CPU buffer.
        let pixelCount = width * height
        let rowBytes   = width * 4 * MemoryLayout<Float>.size
        var rgbaPixels = [Float](repeating: 0, count: pixelCount * 4)

        rgbaPixels.withUnsafeMutableBytes { ptr in
            context.render(ciImage,
                           toBitmap: ptr.baseAddress!,
                           rowBytes: rowBytes,
                           bounds: extent,
                           format: .RGBAf,
                           colorSpace: prophotoLinear)  // output in ProPhoto linear
        }

        // 7. Convert RGBA Float32 → interleaved RGB Float32 (drop alpha channel).
        var rgb = [Float](repeating: 0, count: pixelCount * 3)
        for i in 0 ..< pixelCount {
            rgb[i * 3 + 0] = rgbaPixels[i * 4 + 0]
            rgb[i * 3 + 1] = rgbaPixels[i * 4 + 1]
            rgb[i * 3 + 2] = rgbaPixels[i * 4 + 2]
        }

        return DecodedRAWImage(width: width, height: height, pixels: rgb)
    }
}

#endif  // os(macOS) / else
