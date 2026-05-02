/// ExposureMetering.swift
/// Swift port of metering.py – implements five metering strategies as a
/// protocol-based hierarchy, exactly matching the Python originals.
///
/// All strategies operate on a *downsampled* view of the image for speed
/// (identical to the Python `get_subsampled_view` approach) and return a
/// linear gain value in scene-linear space.

import Foundation

// MARK: - Metering gain limits
// These match the Python originals in metering.py.
// Average: gain ≥ 1 prevents under-exposure in already-bright scenes;
//          50× cap guards against noise amplification in very dark frames.
private let averageGainMin: Float  =  1.0
private let averageGainMax: Float  = 50.0

// All other strategies permit ±10 stops of headroom (0.1 – 100×).
private let defaultGainMin: Float  =  0.1
private let defaultGainMax: Float  = 100.0

// Highlight-safety threshold: peak code value (post-gain) that is
// considered "safe" before clipping in a linear-light pipeline.
// A value of 6.0× scene-linear (≈ 2.6 stops above 18% grey) provides
// headroom for specular highlights while preventing gross clipping.
private let maxAllowedPeak: Float  =   6.0

// MARK: - Luminance helpers

/// Returns the luminance coefficient vector [Lr, Lg, Lb] for a given color
/// space.  For the ProPhoto RGB working space these are the Y-row of the
/// standard RGB→XYZ matrix:  [0.2880, 0.7119, 0.0001].
///
/// The caller may supply custom coefficients; the default assumes ProPhoto RGB.
public let prophoToYCoeffs: (Float, Float, Float) = (0.2880402, 0.7118741, 0.0000857)

/// Compute per-pixel luminance Y = Lr*R + Lg*G + Lb*B from a flat RGB buffer.
/// Returns a newly allocated `[Float]` of length `pixelCount`.
func luminanceBuffer(rgb: UnsafePointer<Float>,
                     pixelCount: Int,
                     coeffs: (Float, Float, Float) = prophoToYCoeffs) -> [Float] {
    var lum = [Float](repeating: 0, count: pixelCount)
    let (cr, cg, cb) = coeffs
    for i in 0 ..< pixelCount {
        lum[i] = rgb[i*3]*cr + rgb[i*3+1]*cg + rgb[i*3+2]*cb
    }
    return lum
}

/// Returns a subsampled view of an RGB Float32 image as a flat `[Float]` array.
/// - Parameters:
///   - src: pointer to the source pixel data (H × W × 3)
///   - width/height: image dimensions
///   - targetSize: the approximate longest dimension of the sample
/// - Returns: a tuple of (buffer, sampledWidth, sampledHeight)
func subsampleRGB(src: UnsafePointer<Float>,
                  width: Int, height: Int,
                  targetSize: Int = 1024) -> (buffer: [Float], w: Int, h: Int) {
    let step = max(1, max(width, height) / targetSize)
    let sw = (width  + step - 1) / step
    let sh = (height + step - 1) / step
    var out = [Float](repeating: 0, count: sw * sh * 3)
    for sy in 0 ..< sh {
        let iy = sy * step
        for sx in 0 ..< sw {
            let ix = sx * step
            let srcIdx  = (iy * width + ix) * 3
            let dstIdx  = (sy * sw + sx) * 3
            out[dstIdx + 0] = src[srcIdx + 0]
            out[dstIdx + 1] = src[srcIdx + 1]
            out[dstIdx + 2] = src[srcIdx + 2]
        }
    }
    return (out, sw, sh)
}

/// Geometric-mean luminance (log-average) of a luminance array.
func logAverageLuminance(_ lum: [Float]) -> Float {
    var sum: Double = 0
    for v in lum { sum += Double(Foundation.log(max(v, 1e-10) + 1e-6)) }
    return Float(Foundation.exp(sum / Double(lum.count)))
}

/// Weighted average of an array using per-element weights.
func weightedMean(_ values: [Float], weights: [Float]) -> Float {
    var sumV: Float = 0; var sumW: Float = 0
    for i in 0 ..< values.count {
        sumV += values[i] * weights[i]
        sumW += weights[i]
    }
    return sumW > 0 ? sumV / sumW : 0
}

/// Returns the p-th percentile of `arr` (0 ≤ p ≤ 100).
func percentile(_ arr: [Float], p: Float) -> Float {
    guard !arr.isEmpty else { return 0 }
    let sorted = arr.sorted()
    let idx = (p / 100.0) * Float(sorted.count - 1)
    let lo  = Int(idx); let hi = min(lo + 1, sorted.count - 1)
    let frac = idx - Float(lo)
    return sorted[lo] * (1 - frac) + sorted[hi] * frac
}

// MARK: - MeteringStrategy protocol

