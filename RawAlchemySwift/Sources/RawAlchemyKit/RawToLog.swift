/// RawToLog.swift
/// Top-level pipeline that converts a camera RAW file to a Log-encoded image.
///
/// This mirrors the `process_image()` function in core.py and ties together
/// all four Swift modules:
///   1. RAW decoding  (RAWDecoder.swift)
///   2. Exposure metering  (ExposureMetering.swift)
///   3. Color matrix + Log curve  (ColorSpace.swift + LogEncoding.swift)
///   4. Optional 3D LUT application  (LUTInterpolation.swift)
///
/// Usage:
///   ```swift
///   let result = try RawToLogPipeline.process(
///       rawPath:     "/path/to/IMG_0001.CR3",
///       logSpace:    .sLog3,
///       meteringMode: .matrix
///   )
///   // result.pixels contains the Log-encoded Float32 RGB data
///   ```

import Foundation

// MARK: - Pipeline options

/// Configuration for a single RAW → Log conversion.
public struct RawToLogOptions {
    /// Target log colour space.
    public var logSpace: LogSpace = .sLog3

    /// Exposure control.
    /// - `nil`:   automatic exposure metering (uses `meteringMode`).
    /// - `.some`: manual exposure offset in EV stops (can be negative).
    public var exposureEV: Float? = nil

    /// Metering mode used when `exposureEV` is `nil`.
    public var meteringMode: MeteringMode = .matrix

    /// Mid-grey target for automatic exposure (scene-linear, default 0.18).
    public var targetGray: Float = 0.18

    /// Optional URL to a .cube LUT file to apply after log encoding.
    public var lutURL: URL? = nil

    /// libraw highlight-recovery mode (0=clip, 2=blend, …).
    public var highlightMode: Int32 = 2

    /// libraw demosaic quality (11=AAHD recommended).
    public var demosaicQuality: Int32 = 11

    /// Luminance coefficients for the ProPhoto RGB working space.
    /// (Y-row of the standard ProPhoto→XYZ matrix.)
    public var lumaCoeffs: (Float, Float, Float) = prophoToYCoeffs

    public init() {}
}

// MARK: - Pipeline result

/// The output of a successful RAW → Log conversion.
public struct RawToLogResult {
    /// Width of the processed image in pixels.
    public let width: Int
    /// Height of the processed image in pixels.
    public let height: Int
    /// Flat interleaved Float32 pixel buffer (R G B … ), length = width × height × 3.
    public let pixels: [Float]
    /// Exposure gain that was applied (1.0 if manual with 0 EV).
    public let appliedGain: Float
    /// The log space that was encoded.
    public let logSpace: LogSpace
}

// MARK: - Pipeline errors

public enum RawToLogError: Error, LocalizedError {
    case lutLoadFailed(String)
    case rawDecodeFailed(Error)
    case unknownLogSpace(String)

    public var errorDescription: String? {
        switch self {
        case .lutLoadFailed(let msg):    return "Failed to load LUT: \(msg)"
        case .rawDecodeFailed(let err):  return "RAW decode failed: \(err.localizedDescription)"
        case .unknownLogSpace(let name): return "Unknown log space: \(name)"
        }
    }
}

// MARK: - Pipeline

public enum RawToLogPipeline {

    // MARK: Main entry point

