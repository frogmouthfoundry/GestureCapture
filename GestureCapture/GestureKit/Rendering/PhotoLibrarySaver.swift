//
//  PhotoLibrarySaver.swift
//  GestureKit
//
//  Saves rendered previews to Photos with add-only authorization (lightweight
//  permission prompt; NSPhotoLibraryAddUsageDescription required).
//

import Foundation
import Photos

public enum PhotoLibrarySaver {

    public enum SaveError: Error, LocalizedError {
        case notAuthorized
        public var errorDescription: String? {
            "Photos access was not granted. Allow \"Add Photos Only\" in Settings."
        }
    }

    public static func save(pngData: Data? = nil, videoURL: URL? = nil) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw SaveError.notAuthorized
        }
        try await PHPhotoLibrary.shared().performChanges {
            if let pngData {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: pngData, options: nil)
            }
            if let videoURL {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            }
        }
    }
}