/// A metering strategy accepts a linear Float32 RGB image buffer and returns
/// the suggested scene-linear gain to apply.
public protocol MeteringStrategy {
    /// - Parameters:
    ///   - rgb: Pointer to the linearised RGB Float32 pixel data (H × W × 3).
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - lumaCoeffs: Luminance weighting for the source color space.
    ///   - targetGray: Mid-gray target in scene-linear (default 0.18).
    /// - Returns: A linear gain multiplier ≥ 0.
    func calculateGain(rgb: UnsafePointer<Float>,
                        width: Int, height: Int,
                        lumaCoeffs: (Float, Float, Float),
                        targetGray: Float) -> Float
}

// MARK: - Average metering (geometric mean / log-average)

/// Mirrors `AverageMeteringStrategy` in metering.py.
public struct AverageMeteringStrategy: MeteringStrategy {
    public init() {}

    public func calculateGain(rgb: UnsafePointer<Float>,
                               width: Int, height: Int,
                               lumaCoeffs: (Float, Float, Float) = prophoToYCoeffs,
                               targetGray: Float = 0.18) -> Float {
        let (sample, sw, sh) = subsampleRGB(src: rgb, width: width, height: height)
        let lum = luminanceBuffer(rgb: sample, pixelCount: sw * sh, coeffs: lumaCoeffs)
        let avgLum = logAverageLuminance(lum)
        let gain = avgLum < 0.0001 ? 1.0 : targetGray / avgLum
        return min(max(gain, averageGainMin), averageGainMax)
    }
}

// MARK: - Center-weighted metering

/// Mirrors `CenterWeightedMeteringStrategy` in metering.py.
public struct CenterWeightedMeteringStrategy: MeteringStrategy {
    public init() {}

    public func calculateGain(rgb: UnsafePointer<Float>,
                               width: Int, height: Int,
                               lumaCoeffs: (Float, Float, Float) = prophoToYCoeffs,
                               targetGray: Float = 0.18) -> Float {
        let (sample, sw, sh) = subsampleRGB(src: rgb, width: width, height: height)
        let lum = luminanceBuffer(rgb: sample, pixelCount: sw * sh, coeffs: lumaCoeffs)

        // Gaussian weights centred on the image
        let cy = Float(sh) / 2.0; let cx = Float(sw) / 2.0
        let sigma = min(Float(sh), Float(sw)) / 2.0
        var weights = [Float](repeating: 0, count: sw * sh)
        for y in 0 ..< sh {
            for x in 0 ..< sw {
                let dy = Float(y) - cy; let dx = Float(x) - cx
                weights[y * sw + x] = Foundation.exp(-(dx*dx + dy*dy) / (2 * sigma * sigma))
            }
        }

        let wLum = weightedMean(lum, weights: weights)
        let gain = wLum < 1e-6 ? 1.0 : targetGray / wLum
        return min(max(gain, defaultGainMin), defaultGainMax)
    }
}

// MARK: - Highlight-safe metering (ETTR)

/// Mirrors `HighlightSafeMeteringStrategy` in metering.py.
public struct HighlightSafeMeteringStrategy: MeteringStrategy {
    public init() {}

    public func calculateGain(rgb: UnsafePointer<Float>,
                               width: Int, height: Int,
                               lumaCoeffs: (Float, Float, Float) = prophoToYCoeffs,
                               targetGray: Float = 0.18) -> Float {
        let (sample, sw, sh) = subsampleRGB(src: rgb, width: width, height: height)
        // Per-pixel maximum channel value
        var maxVals = [Float](repeating: 0, count: sw * sh)
        for i in 0 ..< sw * sh {
            let r = sample[i*3]; let g = sample[i*3+1]; let b = sample[i*3+2]
            maxVals[i] = max(r, max(g, b))
        }
        let highPct = percentile(maxVals, p: 99.0)
        let targetHigh: Float = 0.9
        return highPct < 1e-6 ? 1.0 : targetHigh / highPct
    }
}

// MARK: - Hybrid metering (average + highlight ceiling)

/// Mirrors `HybridMeteringStrategy` in metering.py.
public struct HybridMeteringStrategy: MeteringStrategy {
    public init() {}

    public func calculateGain(rgb: UnsafePointer<Float>,
                               width: Int, height: Int,
                               lumaCoeffs: (Float, Float, Float) = prophoToYCoeffs,
                               targetGray: Float = 0.18) -> Float {
        let (sample, sw, sh) = subsampleRGB(src: rgb, width: width, height: height)
        let lum = luminanceBuffer(rgb: sample, pixelCount: sw * sh, coeffs: lumaCoeffs)
        let avgLum  = logAverageLuminance(lum)
        var baseGain = targetGray / (avgLum + 1e-6)

        var maxVals = [Float](repeating: 0, count: sw * sh)
        for i in 0 ..< sw * sh {
            let r = sample[i*3]; let g = sample[i*3+1]; let b = sample[i*3+2]
            maxVals[i] = max(r, max(g, b))
        }
        let p99 = percentile(maxVals, p: 99.0)

        if p99 * baseGain > maxAllowedPeak {
            baseGain = maxAllowedPeak / p99
        }
        return min(max(baseGain, defaultGainMin), defaultGainMax)
    }
}

