//
//  GestureData.swift
//  GestureKit
//
//  Portable .gesture.json schema (formatVersion 1). Everything a non-Swift
//  consumer needs is inside the file: joint order, units, axis conventions.
//

import Foundation
import simd

public enum GestureType: String, Codable, Sendable {
    case pose      // single held hand shape (1 frame)
    case motion    // time series
}

public enum Handedness: String, Codable, Sendable {
    case either    // recorded one hand, matches either (chirality-normalized)
    case left
    case right
    case bimanual  // both hands together, includes inter-hand relationship
}

public struct CoordinateSystem: Codable, Sendable, Equatable {
    public var units = "meters"
    public var axes = "right-handed, Y-up, joints are wrist-relative; wristTransform is world (column-major 4x4)"
    public var rotationFormat = "quaternion xyzw"
    public init() {}
}

/// One hand in one frame. Joints are packed 25 × 7 floats in `GestureFile.jointOrder`
/// order: [px, py, pz, qx, qy, qz, qw], wrist-anchor-relative.
public struct HandPose: Codable, Sendable {
    public static let stridePerJoint = 7

    public var wristTransform: [Float]   // 16 floats, column-major world transform
    public var joints: [Float]           // 25 × 7
    public var tracked: [Bool]?          // per joint; nil == all tracked

    public init(wristTransform: simd_float4x4, jointTransforms: [simd_float4x4], tracked: [Bool]? = nil) {
        self.wristTransform = wristTransform.packedColumnMajor
        var packed: [Float] = []
        packed.reserveCapacity(jointTransforms.count * Self.stridePerJoint)
        for m in jointTransforms {
            let p = m.columns.3
            let q = simd_quatf(m)
            packed.append(contentsOf: [p.x, p.y, p.z, q.imag.x, q.imag.y, q.imag.z, q.real])
        }
        self.joints = packed
        self.tracked = tracked
    }

    public var wristWorldTransform: simd_float4x4 { simd_float4x4(packedColumnMajor: wristTransform) }

    public func position(at index: Int) -> SIMD3<Float> {
        let o = index * Self.stridePerJoint
        return [joints[o], joints[o + 1], joints[o + 2]]
    }

    public func rotation(at index: Int) -> simd_quatf {
        let o = index * Self.stridePerJoint
        return simd_quatf(ix: joints[o + 3], iy: joints[o + 4], iz: joints[o + 5], r: joints[o + 6])
    }

    public func transform(at index: Int) -> simd_float4x4 {
        var m = simd_float4x4(rotation(at: index))
        let p = position(at: index)
        m.columns.3 = [p.x, p.y, p.z, 1]
        return m
    }
}

public struct GestureFrame: Codable, Sendable {
    public var t: Double          // seconds from sample start
    public var left: HandPose?
    public var right: HandPose?

    public init(t: Double, left: HandPose?, right: HandPose?) {
        self.t = t
        self.left = left
        self.right = right
    }
}

/// One recorded take. A gesture keeps multiple takes so matching can use all of them.
public struct GestureSample: Codable, Sendable {
    public var frames: [GestureFrame]
    public init(frames: [GestureFrame]) { self.frames = frames }
}

public struct GestureFile: Codable, Sendable, Identifiable {
    public var formatVersion: Int
    public var id: UUID
    public var name: String
    public var type: GestureType
    public var handedness: Handedness
    public var orientationSensitive: Bool
    public var sampleRate: Double
    public var coordinateSystem: CoordinateSystem
    public var createdAt: Date
    public var device: String
    public var jointOrder: [HandJoint]
    public var samples: [GestureSample]

    public init(name: String,
                type: GestureType,
                handedness: Handedness,
                orientationSensitive: Bool = false,
                sampleRate: Double = 12,
                samples: [GestureSample] = []) {
        self.formatVersion = 1
        self.id = UUID()
        self.name = name
        self.type = type
        self.handedness = handedness
        self.orientationSensitive = orientationSensitive
        self.sampleRate = sampleRate
        self.coordinateSystem = CoordinateSystem()
        self.createdAt = Date()
        self.device = "Apple Vision Pro"
        self.jointOrder = HandJoint.allCases
        self.samples = samples
    }

    public static func decode(from data: Data) throws -> GestureFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GestureFile.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public extension simd_float4x4 {
    var packedColumnMajor: [Float] {
        [columns.0, columns.1, columns.2, columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    init(packedColumnMajor f: [Float]) {
        self.init(columns: (SIMD4(f[0], f[1], f[2], f[3]),
                            SIMD4(f[4], f[5], f[6], f[7]),
                            SIMD4(f[8], f[9], f[10], f[11]),
                            SIMD4(f[12], f[13], f[14], f[15])))
    }
}
