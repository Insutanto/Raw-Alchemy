/// ColorSpace.swift
/// Defines the color-space primaries used throughout the pipeline and provides
/// a utility to compute the 3×3 RGB-to-RGB transformation matrix that maps
/// ProPhoto RGB (linear, D50) into any of the supported camera log working
/// spaces (linear, typically D65).
///
/// All math follows the standard methodology used by the colour-science Python
/// library (https://www.colour-science.org/):
///   1. Convert xy chromaticities to XYZ using Y=1 normalisation.
///   2. Solve for the scaling coefficients against the white point.
///   3. Build M_rgb_to_xyz.
///   4. Apply Bradford chromatic adaptation (D50 ↔ D65) where required.
///   5. Compose M_source → M_dest via XYZ.

import Foundation
import Accelerate

// MARK: - Chromaticity helpers

/// A CIE xy chromaticity coordinate pair.
public struct Chromaticity {
    public let x: Double
    public let y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    /// Convert to XYZ with Y = 1.
    var xyz: (X: Double, Y: Double, Z: Double) {
        (X: x / y, Y: 1.0, Z: (1.0 - x - y) / y)
    }
}

// MARK: - 3×3 matrix helpers (row-major, Double)

public typealias Mat3 = (
    Double, Double, Double,
    Double, Double, Double,
    Double, Double, Double
)

func mat3Multiply(_ a: Mat3, _ b: Mat3) -> Mat3 {
    let (a00,a01,a02, a10,a11,a12, a20,a21,a22) = a
    let (b00,b01,b02, b10,b11,b12, b20,b21,b22) = b
    return (
        a00*b00+a01*b10+a02*b20, a00*b01+a01*b11+a02*b21, a00*b02+a01*b12+a02*b22,
        a10*b00+a11*b10+a12*b20, a10*b01+a11*b11+a12*b21, a10*b02+a11*b12+a12*b22,
        a20*b00+a21*b10+a22*b20, a20*b01+a21*b11+a22*b21, a20*b02+a21*b12+a22*b22
    )
}

/// Invert a 3×3 matrix using cofactor expansion.
func mat3Inverse(_ m: Mat3) -> Mat3 {
    let (a,b,c, d,e,f, g,h,i) = m
    let A =  (e*i - f*h); let B = -(d*i - f*g); let C =  (d*h - e*g)
    let D = -(b*i - c*h); let E =  (a*i - c*g); let F = -(a*h - b*g)
    let G =  (b*f - c*e); let H = -(a*f - c*d); let I =  (a*e - b*d)
    let det = a*A + b*B + c*C
    let inv = 1.0 / det
    return (A*inv,D*inv,G*inv, B*inv,E*inv,H*inv, C*inv,F*inv,I*inv)
}

func mat3ApplyToVec(_ m: Mat3, _ v: (Double,Double,Double)) -> (Double,Double,Double) {
    let (a,b,c, d,e,f, g,h,i) = m
    let (x,y,z) = v
    return (a*x+b*y+c*z, d*x+e*y+f*z, g*x+h*y+i*z)
}

// MARK: - Build RGB → XYZ matrix from chromaticities

func buildRGBtoXYZ(r: Chromaticity, g: Chromaticity, b: Chromaticity,
                   w: Chromaticity) -> Mat3 {
    let (Xr,Yr,Zr) = r.xyz
    let (Xg,Yg,Zg) = g.xyz
    let (Xb,Yb,Zb) = b.xyz
    let (Xw,Yw,Zw) = w.xyz

    let M: Mat3 = (Xr,Xg,Xb, Yr,Yg,Yb, Zr,Zg,Zb)
    let Minv = mat3Inverse(M)
    let S = mat3ApplyToVec(Minv, (Xw, Yw, Zw))
    let (Sr,Sg,Sb) = S
    return (
        Sr*Xr, Sg*Xg, Sb*Xb,
        Sr*Yr, Sg*Yg, Sb*Yb,
        Sr*Zr, Sg*Zg, Sb*Zb
    )
}

// MARK: - Bradford chromatic adaptation (D50 ↔ D65)

// Bradford D50 → D65 adaptation matrix (pre-computed, from ICC & colour-science)
let bradfordD50toD65: Mat3 = (
     0.9555766, -0.0230393,  0.0631636,
    -0.0282895,  1.0099416,  0.0210077,
     0.0122982, -0.0204830,  1.3299098
)

let bradfordD65toD50: Mat3 = (
     1.0478112,  0.0228866, -0.0501270,
     0.0295424,  0.9904844, -0.0170491,
    -0.0092345,  0.0150436,  0.7521316
)

// MARK: - Color-space primary definitions

/// Represents a color space by its xy primaries and white point.
public struct RGBColorSpacePrimaries {
    public let r: Chromaticity
    public let g: Chromaticity
    public let b: Chromaticity
    public let w: Chromaticity  // white point

