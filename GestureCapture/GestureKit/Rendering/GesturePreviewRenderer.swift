//
//  GesturePreviewRenderer.swift
//  GestureKit
//
//  Offscreen rendering of a recorded gesture using RealityRenderer:
//  poses → PNG thumbnail, motions → MP4 replay (12 fps data stepped at 30 fps).
//  No passthrough or screen capture involved — the rigged hand models are the
//  entire scene.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Metal
import RealityKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import UniformTypeIdentifiers
import simd

@MainActor
public final class GesturePreviewRenderer {

    public struct Output: Sendable {
        public var thumbnailPNG: Data
        public var videoURL: URL?   // motions only
    }

    private static let size = 720
    private static let videoFPS = 30.0
    private let device: MTLDevice

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw GestureKitError.missingResource("Metal device")
        }
        self.device = device
    }

    /// Renders the gesture's first sample. Video is written to `videoDestination`.
    public func render(gesture: GestureFile, videoDestination: URL) async throws -> Output {
        let renderer = try RealityRenderer()
        renderer.cameraSettings.colorBackground = .color(.init(gray: 0.12, alpha: 1))

        let replayer = GestureReplayer()
        try await replayer.load(gesture: gesture, placement: matrix_identity_float4x4)
        renderer.entities.append(replayer.root)

        // Camera: reconstruct the recorder's viewpoint. The replayer re-bases the
        // recorded wrist position to the origin but keeps orientation, and ARKit's
        // world origin is the floor under the user — so the head was roughly at
        // (0, 1.55, 0) minus the recorded wrist position, relative to the hand.
        let camera = Entity()
        camera.components.set(PerspectiveCameraComponent(near: 0.01, far: 5, fieldOfViewInDegrees: 45))
        let bounds = replayer.root.visualBounds(relativeTo: nil)
        let target = bounds.center
        var viewDirection = SIMD3<Float>(0, 0.35, 1)   // fallback: in front, slightly above
        if let firstFrame = gesture.samples.first?.frames.first,
           let wrist = (firstFrame.right ?? firstFrame.left)?.wristWorldTransform {
            let recordedWrist = SIMD3(wrist.columns.3.x, wrist.columns.3.y, wrist.columns.3.z)
            let headOffset = SIMD3<Float>(0, 1.55, 0) - recordedWrist
            if simd_length(headOffset) > 0.05 { viewDirection = simd_normalize(headOffset) }
        }
        let distance = max(simd_length(bounds.extents) * 1.25, 0.28)
        camera.look(at: target, from: target + viewDirection * distance, relativeTo: nil)
        renderer.entities.append(camera)
        renderer.activeCamera = camera

        let light = Entity()
        light.components.set(DirectionalLightComponent(color: .white, intensity: 2500))
        light.orientation = simd_quatf(angle: -.pi / 3, axis: [1, 0, 0])
        renderer.entities.append(light)

        let texture = try makeTexture()

        if gesture.type == .pose || replayer.duration <= 0 {
            replayer.seek(to: 0)
            let image = try await renderFrame(renderer: renderer, texture: texture)
            return Output(thumbnailPNG: try Self.pngData(from: image), videoURL: nil)
        }

        // Motion: encode frames at 30 fps; thumbnail = mid-motion frame.
        let frameCount = max(Int(replayer.duration * Self.videoFPS), 2)
        let writer = try VideoWriter(url: videoDestination,
                                     width: Self.size, height: Self.size, fps: Self.videoFPS)
        var thumbnail: CGImage?
        for i in 0..<frameCount {
            let t = Double(i) / Self.videoFPS
            replayer.seek(to: t)
            let image = try await renderFrame(renderer: renderer, texture: texture)
            try await writer.append(image: image, frameIndex: i)
            if i == frameCount / 2 { thumbnail = image }
        }
        try await writer.finish()
        guard let thumbnail else { throw GestureKitError.missingResource("thumbnail frame") }
        return Output(thumbnailPNG: try Self.pngData(from: thumbnail), videoURL: videoDestination)
    }

    private func makeTexture() throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: Self.size, height: Self.size, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw GestureKitError.missingResource("render texture")
        }
        return texture
    }

    private func renderFrame(renderer: RealityRenderer, texture: MTLTexture) async throws -> CGImage {
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            do {
                try renderer.updateAndRender(deltaTime: 1.0 / Self.videoFPS,
                                             cameraOutput: output,
                                             onComplete: { _ in cont.resume() })
            } catch {
                cont.resume(throwing: error)
            }
        }
        return try Self.cgImage(from: texture)
    }

    // MARK: - Pixel plumbing

    private static func cgImage(from texture: MTLTexture) throws -> CGImage {
        let width = texture.width, height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        // BGRA little-endian
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else {
            throw GestureKitError.missingResource("CGImage conversion")
        }
        return image
    }

    private static func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else {
            throw GestureKitError.missingResource("PNG encoder")
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}

// MARK: - MP4 writer

private final class VideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Double

    init(url: URL, width: Int, height: Int, fps: Double) throws {
        try? FileManager.default.removeItem(at: url)
        self.fps = fps
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func append(image: CGImage, frameIndex: Int) async throws {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw GestureKitError.missingResource("pixel buffer pool")
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw GestureKitError.missingResource("pixel buffer") }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                width: image.width, height: image.height,
                                bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                    | CGImageAlphaInfo.premultipliedFirst.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
        adaptor.append(buffer, withPresentationTime: time)
    }

    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}
