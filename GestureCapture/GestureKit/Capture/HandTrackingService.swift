//
//  HandTrackingService.swift
//  GestureKit
//
//  Owns the ARKitSession + HandTrackingProvider and exposes the latest pair of
//  hand anchors. Requires an open ImmersiveSpace (any style, including .mixed);
//  unavailable in the simulator.
//

#if os(visionOS)
import ARKit
import Foundation
import QuartzCore

@Observable
@MainActor
public final class HandTrackingService {

    public enum State: Equatable {
        case idle
        case running
        case unsupported
        case denied
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var leftAnchor: HandAnchor?
    public private(set) var rightAnchor: HandAnchor?
    /// Time of the most recent anchor update, CACurrentMediaTime-based.
    public private(set) var lastUpdateTime: TimeInterval = 0

    private let session = ARKitSession()
    private let provider = HandTrackingProvider()
    private var updateTask: Task<Void, Never>?

    public init() {}

    public func start() async {
        guard state != .running else { return }
        guard HandTrackingProvider.isSupported else {
            state = .unsupported
            return
        }
        let auth = await session.requestAuthorization(for: [.handTracking])
        guard auth[.handTracking] == .allowed else {
            state = .denied
            return
        }
        do {
            try await session.run([provider])
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        updateTask = Task { [weak self] in
            guard let provider = self?.provider else { return }
            for await update in provider.anchorUpdates {
                guard let self, !Task.isCancelled else { return }
                let anchor = update.anchor
                switch anchor.chirality {
                case .left: self.leftAnchor = anchor
                case .right: self.rightAnchor = anchor
                }
                self.lastUpdateTime = CACurrentMediaTime()
            }
        }
    }

    public func stop() {
        updateTask?.cancel()
        updateTask = nil
        session.stop()
        state = .idle
        leftAnchor = nil
        rightAnchor = nil
    }
}

public extension HandPose {
    /// Snapshot of an ARKit hand anchor in the canonical joint order.
    init?(anchor: HandAnchor) {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else { return nil }
        let joints = HandJoint.allCases.map { skeleton.joint($0.arkitName) }
        self.init(wristTransform: anchor.originFromAnchorTransform,
                  jointTransforms: joints.map(\.anchorFromJointTransform),
                  tracked: joints.map(\.isTracked))
    }
}
#endif
