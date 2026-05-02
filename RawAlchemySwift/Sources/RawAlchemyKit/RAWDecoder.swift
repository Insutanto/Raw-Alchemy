/// RAWDecoder.swift
/// Swift wrapper around the libraw C library for decoding camera RAW files
/// into a linear-light ProPhoto RGB Float32 image buffer.
///
/// Mirrors the rawpy.postprocess() call in core.py:
///   gamma=(1,1), no_auto_bright=True, use_camera_wb=True,
///   output_bps=16, output_color=ProPhoto, highlight_mode=2 (blend),
///   demosaic=AAHD.
///
/// Requires: libraw ≥ 0.20  (brew install libraw  |  apt install libraw-dev)

import Foundation
import CLibRaw

// MARK: - Errors

public enum RAWDecoderError: Error, LocalizedError {
    case openFailed(Int32)
    case unpackFailed(Int32)
    case processFailed(Int32)
    case makeImageFailed(Int32)
    case unexpectedImageType

    public var errorDescription: String? {
        switch self {
        case .openFailed(let c):    return "libraw_open_file failed: \(libraw_strerror(c) ?? "unknown")"
        case .unpackFailed(let c):  return "libraw_unpack failed:     \(libraw_strerror(c) ?? "unknown")"
        case .processFailed(let c): return "libraw_process failed:    \(libraw_strerror(c) ?? "unknown")"
        case .makeImageFailed(let c): return "libraw_make_mem_image failed: \(libraw_strerror(c) ?? "unknown")"
        case .unexpectedImageType:  return "Unexpected libraw image type (expected 3-channel 16-bit)"
        }
    }
}

// MARK: - Decoded image

/// A decoded RAW image in linear-light ProPhoto RGB.
/// Pixel data is stored as a flat `[Float]` array in interleaved R G B order,
/// values normalised to [0, 1].
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

// MARK: - RAWDecoder

/// Decodes a camera RAW file to a linear-light ProPhoto RGB Float32 buffer.
public final class RAWDecoder {

    /// Decode the RAW file at `path` and return a `DecodedRAWImage`.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the RAW file.
    ///   - highlightMode: libraw highlight recovery mode.
    ///                    0=clip, 1=unclip, 2=blend (default), 3-9=rebuild.
    ///   - demosaicQuality: libraw user_qual parameter.
    ///                      3=AHD, 11=AAHD (default), 12=DCB, etc.
    /// - Returns: A `DecodedRAWImage` with pixel values in [0, 1].
    public static func decode(path: String,
                               highlightMode: Int32 = 2,
                               demosaicQuality: Int32 = 11) throws -> DecodedRAWImage {

        // 1. Allocate a libraw instance
        guard let data = libraw_init(0) else {
            throw RAWDecoderError.openFailed(LIBRAW_OUT_OF_ORDER_CALL)
        }
        defer { libraw_close(data) }

        // 2. Open the RAW file
        let openRet = path.withCString { libraw_open_file(data, $0) }
        guard openRet == LIBRAW_SUCCESS.rawValue else {
            throw RAWDecoderError.openFailed(openRet)
        }

        // 3. Unpack RAW data
        let unpackRet = libraw_unpack(data)
        guard unpackRet == LIBRAW_SUCCESS.rawValue else {
            throw RAWDecoderError.unpackFailed(unpackRet)
        }

        // 4. Configure output parameters (mirrors rawpy.postprocess arguments)
        configureOutputParams(data, highlightMode: highlightMode,
                              demosaicQuality: demosaicQuality)

        // 5. Process (demosaic + colour pipeline)
        let procRet = libraw_dcraw_process(data)
        guard procRet == LIBRAW_SUCCESS.rawValue else {
            throw RAWDecoderError.processFailed(procRet)
        }

        // 6. Retrieve the result image from libraw's internal buffer
        var errc: Int32 = 0
        guard let img = libraw_dcraw_make_mem_image(data, &errc) else {
            throw RAWDecoderError.makeImageFailed(errc)
        }
        defer { libraw_dcraw_clear_mem(img) }

        // Validate: we expect a 3-channel 16-bit image
        guard img.pointee.type == LIBRAW_IMAGE_BITMAP,
              img.pointee.bits == 16,
              img.pointee.colors == 3 else {
            throw RAWDecoderError.unexpectedImageType
        }

        let width  = Int(img.pointee.width)
        let height = Int(img.pointee.height)
        let pixelCount = width * height

        // 7. Convert uint16 [0, 65535] → Float32 [0, 1]
        //    `img.pointee.data` is the first element of a C flexible array member
        //    (`unsigned char data[1]`).  Taking the address of that field and
        //    rebinding the memory as UInt16 gives us the full pixel array, since
        //    libraw allocates the complete data contiguously after the header.
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

    // MARK: Private helpers

    private static func configureOutputParams(_ data: UnsafeMutablePointer<libraw_data_t>,
                                              highlightMode: Int32,
                                              demosaicQuality: Int32) {
        // Output colour space: 6 = ProPhoto RGB
        data.pointee.params.output_color = 6

        // Linear gamma (no tone curve)
        data.pointee.params.gamm.0 = 1.0   // gamma power
        data.pointee.params.gamm.1 = 1.0   // toe slope

        // White balance
        data.pointee.params.use_camera_wb  = 1
        data.pointee.params.use_auto_wb    = 0

        // Disable auto-brightness
        data.pointee.params.no_auto_bright = 1
        data.pointee.params.bright         = 1.0

        // 16-bit output
        data.pointee.params.output_bps = 16

        // Highlight recovery
        data.pointee.params.highlight = highlightMode

        // Demosaic algorithm (11 = AAHD)
        data.pointee.params.user_qual = demosaicQuality

        // No flip (use EXIF orientation)
        data.pointee.params.user_flip = -1
    }
}
