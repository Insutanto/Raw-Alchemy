/// RawAlchemyKitTests.swift
/// Unit tests for the four core modules of RawAlchemyKit.
///
/// Run with:  swift test   (from RawAlchemySwift/)

import XCTest
@testable import RawAlchemyKit

final class RawAlchemyKitTests: XCTestCase {

    // =========================================================================
    // MARK: - Log encoding tests
    // =========================================================================

    /// S-Log3: middle grey (0.18) should encode to ≈ 0.410 code value.
    func testSLog3MiddleGrey() {
        let encoded = encodeSLog3(0.18)
        XCTAssertEqual(encoded, 0.410, accuracy: 0.005,
                       "S-Log3 middle grey expected ≈ 0.410")
    }

    /// V-Log: 0.01 should be in the linear segment.
    func testVLogLinearSegment() {
        let lo = encodeVLog(0.005)
        let hi = encodeVLog(0.015)
        XCTAssertLessThan(lo, hi, "V-Log should be monotonically increasing")
    }

    /// F-Log: monotonically increasing across the full range.
    func testFLogMonotone() {
        let vals: [Float] = [0.001, 0.01, 0.1, 0.5, 1.0, 10.0]
        for i in 0 ..< vals.count - 1 {
            XCTAssertLessThan(encodeFLog(vals[i]), encodeFLog(vals[i+1]),
                              "F-Log must be monotone at \(vals[i])")
        }
    }

    /// ARRI LogC3: middle grey near 0.38 (EI 800 spec).
    func testArriLogC3MiddleGrey() {
        let encoded = encodeArriLogC3(0.18)
        XCTAssertEqual(encoded, 0.391, accuracy: 0.010,
                       "ARRI LogC3 middle grey expected ≈ 0.391")
    }

    /// ARRI LogC4: encoding should return values in [0, 1] for normal inputs.
    func testArriLogC4Range() {
        for x: Float in [0.001, 0.01, 0.18, 0.5, 1.0] {
            let y = encodeArriLogC4(x)
            XCTAssertTrue(y >= 0 && y <= 1.0,
                          "LogC4(\(x)) = \(y) out of [0,1]")
        }
    }

    /// All LogSpace cases dispatch without crashing.
    func testAllLogSpacesDispatch() {
        for space in LogSpace.allCases {
            let y = encodeLog(0.18, space: space)
            XCTAssertFalse(y.isNaN,      "\(space.rawValue) produced NaN")
            XCTAssertFalse(y.isInfinite, "\(space.rawValue) produced Inf")
        }
    }

    // =========================================================================
    // MARK: - Exposure metering tests
    // =========================================================================

    /// Average metering: a uniform 0.18 image should return gain ≈ 1.0.
    func testAverageMeteringMidGrey() {
        let (buf, w, h) = makeUniformBuffer(value: 0.18)
        buf.withUnsafeBytes { rawBuf in
            let ptr = rawBuf.baseAddress!.assumingMemoryBound(to: Float.self)
            let gain = AverageMeteringStrategy().calculateGain(
                rgb: ptr, width: w, height: h,
                lumaCoeffs: prophoToYCoeffs, targetGray: 0.18)
            XCTAssertEqual(gain, 1.0, accuracy: 0.05,
                           "Mid-grey image should yield gain ≈ 1.0")
        }
    }

    /// Center-weighted metering: uniform image, gain ≈ 1.0.
    func testCenterWeightedMeteringMidGrey() {
        let (buf, w, h) = makeUniformBuffer(value: 0.18)
        buf.withUnsafeBytes { rawBuf in
            let ptr = rawBuf.baseAddress!.assumingMemoryBound(to: Float.self)
            let gain = CenterWeightedMeteringStrategy().calculateGain(
                rgb: ptr, width: w, height: h,
                lumaCoeffs: prophoToYCoeffs, targetGray: 0.18)
            XCTAssertEqual(gain, 1.0, accuracy: 0.05)
        }
    }

    /// HighlightSafe on a very bright image should return gain < 1.
    func testHighlightSafeBrightImage() {
        let (buf, w, h) = makeUniformBuffer(value: 0.9)
        buf.withUnsafeBytes { rawBuf in
            let ptr = rawBuf.baseAddress!.assumingMemoryBound(to: Float.self)
            let gain = HighlightSafeMeteringStrategy().calculateGain(
                rgb: ptr, width: w, height: h,
                lumaCoeffs: prophoToYCoeffs, targetGray: 0.18)
            XCTAssertLessThanOrEqual(gain, 1.0,
                           "Bright image highlight-safe gain should be ≤ 1")
        }
    }

    /// All metering modes dispatch without crashing.
    func testAllMeteringModesDispatch() {
        let (buf, w, h) = makeUniformBuffer(value: 0.18)
        buf.withUnsafeBytes { rawBuf in
            let ptr = rawBuf.baseAddress!.assumingMemoryBound(to: Float.self)
            for mode in MeteringMode.allCases {
                let gain = makeMeteringStrategy(mode).calculateGain(
                    rgb: ptr, width: w, height: h,
                    lumaCoeffs: prophoToYCoeffs, targetGray: 0.18)
                XCTAssertFalse(gain.isNaN,     "\(mode) produced NaN gain")
                XCTAssertFalse(gain.isInfinite, "\(mode) produced Inf gain")
                XCTAssertGreaterThan(gain, 0,  "\(mode) produced non-positive gain")
            }
        }
    }