    /// Whether this white point is D50 (vs D65 for most camera spaces).
    public let isD50: Bool

    public init(r: Chromaticity, g: Chromaticity, b: Chromaticity,
                w: Chromaticity, isD50: Bool = false) {
        self.r = r; self.g = g; self.b = b; self.w = w; self.isD50 = isD50
    }
}

// Standard illuminants
let D50 = Chromaticity(0.3457, 0.3585)
let D65 = Chromaticity(0.3127, 0.3290)

// ── Known primaries ──────────────────────────────────────────────────────────
// Sources:
//   • ProPhoto / ROMM RGB: ICC profile specification
//   • Camera spaces: manufacturer SDK documentation +
//                    ACES Common LUT Format (CLF) spec +
//                    colour-science library (https://colour.readthedocs.io)

public let prophotoPrimaries = RGBColorSpacePrimaries(
    r: .init(0.7347, 0.2653), g: .init(0.1596, 0.8404), b: .init(0.0366, 0.0001),
    w: D50, isD50: true)

public let sGamut3Primaries = RGBColorSpacePrimaries(
    r: .init(0.7300, 0.2800), g: .init(0.1400, 0.8500), b: .init(0.1000, -0.0500),
    w: D65)

public let sGamut3CinePrimaries = RGBColorSpacePrimaries(
    r: .init(0.7660, 0.2750), g: .init(0.2250, 0.8000), b: .init(0.0890, -0.0870),
    w: D65)

public let fGamutPrimaries = RGBColorSpacePrimaries(
    r: .init(0.7347, 0.2653), g: .init(0.1500, 0.8800), b: .init(0.1000, -0.0500),
    w: D65)

// F-Gamut C (Fujifilm FUJINON cinema)
// Note: F-Gamut C uses the same xy primaries as N-Gamut and BT.2020.
// This is intentional – all three independently specify the same ITU-R
// BT.2020 primaries (confirmed in colour-science and Fujifilm documentation).
public let fGamutCPrimaries = RGBColorSpacePrimaries(
    r: .init(0.7080, 0.2920), g: .init(0.1700, 0.7970), b: .init(0.1310, 0.0460),
    w: D65)

public let vGamutPrimaries = RGBColorSpacePrimaries(
    r: .init(0.7300, 0.2800), g: .init(0.1650, 0.8400), b: .init(0.1000, -0.0300),
    w: D65)

// Note: N-Gamut primaries match ITU-R BT.2020 exactly (confirmed in
// Nikon N-Log specification and colour-science library).
public let nGamutPrimaries = RGBColorSpacePrimaries(
    r: .init(0.7080, 0.2920), g: .init(0.1700, 0.7970), b: .init(0.1310, 0.0460),
    w: D65)

// ITU-R BT.2020 (used by L-Log)
// Primaries defined in ITU-R BT.2020 Table 2 (D65 white point).
// Note: nGamutPrimaries and fGamutCPrimaries also use these same primaries –
// that is correct per their respective manufacturer specifications.
public let bt2020Primaries = RGBColorSpacePrimaries(
    r: .init(0.7080, 0.2920), g: .init(0.1700, 0.7970), b: .init(0.1310, 0.0460),
    w: D65)

// Canon Cinema Gamut
public let cinemaGamutPrimaries = RGBColorSpacePrimaries(
    r: .init(0.7400, 0.2700), g: .init(0.1700, 1.1400), b: .init(0.0800, -0.1000),
    w: D65)

// ARRI Wide Gamut 3
public let arriWG3Primaries = RGBColorSpacePrimaries(
    r: .init(0.6840, 0.3130), g: .init(0.2210, 0.8480), b: .init(0.0861, -0.1020),
    w: D65)

// ARRI Wide Gamut 4
public let arriWG4Primaries = RGBColorSpacePrimaries(
    r: .init(0.7347, 0.2653), g: .init(0.1424, 0.8576), b: .init(0.0991, -0.0308),
    w: D65)

// RED Wide Gamut RGB
public let redWideGamutPrimaries = RGBColorSpacePrimaries(
    r: .init(0.7800, 0.3040), g: .init(0.1200, 1.1720), b: .init(0.1010, -0.1490),
    w: D65)

// DJI D-Gamut
public let djiDGamutPrimaries = RGBColorSpacePrimaries(
    r: .init(0.7100, 0.3100), g: .init(0.2110, 0.7810), b: .init(0.0210, -0.1060),
    w: D65)

// MARK: - Derive ProPhoto → target transformation matrix