    /// Converts a camera RAW file to a Log-encoded Float32 image buffer.
    ///
    /// - Parameters:
    ///   - rawPath: Absolute path to the RAW file.
    ///   - options: Processing options (log space, metering, LUT, …).
    /// - Returns: A `RawToLogResult` containing the processed pixel data.
    public static func process(rawPath: String,
                                options: RawToLogOptions = .init()) throws -> RawToLogResult {

        // ── Step 1: Decode RAW (libraw → ProPhoto RGB linear Float32) ────────
        let decoded: DecodedRAWImage
        do {
            decoded = try RAWDecoder.decode(path: rawPath,
                                            highlightMode: options.highlightMode,
                                            demosaicQuality: options.demosaicQuality)
        } catch {
            throw RawToLogError.rawDecodeFailed(error)
        }

        var pixels = decoded.pixels
        let width  = decoded.width
        let height = decoded.height

        let appliedGain: Float = try pixels.withUnsafeMutableBufferPointer { bp in
            guard let base = bp.baseAddress else { return 1.0 }

            // ── Step 2: Exposure ──────────────────────────────────────────
            let gain: Float
            if let ev = options.exposureEV {
                // Manual: 2^EV gain
                gain = pow(2.0, ev)
                applyGain(buffer: base, count: width * height * 3, gain: gain)
            } else {
                // Auto: metering
                gain = applyAutoExposure(
                    rgb: base,
                    width: width, height: height,
                    mode: options.meteringMode,
                    lumaCoeffs: options.lumaCoeffs,
                    targetGray: options.targetGray)
            }

            // ── Step 3: Gamut transform (ProPhoto linear → target linear) ─
            let matrix = LogSpaceMatrix.matrix(for: options.logSpace)
            applyMatrix3x3(buffer: base, pixelCount: width * height, matrix: matrix)

            // ── Step 4: Log encoding ──────────────────────────────────────
            encodeLogBuffer(buffer: base, pixelCount: width * height,
                            space: options.logSpace)

            // ── Step 5: Optional LUT ──────────────────────────────────────
            if let lutURL = options.lutURL {
                do {
                    let lut = try parseCubeLUT(contentsOf: lutURL)
                    applyLUT3D(buffer: base, pixelCount: width * height, lut: lut)
                } catch {
                    throw RawToLogError.lutLoadFailed(error.localizedDescription)
                }
            }

            return gain
        }

        return RawToLogResult(width: width,
                              height: height,
                              pixels: pixels,
                              appliedGain: appliedGain,
                              logSpace: options.logSpace)
    }

    // MARK: Convenience overloads

    /// Converts a RAW file to Log with a specific log space and metering mode.
    public static func process(rawPath: String,
                                logSpace: LogSpace,
                                meteringMode: MeteringMode = .matrix,
                                exposureEV: Float? = nil,
                                lutURL: URL? = nil) throws -> RawToLogResult {
        var opts = RawToLogOptions()
        opts.logSpace     = logSpace
        opts.meteringMode = meteringMode
        opts.exposureEV   = exposureEV
        opts.lutURL       = lutURL
        return try process(rawPath: rawPath, options: opts)
    }
}

// MARK: - EXR / TIFF helpers (stub)

extension RawToLogResult {
    /// Returns the pixel data as a 16-bit half-float (little-endian) array
    /// suitable for writing to an OpenEXR file.
    /// Values are expected to be in [0, 1] after Log encoding.
    public func toFloat16Array() -> [UInt16] {
        pixels.map { float32ToHalf($0) }
    }
}

/// Converts a Float32 to an IEEE 754 half-precision float (binary16).
private func float32ToHalf(_ v: Float) -> UInt16 {
    // Use bit manipulation to convert Float32 → Float16
    let bits = v.bitPattern
    let sign: UInt16 = UInt16((bits >> 31) & 0x1) << 15
    let exp32 = Int32((bits >> 23) & 0xFF) - 127
    let mant  = bits & 0x7FFFFF

    if exp32 >= 16 {
        // Infinity or overflow
        return sign | 0x7C00
    } else if exp32 < -24 {
        // Zero / underflow
        return sign
    } else if exp32 < -14 {
        // Denormalised half
        let shift = UInt32(-14 - exp32)
        return sign | UInt16((mant | 0x800000) >> (shift + 13))
    } else {
        let exp16 = UInt16(exp32 + 15) & 0x1F
        return sign | (exp16 << 10) | UInt16(mant >> 13)
    }
}
