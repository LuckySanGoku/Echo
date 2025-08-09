import Foundation
import SwiftUI
import Photos
import CoreLocation

// MARK: - Photo Tag Enum
enum PhotoTag: String, CaseIterable, Codable {
    case duplicate = "duplicate"
    case blurry = "blurry"
    case lowQuality = "lowQuality"
    case screenshot = "screenshot"
    case unrated = "unrated"
    case textHeavy = "textHeavy"        // photos with significant text that aren't screenshots
    case people = "people"              // photos containing faces
    case lowLight = "lowLight"          // underexposed but potentially recoverable
    case nearDuplicate = "nearDuplicate" // similar but not exact matches
    case document = "document"          // scanned documents, receipts, IDs
}

// MARK: - Photo Metadata
struct PhotoMetadata: Codable {
    let creationDate: Date?
    let location: CLLocation?
    let source: String? // Camera, Screenshot, etc.
    let dimensions: CGSize
    let isScreenshot: Bool
    let textDensity: Double // 0-1, higher = more text
    
    private enum CodingKeys: String, CodingKey {
        case creationDate, source, dimensions, isScreenshot, textDensity
        case latitude, longitude
    }
    
    init(creationDate: Date?, location: CLLocation?, source: String?, dimensions: CGSize, isScreenshot: Bool, textDensity: Double) {
        self.creationDate = creationDate
        self.location = location
        self.source = source
        self.dimensions = dimensions
        self.isScreenshot = isScreenshot
        self.textDensity = textDensity
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        dimensions = try container.decode(CGSize.self, forKey: .dimensions)
        isScreenshot = try container.decode(Bool.self, forKey: .isScreenshot)
        textDensity = try container.decode(Double.self, forKey: .textDensity)
        
        // Handle location
        if let latitude = try container.decodeIfPresent(Double.self, forKey: .latitude),
           let longitude = try container.decodeIfPresent(Double.self, forKey: .longitude) {
            location = CLLocation(latitude: latitude, longitude: longitude)
        } else {
            location = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(creationDate, forKey: .creationDate)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encode(dimensions, forKey: .dimensions)
        try container.encode(isScreenshot, forKey: .isScreenshot)
        try container.encode(textDensity, forKey: .textDensity)
        
        // Handle location
        if let location = location {
            try container.encode(location.coordinate.latitude, forKey: .latitude)
            try container.encode(location.coordinate.longitude, forKey: .longitude)
        }
    }
}

// MARK: - Photo Scan Result
struct PhotoScanResult: Identifiable {
    let id: String
    let thumbnail: Image
    var tags: Set<PhotoTag>  // Confirmed tags (what we know for sure)
    var predictedTags: Set<PhotoTag> = []  // AI predictions (for training)
    var tagConfidence: [PhotoTag: Double] = [:]  // Confidence scores for each tag
    var relatedPhotoIds: [String] = []  // IDs of related photos (for duplicates)
    let asset: PHAsset
    let exactHash: String
    let perceptualHash: UInt64
    let metadata: PhotoMetadata
    
    // For persistence - we can't store PHAsset or Image directly
    func toPersistableResult() -> PersistablePhotoResult {
        return PersistablePhotoResult(
            id: id,
            tags: Array(tags.map { $0.rawValue }),
            exactHash: exactHash,
            perceptualHash: perceptualHash,
            metadata: metadata
        )
    }
    
    init(from persistable: PersistablePhotoResult, asset: PHAsset, thumbnail: Image) {
        self.id = persistable.id
        self.thumbnail = thumbnail
        self.tags = Set(persistable.tags.compactMap { PhotoTag(rawValue: $0) })
        self.asset = asset
        self.exactHash = persistable.exactHash
        self.perceptualHash = persistable.perceptualHash
        self.metadata = persistable.metadata
    }
    
    init(id: String, thumbnail: Image, tags: Set<PhotoTag>, asset: PHAsset, exactHash: String, perceptualHash: UInt64, metadata: PhotoMetadata) {
        self.id = id
        self.thumbnail = thumbnail
        self.tags = tags
        self.asset = asset
        self.exactHash = exactHash
        self.perceptualHash = perceptualHash
        self.metadata = metadata
    }
}

// MARK: - Persistable Photo Result
struct PersistablePhotoResult: Codable {
    let id: String
    let tags: [String]
    let exactHash: String
    let perceptualHash: UInt64
    let metadata: PhotoMetadata
}