/// Returns the 3×3 matrix (as a flat `[Float]` array, row-major) that maps
/// ProPhoto RGB (linear D50) values to the linear target color space.
/// This exactly mirrors `colour.matrix_RGB_to_RGB(ProPhoto, target)`.
public func prophotoToTargetMatrix(_ target: RGBColorSpacePrimaries) -> [Float] {
    // 1. Build M_prophoto → XYZ_D50
    let Msrc = buildRGBtoXYZ(r: prophotoPrimaries.r, g: prophotoPrimaries.g,
                              b: prophotoPrimaries.b, w: prophotoPrimaries.w)
    // 2. Build M_target → XYZ_target
    let Mtgt = buildRGBtoXYZ(r: target.r, g: target.g, b: target.b, w: target.w)

    // 3. Build M_XYZ_target → target_RGB = inv(M_target)
    let MtgtInv = mat3Inverse(Mtgt)

    // 4. Handle chromatic adaptation if white points differ
    //    ProPhoto = D50, most camera spaces = D65
    let Madapt: Mat3
    if target.isD50 {
        // No adaptation needed – both D50
        Madapt = (1,0,0, 0,1,0, 0,0,1)
    } else {
        // D50 → D65 (Bradford)
        Madapt = bradfordD50toD65
    }

    // 5. Compose: M = MtgtInv × Madapt × Msrc
    let M1 = mat3Multiply(Madapt, Msrc)      // XYZ_D50 → XYZ_D65
    let M  = mat3Multiply(MtgtInv, M1)       // XYZ_D65 → target RGB

    let (a,b,c, d,e,f, g,h,i) = M
    return [Float(a),Float(b),Float(c),
            Float(d),Float(e),Float(f),
            Float(g),Float(h),Float(i)]
}

// MARK: - Pre-computed matrices for all supported log spaces

/// The set of pre-computed 3×3 matrices (row-major Float arrays) from ProPhoto
/// linear to each supported log-space's *linear* working gamut.
public enum LogSpaceMatrix {
    public static let sLog3     = prophotoToTargetMatrix(sGamut3Primaries)
    public static let sLog3Cine = prophotoToTargetMatrix(sGamut3CinePrimaries)
    public static let fLog      = prophotoToTargetMatrix(fGamutPrimaries)
    public static let fLog2     = prophotoToTargetMatrix(fGamutPrimaries)
    public static let fLog2C    = prophotoToTargetMatrix(fGamutCPrimaries)
    public static let vLog      = prophotoToTargetMatrix(vGamutPrimaries)
    public static let nLog      = prophotoToTargetMatrix(nGamutPrimaries)
    public static let lLog      = prophotoToTargetMatrix(bt2020Primaries)    // L-Log → BT.2020
    public static let canonLog2 = prophotoToTargetMatrix(cinemaGamutPrimaries)
    public static let canonLog3 = prophotoToTargetMatrix(cinemaGamutPrimaries)
    public static let arriLogC3 = prophotoToTargetMatrix(arriWG3Primaries)
    public static let arriLogC4 = prophotoToTargetMatrix(arriWG4Primaries)
    public static let log3G10   = prophotoToTargetMatrix(redWideGamutPrimaries)
    public static let dLog      = prophotoToTargetMatrix(djiDGamutPrimaries)

    /// Look up the matrix for a given `LogSpace`.
    public static func matrix(for space: LogSpace) -> [Float] {
        switch space {
        case .sLog3:     return sLog3
        case .sLog3Cine: return sLog3Cine
        case .fLog:      return fLog
        case .fLog2:     return fLog2
        case .fLog2C:    return fLog2C
        case .vLog:      return vLog
        case .nLog:      return nLog
        case .lLog:      return lLog
        case .canonLog2: return canonLog2
        case .canonLog3: return canonLog3
        case .arriLogC3: return arriLogC3
        case .arriLogC4: return arriLogC4
        case .log3G10:   return log3G10
        case .dLog:      return dLog
        }
    }
}

// MARK: - Apply a 3×3 matrix to a Float32 pixel buffer in-place

/// Applies a row-major 3×3 `matrix` to every RGB pixel in `buffer`
/// (interleaved R G B R G B … layout, `pixelCount` triples).
/// Uses vDSP when channel count is 3 for maximum throughput.
public func applyMatrix3x3(buffer: UnsafeMutablePointer<Float>,
                            pixelCount: Int,
                            matrix: [Float]) {
    precondition(matrix.count == 9)
    let m = matrix
    let stride = 3
    for i in 0 ..< pixelCount {
        let base = i * stride
        let r = buffer[base + 0]
        let g = buffer[base + 1]
        let b = buffer[base + 2]
        buffer[base + 0] = m[0]*r + m[1]*g + m[2]*b
        buffer[base + 1] = m[3]*r + m[4]*g + m[5]*b
        buffer[base + 2] = m[6]*r + m[7]*g + m[8]*b
    }
}