// MARK: - Matrix / evaluative metering

/// Mirrors `MatrixMeteringStrategy` in metering.py (7×7 grid with centre-bias,
/// highlight suppression and shadow boost).
public struct MatrixMeteringStrategy: MeteringStrategy {
    public init() {}

    public func calculateGain(rgb: UnsafePointer<Float>,
                               width: Int, height: Int,
                               lumaCoeffs: (Float, Float, Float) = prophoToYCoeffs,
                               targetGray: Float = 0.18) -> Float {
        let (sample, sw, sh) = subsampleRGB(src: rgb, width: width, height: height)
        let lum = luminanceBuffer(rgb: sample, pixelCount: sw * sh, coeffs: lumaCoeffs)

        let gridSize = 7
        let gridH = max(1, sh / gridSize)
        let gridW = max(1, sw / gridSize)

        // 1. Compute per-cell luminance
        var gridLums = [Float](repeating: 0, count: gridSize * gridSize)
        for gi in 0 ..< gridSize {
            for gj in 0 ..< gridSize {
                var sum: Float = 0; var cnt: Int = 0
                for yi in (gi * gridH) ..< min((gi+1) * gridH, sh) {
                    for xj in (gj * gridW) ..< min((gj+1) * gridW, sw) {
                        sum += lum[yi * sw + xj]; cnt += 1
                    }
                }
                gridLums[gi * gridSize + gj] = cnt > 0 ? sum / Float(cnt) : 0
            }
        }

        // 2. Compute weights
        var weights = [Float](repeating: 1, count: gridSize * gridSize)
        let cy = Float(gridSize - 1) / 2.0; let cx = Float(gridSize - 1) / 2.0
        let sigma = Float(gridSize) / 2.5

        for gi in 0 ..< gridSize {
            for gj in 0 ..< gridSize {
                let dy = Float(gi) - cy; let dx = Float(gj) - cx
                let bias = Foundation.exp(-(dx*dx + dy*dy) / (2 * sigma * sigma))
                weights[gi * gridSize + gj] *= (1 + bias * 1.5)
            }
        }

        let pct90 = percentile(gridLums, p: 90.0)
        let pct10 = percentile(gridLums, p: 10.0)
        for k in 0 ..< gridSize * gridSize {
            if gridLums[k] > pct90 { weights[k] *= 0.2 }
            if gridLums[k] < pct10 { weights[k] *= 1.2 }
        }

        let wAvgLum = weightedMean(gridLums, weights: weights)
        var gain = wAvgLum < 1e-6 ? 1.0 : targetGray / wAvgLum

        // Highlight protection
        var maxVals = [Float](repeating: 0, count: sw * sh)
        for i in 0 ..< sw * sh {
            let r = sample[i*3]; let g = sample[i*3+1]; let b = sample[i*3+2]
            maxVals[i] = max(r, max(g, b))
        }
        let p99 = percentile(maxVals, p: 99.0)
        if p99 * gain > maxAllowedPeak { gain = maxAllowedPeak / p99 }

        return min(max(gain, defaultGainMin), defaultGainMax)
    }
}

// MARK: - Factory

/// All available metering mode identifiers (mirrors Python METERING_STRATEGIES).
public enum MeteringMode: String, CaseIterable {
    case average        = "average"
    case centerWeighted = "center-weighted"
    case highlightSafe  = "highlight-safe"
    case hybrid         = "hybrid"
    case matrix         = "matrix"
}

/// Returns the concrete `MeteringStrategy` for the requested mode.
public func makeMeteringStrategy(_ mode: MeteringMode) -> any MeteringStrategy {
    switch mode {
    case .average:        return AverageMeteringStrategy()
    case .centerWeighted: return CenterWeightedMeteringStrategy()
    case .highlightSafe:  return HighlightSafeMeteringStrategy()
    case .hybrid:         return HybridMeteringStrategy()
    case .matrix:         return MatrixMeteringStrategy()
    }
}

// MARK: - Apply gain in-place

/// Multiplies every float in `buffer` by `gain` in-place.
public func applyGain(buffer: UnsafeMutablePointer<Float>,
                       count: Int,
                       gain: Float) {
    for i in 0 ..< count { buffer[i] *= gain }
}

/// Convenience: run the selected metering strategy and apply the resulting
/// gain to the pixel buffer in-place.
/// - Returns: The gain that was applied.
@discardableResult
public func applyAutoExposure(rgb: UnsafeMutablePointer<Float>,
                               width: Int, height: Int,
                               mode: MeteringMode = .hybrid,
                               lumaCoeffs: (Float, Float, Float) = prophoToYCoeffs,
                               targetGray: Float = 0.18) -> Float {
    let strategy = makeMeteringStrategy(mode)
    let gain = strategy.calculateGain(rgb: rgb, width: width, height: height,
                                       lumaCoeffs: lumaCoeffs, targetGray: targetGray)
    applyGain(buffer: rgb, count: width * height * 3, gain: gain)
    return gain
}