    // =========================================================================
    // MARK: - LUT tetrahedral interpolation tests
    // =========================================================================

    /// Identity LUT: output should equal input.
    func testIdentityLUT() {
        let size = 17
        let lut  = makeIdentityLUT(size: size)
        var pixels: [Float] = [0.25, 0.50, 0.75,
                                0.10, 0.90, 0.20]
        pixels.withUnsafeMutableBufferPointer { bp in
            applyLUT3D(buffer: bp.baseAddress!, pixelCount: 2, lut: lut)
        }
        XCTAssertEqual(pixels[0], 0.25, accuracy: 0.005)
        XCTAssertEqual(pixels[1], 0.50, accuracy: 0.005)
        XCTAssertEqual(pixels[2], 0.75, accuracy: 0.005)
        XCTAssertEqual(pixels[3], 0.10, accuracy: 0.005)
        XCTAssertEqual(pixels[4], 0.90, accuracy: 0.005)
        XCTAssertEqual(pixels[5], 0.20, accuracy: 0.005)
    }

    /// Constant LUT: every output is (0.5, 0.5, 0.5).
    func testConstantLUT() {
        let size = 4
        let tableSize = size * size * size * 3
        let lut = LUT3D(size: size,
                        table: [Float](repeating: 0.5, count: tableSize))
        var pixels: [Float] = [0.0, 0.0, 0.0, 1.0, 1.0, 1.0]
        pixels.withUnsafeMutableBufferPointer { bp in
            applyLUT3D(buffer: bp.baseAddress!, pixelCount: 2, lut: lut)
        }
        for v in pixels { XCTAssertEqual(v, 0.5, accuracy: 1e-4) }
    }

    // =========================================================================
    // MARK: - Color-space matrix tests
    // =========================================================================

    /// ProPhoto → ProPhoto matrix should be identity.
    func testProphotToProPhotoIsIdentity() {
        // Use the ProPhoto primaries as both source and target (no conversion).
        // The helper function prophotoToTargetMatrix(prophotoPrimaries)
        // should return something close to identity (with D50→D50 adaptation).
        let m = prophotoToTargetMatrix(prophotoPrimaries)
        XCTAssertEqual(m[0], 1.0, accuracy: 0.005, "M[0,0] ≈ 1")
        XCTAssertEqual(m[4], 1.0, accuracy: 0.005, "M[1,1] ≈ 1")
        XCTAssertEqual(m[8], 1.0, accuracy: 0.005, "M[2,2] ≈ 1")
        XCTAssertEqual(m[1], 0.0, accuracy: 0.005, "M[0,1] ≈ 0")
        XCTAssertEqual(m[3], 0.0, accuracy: 0.005, "M[1,0] ≈ 0")
    }

    /// All LogSpace matrices are available and have finite values.
    func testAllMatricesFinite() {
        for space in LogSpace.allCases {
            let m = LogSpaceMatrix.matrix(for: space)
            XCTAssertEqual(m.count, 9, "\(space.rawValue) matrix should have 9 elements")
            for v in m {
                XCTAssertFalse(v.isNaN,      "\(space.rawValue) matrix contains NaN")
                XCTAssertFalse(v.isInfinite, "\(space.rawValue) matrix contains Inf")
            }
        }
    }

    /// applyMatrix3x3 with identity leaves pixels unchanged.
    func testApplyIdentityMatrix() {
        let identity: [Float] = [1,0,0, 0,1,0, 0,0,1]
        var pixels: [Float] = [0.2, 0.5, 0.8, 0.1, 0.3, 0.7]
        pixels.withUnsafeMutableBufferPointer { bp in
            applyMatrix3x3(buffer: bp.baseAddress!, pixelCount: 2, matrix: identity)
        }
        XCTAssertEqual(pixels[0], 0.2, accuracy: 1e-5)
        XCTAssertEqual(pixels[1], 0.5, accuracy: 1e-5)
        XCTAssertEqual(pixels[2], 0.8, accuracy: 1e-5)
    }

    // =========================================================================
    // MARK: - Helpers
    // =========================================================================

    /// Creates a uniform RGB Float32 buffer of size 64×64.
    private func makeUniformBuffer(value: Float) -> (Data, Int, Int) {
        let w = 64; let h = 64
        let count = w * h * 3
        var arr = [Float](repeating: value, count: count)
        return (Data(bytes: &arr, count: count * MemoryLayout<Float>.stride), w, h)
    }

    /// Creates an identity 3D LUT of the given size.
    private func makeIdentityLUT(size: Int) -> LUT3D {
        let n = size - 1
        var table = [Float](repeating: 0, count: size * size * size * 3)
        for r in 0 ..< size {
            for g in 0 ..< size {
                for b in 0 ..< size {
                    let idx = ((r * size + g) * size + b) * 3
                    table[idx + 0] = Float(r) / Float(n)
                    table[idx + 1] = Float(g) / Float(n)
                    table[idx + 2] = Float(b) / Float(n)
                }
            }
        }
        return LUT3D(size: size, table: table)
    }
}
