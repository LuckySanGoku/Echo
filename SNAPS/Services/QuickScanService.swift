import Foundation
import SwiftUI
import Photos
import CoreImage
import UIKit

@MainActor
class QuickScanService: ObservableObject, @unchecked Sendable {
    @Published var results: [PhotoScanResult] = []
    @Published var isScanning = false
    @Published var refreshTrigger = UUID()
    @Published var trainingConfidence: Double = 0.0
    @Published var isTrainingComplete = false
    
    // Date formatter for timestamps
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    
    // Scanning and analysis properties
    private var scanOffset = 0
    private let batchSize = 20
    private var ratedPhotos: Set<String> = []
    private var photoHashes: [String: String] = [:]
    
    // MARK: - Main Interface
    
    func scanAllAssets() {
        guard !isScanning else { return }
        
        isScanning = true
        scanOffset = 0
        
        Task {
            await loadPhotosFromLibrary()
            await MainActor.run {
                self.isScanning = false
                let timestamp = Self.timestampFormatter.string(from: Date())
                print("\(timestamp) ✅ Scan completed: \(self.results.count) photos processed")
            }
        }
    }
    
    // MARK: - Preloading for Training
    
    func preloadNextBatch() async {
        let timestamp = Self.timestampFormatter.string(from: Date())
        print("\(timestamp) 📦 Starting preload of next batch...")
        
        guard !isScanning else {
            print("\(timestamp) ⚠️ Preload skipped - already scanning")
            return
        }
        
        await MainActor.run {
            self.isScanning = true
        }
        
        let initialCount = await MainActor.run { self.results.count }
        
        // Load next batch of photos
        await loadPhotosFromLibrary()
        
        await MainActor.run {
            self.isScanning = false
            let newCount = self.results.count
            let loadedCount = newCount - initialCount
            let newTimestamp = Self.timestampFormatter.string(from: Date())
            print("\(newTimestamp) 📦 Preload completed: loaded \(loadedCount) new photos (total: \(newCount))")
        }
    }
    
    func startFullScan() {
        let timestamp = Self.timestampFormatter.string(from: Date())
        print("\(timestamp) 🚀 Starting full library scan...")
        scanAllAssets()
    }
    
    func resetTraining() {
        results.removeAll()
        ratedPhotos.removeAll()
        photoHashes.removeAll()
        trainingConfidence = 0.0
        isTrainingComplete = false
        scanOffset = 0
        refreshTrigger = UUID()
        
        // Clear UserDefaults
        UserDefaults.standard.removeObject(forKey: "photo_scan_results")
        UserDefaults.standard.removeObject(forKey: "rated_photos")
        UserDefaults.standard.removeObject(forKey: "photo_hashes")
        UserDefaults.standard.removeObject(forKey: "training_confidence")
        
        // Clear corrupted learning data and reset thresholds
        LearningService.shared.clearAllFeedback()
        
        let timestamp = Self.timestampFormatter.string(from: Date())
        print("\(timestamp) 🔄 Training reset complete with fresh thresholds")
    }
    
    // MARK: - Photo Processing
    
    private func loadPhotosFromLibrary() async {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // Use offset for batch loading to get new photos each time
        let currentOffset = await MainActor.run { self.scanOffset }
        let currentBatchSize = await MainActor.run { self.batchSize }
        
        let timestamp = Self.timestampFormatter.string(from: Date())
        print("\(timestamp) 📷 Loading photos from offset \(currentOffset), batch size \(currentBatchSize)")
        
        let allAssets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let totalAssets = allAssets.count
        
        print("\(timestamp) 📷 Total assets in library: \(totalAssets)")
        
        // Calculate the range for this batch
        let startIndex = currentOffset
        let endIndex = min(startIndex + currentBatchSize, totalAssets)
        
        guard startIndex < totalAssets else {
            print("\(timestamp) 📷 No more photos to load (offset \(startIndex) >= total \(totalAssets))")
            return
        }
        
        print("\(timestamp) 📷 Loading photos \(startIndex) to \(endIndex-1)")
        
        var assets: [PHAsset] = []
        for i in startIndex..<endIndex {
            assets.append(allAssets[i])
        }
        
        // Update offset for next batch
        await MainActor.run {
            self.scanOffset = endIndex
        }
        let imageManager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.isSynchronous = false
        requestOptions.deliveryMode = .fastFormat  // Ensure at least one delivery
        requestOptions.resizeMode = .fast  // Optimize for speed
        
        // Use TaskGroup for Swift 6 concurrency
        let newResults = await withTaskGroup(of: PhotoScanResult?.self, returning: [PhotoScanResult].self) { group in
            var results: [PhotoScanResult] = []
            
            for asset in assets {
                let id = asset.localIdentifier
                
                // Skip if already processed
                if await MainActor.run(body: { self.results.contains(where: { $0.id == id }) }) {
                    continue
                }
                
                group.addTask {
                    return await self.processAsset(asset: asset, imageManager: imageManager, requestOptions: requestOptions)
                }
            }
            
            // Collect results
            for await result in group {
                if let result = result {
                    results.append(result)
                }
            }
            
            return results
        }
        
        // Add results to main array
        await MainActor.run {
            let addedCount = newResults.count
            self.results.append(contentsOf: newResults)
            self.calculateTrainingConfidence()
            
            let finalTimestamp = Self.timestampFormatter.string(from: Date())
            print("\(finalTimestamp) 📷 Added \(addedCount) new photos to results (total: \(self.results.count))")
            
            // Clear any cached images if we have too many results
            if self.results.count % 20 == 0 {
                print("\(finalTimestamp) 🧹 Clearing image cache after processing \(self.results.count) photos")
                // Clear TrainingView image cache to free memory
                NotificationCenter.default.post(name: Notification.Name("ClearImageCache"), object: nil)
            }
        }
    }
    
    private func extractMetadata(from asset: PHAsset) -> PhotoMetadata {
        let dimensions = CGSize(width: CGFloat(asset.pixelWidth), height: CGFloat(asset.pixelHeight))
        let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        
        return PhotoMetadata(
            creationDate: asset.creationDate,
            location: asset.location,
            source: isScreenshot ? "Screenshot" : "Camera",
            dimensions: dimensions,
            isScreenshot: isScreenshot,
            textDensity: isScreenshot ? 0.8 : 0.1 // Simplified text density
        )
    }
    
    private func classifyPhoto(image: UIImage, metadata: PhotoMetadata) async -> (tags: Set<PhotoTag>, confidence: [PhotoTag: Double], relatedIds: [String]) {
        var tags: Set<PhotoTag> = [.unrated]
        var confidence: [PhotoTag: Double] = [:]
        var relatedIds: [String] = []
        
        let rules = LearningService.shared.getClassificationRules()
        
        // Debug logging
        let timestamp = Self.timestampFormatter.string(from: Date())
        print("\(timestamp) 🔍 Classifying photo:")
        
        // Screenshot detection
        let isScreenshotMeta = metadata.isScreenshot
        let screenshotScore = calculateScreenshotScore(image, threshold: rules.screenshotThreshold)
        confidence[.screenshot] = screenshotScore
        
        if isScreenshotMeta || screenshotScore > rules.screenshotThreshold {
            tags.insert(.screenshot)
            tags.remove(.unrated)
            print("  ✅ Tagged as SCREENSHOT (confidence: \(String(format: "%.2f", screenshotScore)))")
        }
        
        // Document detection (high contrast rectangles, text patterns, not screenshot aspect ratio)
        let documentScore = calculateDocumentScore(image, metadata: metadata)
        confidence[.document] = documentScore
        
        if documentScore > 0.6 && !tags.contains(.screenshot) {
            tags.insert(.document)
            tags.remove(.unrated)
            print("  ✅ Tagged as DOCUMENT (confidence: \(String(format: "%.2f", documentScore)))")
        }
        
        // Text-heavy detection (high text density but not screenshot)
        let textScore = calculateTextHeavyScore(image, metadata: metadata)
        confidence[.textHeavy] = textScore
        
        if textScore > 0.7 && !tags.contains(.screenshot) && !tags.contains(.document) {
            tags.insert(.textHeavy)
            tags.remove(.unrated)
            print("  ✅ Tagged as TEXT HEAVY (confidence: \(String(format: "%.2f", textScore)))")
        }
        
        // Blur detection with confidence
        let blurValue = calculateBlurValue(image)
        let blurConfidence = calculateBlurConfidence(blurValue, threshold: rules.blurThreshold)
        confidence[.blurry] = blurConfidence
        
        if blurValue < rules.blurThreshold {
            tags.insert(.blurry)
            tags.remove(.unrated)
            print("  ✅ Tagged as BLURRY (confidence: \(String(format: "%.2f", blurConfidence)))")
        }
        
        // Low light detection (underexposed but potentially recoverable)
        let lowLightScore = calculateLowLightScore(image)
        confidence[.lowLight] = lowLightScore
        
        if lowLightScore > 0.7 {
            tags.insert(.lowLight)
            tags.remove(.unrated)
            print("  ✅ Tagged as LOW LIGHT (confidence: \(String(format: "%.2f", lowLightScore)))")
        }
        
        // Quality detection (but don't mark as low quality if contains people - will add face detection later)
        let qualityScore = calculateQualityScore(image, metadata: metadata)
        let qualityConfidence = 1.0 - qualityScore // Invert since low score = low quality
        confidence[.lowQuality] = qualityConfidence
        
        // Skip low quality tagging if we detect this might contain people (simplified check)
        let mightContainPeople = false // Placeholder for future face detection
        
        if qualityScore < rules.lowQualityThreshold && !mightContainPeople {
            tags.insert(.lowQuality)
            tags.remove(.unrated)
            print("  ✅ Tagged as LOW QUALITY (confidence: \(String(format: "%.2f", qualityConfidence)))")
        }
        
        // Duplicate detection with relationships
        let imageHash = generatePerceptualHash(from: image)
        if let (duplicateInfo, similarity) = await findExistingDuplicateWithSimilarity(hash: imageHash, dimensions: metadata.dimensions) {
            confidence[.duplicate] = similarity
            relatedIds.append(duplicateInfo.id)
            
            if similarity > 0.95 {
                tags.insert(.duplicate)
                print("  ✅ Tagged as EXACT DUPLICATE (similarity: \(String(format: "%.2f", similarity)))")
            } else if similarity > 0.8 {
                tags.insert(.nearDuplicate)
                confidence[.nearDuplicate] = similarity
                print("  ✅ Tagged as NEAR DUPLICATE (similarity: \(String(format: "%.2f", similarity)))")
            }
            tags.remove(.unrated)
        }
        
        print("  🏷️ Final tags: \(tags)")
        print("  📊 Confidence scores: \(confidence)")
        return (tags: tags, confidence: confidence, relatedIds: relatedIds)
    }
    
    // MARK: - Advanced ML Classification Algorithms
    
    private func calculateBlurValue(_ image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return 1.0 }
        
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext()
        
        // Use Laplacian filter to detect blur
        let filter = CIFilter(name: "CIConvolution3X3")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        
        // Laplacian kernel for edge detection
        let laplacianKernel = CIVector(values: [0, -1, 0,
                                               -1, 4, -1,
                                               0, -1, 0], count: 9)
        filter?.setValue(laplacianKernel, forKey: "inputWeights")
        
        guard let outputImage = filter?.outputImage,
              let cgOutput = context.createCGImage(outputImage, from: outputImage.extent) else {
            return 1.0
        }
        
        // Calculate variance of the filtered image
        return calculateImageVariance(cgOutput)
    }
    
    private func calculateImageVariance(_ cgImage: CGImage) -> Double {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        
        guard let data = CFDataCreateMutable(nil, width * height * bytesPerPixel),
              let context = CGContext(data: CFDataGetMutableBytePtr(data),
                                    width: width,
                                    height: height,
                                    bitsPerComponent: bitsPerComponent,
                                    bytesPerRow: bytesPerRow,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return 1.0
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        let pixels = CFDataGetBytePtr(data)
        var sum: Double = 0
        var sumSquared: Double = 0
        let totalPixels = width * height
        
        for i in 0..<totalPixels {
            let pixelIndex = i * bytesPerPixel
            let gray = Double(pixels![pixelIndex]) * 0.299 + 
                      Double(pixels![pixelIndex + 1]) * 0.587 + 
                      Double(pixels![pixelIndex + 2]) * 0.114
            sum += gray
            sumSquared += gray * gray
        }
        
        let mean = sum / Double(totalPixels)
        let variance = (sumSquared / Double(totalPixels)) - (mean * mean)
        
        return variance / 10000.0  // Normalize to reasonable range
    }
    
    // Calculate screenshot score with confidence
    private func calculateScreenshotScore(_ image: UIImage, threshold: Double) -> Double {
        return isImageScreenshot(image, threshold: threshold) ? 0.9 : 0.1
    }
    
    // Calculate confidence for blur detection based on distance from threshold
    private func calculateBlurConfidence(_ blurValue: Double, threshold: Double) -> Double {
        if blurValue < threshold {
            // More confident the further below threshold
            let distance = threshold - blurValue
            return min(1.0, 0.5 + distance * 2.0)
        } else {
            // Less confident the closer to threshold
            let distance = blurValue - threshold
            return max(0.0, 0.5 - distance * 2.0)
        }
    }
    
    // Calculate document score (high contrast rectangles, text patterns)
    private func calculateDocumentScore(_ image: UIImage, metadata: PhotoMetadata) -> Double {
        guard let cgImage = image.cgImage else { return 0.0 }
        
        let aspectRatio = Double(cgImage.width) / Double(cgImage.height)
        
        // Documents often have paper-like aspect ratios
        let isDocumentRatio = abs(aspectRatio - 1.414) < 0.2 || // A4 ratio
                             abs(aspectRatio - 1.29) < 0.2 ||   // Letter ratio
                             abs(aspectRatio - 0.707) < 0.2     // Portrait ratios
        
        let sharpnessScore = calculateSharpnessScore(image)
        let textPatterns = detectTextPatterns(image: cgImage)
        
        var score: Double = 0.0
        if isDocumentRatio { score += 0.3 }
        if sharpnessScore > 0.7 { score += 0.4 }
        if textPatterns { score += 0.4 }
        
        return score
    }
    
    // Calculate text-heavy score (high text density but not screenshot aspect ratio)
    private func calculateTextHeavyScore(_ image: UIImage, metadata: PhotoMetadata) -> Double {
        guard let cgImage = image.cgImage else { return 0.0 }
        
        let aspectRatio = Double(cgImage.width) / Double(cgImage.height)
        let isScreenRatio = isCommonScreenAspectRatio(aspectRatio)
        
        if isScreenRatio {
            return 0.0 // If it's screen ratio, it's likely a screenshot not text-heavy
        }
        
        let textPatterns = detectTextPatterns(image: cgImage)
        let highTextDensity = metadata.textDensity > 0.5
        
        var score: Double = 0.0
        if textPatterns { score += 0.5 }
        if highTextDensity { score += 0.4 }
        
        return score
    }
    
    // Calculate low light score (underexposed but potentially recoverable)
    private func calculateLowLightScore(_ image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return 0.0 }
        
        // Sample brightness across the image
        let width = cgImage.width
        let height = cgImage.height
        var brightnessSum: Double = 0.0
        let sampleCount = 100
        
        for i in 0..<sampleCount {
            let x = (i % 10) * (width / 10)
            let y = (i / 10) * (height / 10)
            let brightness = getPixelBrightness(image: cgImage, x: x, y: y)
            brightnessSum += brightness
        }
        
        let averageBrightness = brightnessSum / Double(sampleCount)
        
        // Low light if average brightness is low but image has some detail
        if averageBrightness < 0.3 {
            let sharpness = calculateSharpnessScore(image)
            // If it's dark but has some sharpness, it might be recoverable low light
            return sharpness > 0.2 ? min(1.0, (0.3 - averageBrightness) * 2.0 + sharpness) : 0.0
        }
        
        return 0.0
    }
    
    // Improved duplicate detection with similarity scoring
    private func findExistingDuplicateWithSimilarity(hash: String, dimensions: CGSize) async -> (PhotoScanResult, Double)? {
        return await MainActor.run {
            var bestMatch: (PhotoScanResult, Double)? = nil
            var bestSimilarity: Double = 0.0
            
            for result in self.results {
                if let existingHash = self.photoHashes[result.id] {
                    let similarity = calculateHashSimilarity(hash1: hash, hash2: existingHash)
                    
                    if similarity > bestSimilarity && similarity > 0.8 {
                        bestSimilarity = similarity
                        bestMatch = (result, similarity)
                    }
                }
                
                // Also check dimensions for size matches
                let sizeDiff = abs(result.metadata.dimensions.width - dimensions.width) + 
                              abs(result.metadata.dimensions.height - dimensions.height)
                if sizeDiff < 10 {
                    let dimensionSimilarity = 0.95 // High similarity for exact size match
                    if dimensionSimilarity > bestSimilarity {
                        bestSimilarity = dimensionSimilarity
                        bestMatch = (result, dimensionSimilarity)
                    }
                }
            }
            
            return bestMatch
        }
    }
    
    private func isImageScreenshot(_ image: UIImage, threshold: Double) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        
        // Analyze image characteristics typical of screenshots
        let aspectRatio = Double(cgImage.width) / Double(cgImage.height)
        let hasCommonScreenRatio = isCommonScreenAspectRatio(aspectRatio)
        
        // Check for sharp edges (screenshots typically have many sharp edges)
        let sharpnessScore = calculateSharpnessScore(image)
        
        // Check for UI elements patterns (simplified)
        let hasUIPatterns = detectUIPatterns(image)
        
        // More generous scoring for screenshot detection
        let screenshotScore = (hasCommonScreenRatio ? 0.4 : 0.1) + 
                             (sharpnessScore > 0.3 ? 0.4 : 0.0) + 
                             (hasUIPatterns ? 0.4 : 0.0)
        
        return screenshotScore > threshold
    }
    
    private func calculateQualityScore(_ image: UIImage, metadata: PhotoMetadata) -> Double {
        guard let cgImage = image.cgImage else { return 0.0 }
        
        var qualityScore: Double = 0.5 // Base score
        
        // Resolution quality
        let megapixels = Double(cgImage.width * cgImage.height) / 1_000_000.0
        let resolutionScore = min(1.0, megapixels / 12.0) // Normalize to 12MP
        qualityScore += resolutionScore * 0.3
        
        // Sharpness quality
        let sharpnessScore = calculateSharpnessScore(image)
        qualityScore += sharpnessScore * 0.4
        
        // Noise detection (simplified)
        let noiseScore = 1.0 - calculateNoiseLevel(image)
        qualityScore += noiseScore * 0.3
        
        return max(0.0, min(1.0, qualityScore))
    }
    
    private func calculateSharpnessScore(_ image: UIImage) -> Double {
        // Use the blur value (which is actually edge variance)
        // Higher variance = more edges = sharper image
        let edgeVariance = calculateBlurValue(image)
        return max(0.0, min(1.0, edgeVariance))
    }
    
    private func calculateNoiseLevel(_ image: UIImage) -> Double {
        // Simplified noise detection
        guard let cgImage = image.cgImage else { return 0.0 }
        
        // Sample a small region to check for noise patterns
        let _ = min(100, min(cgImage.width, cgImage.height))
        // For simplicity, return a default low noise level
        return 0.1
    }
    
    private func isCommonScreenAspectRatio(_ ratio: Double) -> Bool {
        let commonRatios: [Double] = [
            16.0/9.0,   // 16:9 (most common)
            4.0/3.0,    // 4:3 (older displays)
            3.0/2.0,    // 3:2 (some tablets)
            19.5/9.0,   // iPhone X series
            2.0/1.0     // 2:1 (some phones)
        ]
        
        return commonRatios.contains { abs($0 - ratio) < 0.1 || abs((1.0/$0) - ratio) < 0.1 }
    }
    
    private func detectUIPatterns(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        
        // Look for UI patterns typical in screenshots:
        // 1. High contrast rectangular regions (UI elements)
        // 2. Repeated horizontal/vertical lines (typical of UI layouts)
        // 3. Sharp edges with consistent spacing
        
        let width = cgImage.width
        let height = cgImage.height
        
        // Sample key areas where UI elements typically appear
        let topBarRegion = CGRect(x: 0, y: 0, width: width, height: height / 10) // Status bar area
        let bottomRegion = CGRect(x: 0, y: height * 9 / 10, width: width, height: height / 10) // Navigation bar area
        
        // Check for high contrast in typical UI regions
        let topContrast = calculateRegionContrast(image: cgImage, region: topBarRegion)
        let bottomContrast = calculateRegionContrast(image: cgImage, region: bottomRegion)
        
        // Screenshots often have high contrast UI elements
        let hasHighContrastUI = topContrast > 0.7 || bottomContrast > 0.7
        
        // Check for text-like patterns (high frequency content)
        let hasTextPatterns = detectTextPatterns(image: cgImage)
        
        return hasHighContrastUI || hasTextPatterns
    }
    
    private func calculateRegionContrast(image: CGImage, region: CGRect) -> Double {
        // Sample pixels in the region and calculate local contrast
        let samplePoints = 20
        var contrastSum: Double = 0
        
        for i in 0..<samplePoints {
            let x = Int(region.minX + (region.width * Double(i) / Double(samplePoints)))
            let y = Int(region.minY + region.height / 2)
            
            if x < image.width - 1 && y < image.height - 1 {
                // Get pixel values at adjacent points
                let pixel1 = getPixelBrightness(image: image, x: x, y: y)
                let pixel2 = getPixelBrightness(image: image, x: x + 1, y: y)
                
                // Calculate local contrast
                let contrast = abs(pixel1 - pixel2)
                contrastSum += contrast
            }
        }
        
        return contrastSum / Double(samplePoints)
    }
    
    private func detectTextPatterns(image: CGImage) -> Bool {
        // Look for high-frequency patterns typical of text
        // Text has alternating light/dark patterns at small scales
        
        let width = image.width
        let height = image.height
        let _ = min(width, height) / 4  // Sample size for future use
        
        // Sample center region where text commonly appears
        let centerX = width / 2
        let centerY = height / 2
        
        var highFrequencyCount = 0
        let totalSamples = 50
        
        for i in 0..<totalSamples {
            let x = centerX + (i % 10) - 5
            let y = centerY + (i / 10) - 5
            
            if x >= 1 && x < width - 1 && y >= 1 && y < height - 1 {
                // Check for rapid brightness changes (typical of text)
                let center = getPixelBrightness(image: image, x: x, y: y)
                let left = getPixelBrightness(image: image, x: x - 1, y: y)
                let right = getPixelBrightness(image: image, x: x + 1, y: y)
                
                let horizontalChange = abs(left - center) + abs(center - right)
                if horizontalChange > 0.3 { // Threshold for "high frequency"
                    highFrequencyCount += 1
                }
            }
        }
        
        return Double(highFrequencyCount) / Double(totalSamples) > 0.4 // 40% high-frequency content
    }
    
    private func getPixelBrightness(image: CGImage, x: Int, y: Int) -> Double {
        // Simplified brightness extraction - in production would use proper pixel data access
        // This is a placeholder that returns a reasonable approximation
        
        // Use a simple hash of position as proxy for actual pixel sampling
        // In real implementation, would extract actual pixel data
        let hash = (x * 31 + y) % 256
        return Double(hash) / 255.0
    }
    
    // Legacy methods for backward compatibility
    private func isImageBlurry(_ image: UIImage) -> Bool {
        let rules = LearningService.shared.getClassificationRules()
        return calculateBlurValue(image) < rules.blurThreshold
    }
    
    private func isImageLowQuality(_ image: UIImage) -> Bool {
        let rules = LearningService.shared.getClassificationRules()
        let metadata = PhotoMetadata(creationDate: Date(), location: nil, source: nil, 
                                   dimensions: image.size, isScreenshot: false, textDensity: 0.0)
        return calculateQualityScore(image, metadata: metadata) < rules.lowQualityThreshold
    }
    
    private func generateHash(from image: UIImage) -> String {
        // Simplified hash generation for exact matches
        return UUID().uuidString
    }
    
    // Generate perceptual hash for duplicate detection
    private func generatePerceptualHash(from image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return UUID().uuidString }
        
        // Simple perceptual hash based on 8x8 grayscale thumbnail
        let size = CGSize(width: 8, height: 8)
        UIGraphicsBeginImageContext(size)
        defer { UIGraphicsEndImageContext() }
        
        let context = UIGraphicsGetCurrentContext()
        context?.draw(cgImage, in: CGRect(origin: .zero, size: size))
        
        guard let resizedImage = UIGraphicsGetImageFromCurrentImageContext(),
              let resizedCGImage = resizedImage.cgImage else {
            return UUID().uuidString
        }
        
        // Extract grayscale values
        var pixels: [UInt8] = Array(repeating: 0, count: 64)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context2 = CGContext(data: &pixels, width: 8, height: 8, 
                                bitsPerComponent: 8, bytesPerRow: 8, 
                                space: colorSpace, bitmapInfo: 0)
        context2?.draw(resizedCGImage, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        
        // Calculate average (use Int to prevent overflow)
        let sum = pixels.reduce(0) { Int($0) + Int($1) }
        let average = UInt8(sum / 64)
        
        // Generate hash string based on above/below average
        return pixels.map { $0 > average ? "1" : "0" }.joined()
    }
    
    // Find existing photo with similar hash
    private func findExistingDuplicate(hash: String, dimensions: CGSize) async -> PhotoScanResult? {
        return await MainActor.run {
            for result in self.results {
                // Compare perceptual hashes (allow for some differences)
                if let existingHash = self.photoHashes[result.id] {
                    let similarity = calculateHashSimilarity(hash1: hash, hash2: existingHash)
                    if similarity > 0.9 { // 90% similarity threshold
                        return result
                    }
                }
                
                // Also check dimensions for exact size matches
                let sizeDiff = abs(result.metadata.dimensions.width - dimensions.width) + 
                              abs(result.metadata.dimensions.height - dimensions.height)
                if sizeDiff < 10 { // Very similar dimensions
                    return result
                }
            }
            return nil
        }
    }
    
    // Calculate similarity between two perceptual hashes
    private func calculateHashSimilarity(hash1: String, hash2: String) -> Double {
        guard hash1.count == hash2.count else { return 0.0 }
        
        let matches = zip(hash1, hash2).reduce(0) { count, pair in
            return count + (pair.0 == pair.1 ? 1 : 0)
        }
        
        return Double(matches) / Double(hash1.count)
    }
    
    // MARK: - Asset Processing Helper
    
    private func processAsset(asset: PHAsset, imageManager: PHImageManager, requestOptions: PHImageRequestOptions) async -> PhotoScanResult? {
        return await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 300, height: 300),
                contentMode: .aspectFill,
                options: requestOptions
            ) { image, _ in
                guard let image = image else {
                    continuation.resume(returning: nil)
                    return
                }
                
                Task { @MainActor in
                    let thumbnail = Image(uiImage: image)
                    let metadata = self.extractMetadata(from: asset)
                    
                    // During training mode, load ALL photos as unrated (no auto-classification)
                    // Classification happens only after user feedback or during full scan
                    let tags: Set<PhotoTag> = [.unrated]
                    
                    // Store perceptual hash for future duplicate detection
                    let perceptualHash = self.generatePerceptualHash(from: image)
                    self.photoHashes[asset.localIdentifier] = perceptualHash
                    
                    let result = PhotoScanResult(
                        id: asset.localIdentifier,
                        thumbnail: thumbnail,
                        tags: tags,
                        asset: asset,
                        exactHash: self.generateHash(from: image),
                        perceptualHash: 0, // Legacy field, hash stored in photoHashes dict
                        metadata: metadata
                    )
                    
                    continuation.resume(returning: result)
                }
            }
        }
    }
    
    // MARK: - Training Management
    
    func markPhotoAsRated(_ photoId: String) {
        ratedPhotos.insert(photoId)
        calculateTrainingConfidence()
    }
    
    func updatePhotoTags(assetId: String, newTags: Set<PhotoTag>) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        print("\(timestamp) 📝 updatePhotoTags called for \(assetId)")
        print("\(timestamp) 📝 New tags: \(newTags)")
        
        if let index = results.firstIndex(where: { $0.id == assetId }) {
            let oldTags = results[index].tags
            
            // Create new result with updated tags
            var updatedResult = results[index]
            updatedResult.tags = newTags
            results[index] = updatedResult
            
            markPhotoAsRated(assetId)
            
            print("\(timestamp) 📝 Photo updated at index \(index)")
            print("\(timestamp) 📝 Old tags: \(oldTags) -> New tags: \(newTags)")
            print("\(timestamp) 📝 Photo \(assetId) now has tags: \(results[index].tags)")
            
            // Force a refresh to ensure UI updates
            objectWillChange.send()
            
        } else {
            print("\(timestamp) ❌ Photo with ID \(assetId) not found in results")
        }
    }
    
    func calculateTrainingConfidence() {
        // Only count unrated photos for training (not auto-classified ones)
        let unratedPhotos = results.filter { $0.tags.contains(.unrated) }.count
        let userRatedCount = ratedPhotos.count  // Photos actually rated by user
        
        if unratedPhotos > 0 {
            trainingConfidence = Double(userRatedCount) / Double(unratedPhotos + userRatedCount)
            // Training complete when user has rated at least 10 photos (not based on percentage)
            isTrainingComplete = userRatedCount >= 10
        } else if userRatedCount > 0 {
            // All photos have been rated
            trainingConfidence = 1.0
            isTrainingComplete = true
        } else {
            trainingConfidence = 0.0
            isTrainingComplete = false
        }
        
        let timestamp = Self.timestampFormatter.string(from: Date())
        print("\(timestamp) 📊 Training confidence: \(Int(trainingConfidence * 100))% (\(userRatedCount) user-rated, \(unratedPhotos) remaining)")
        print("\(timestamp) 📊 Training complete: \(isTrainingComplete) (need 10 user ratings, have \(userRatedCount))")
    }
    
    func updateMLThresholds() {
        // Integration point with LearningService
        LearningService.shared.updateClassificationRules()
    }
    
    // MARK: - Duplicate Detection
    
    func findDuplicatesFor(assetId: String) -> [PhotoScanResult] {
        print("🔍 Finding duplicates for \(assetId)")
        guard let photo = results.first(where: { $0.id == assetId }) else { 
            print("  ❌ Photo not found in results")
            return [] 
        }
        
        // First check stored relationships
        if !photo.relatedPhotoIds.isEmpty {
            let related = results.filter { photo.relatedPhotoIds.contains($0.id) }
            print("  ✅ Found \(related.count) related photos from stored IDs: \(photo.relatedPhotoIds)")
            return related
        }
        
        // Fall back to similarity check
        let duplicates = results.filter { otherPhoto in
            otherPhoto.id != assetId && areSimilarImages(photo, otherPhoto)
        }
        print("  📊 Found \(duplicates.count) similar photos by comparison")
        return duplicates
    }
    
    func isPhotoRated(_ assetId: String) -> Bool {
        return ratedPhotos.contains(assetId)
    }
    
    // Generate predictions for training (separate from confirmed tags)
    func generatePredictionForPhoto(_ photoId: String) async -> Set<PhotoTag> {
        guard let index = results.firstIndex(where: { $0.id == photoId }) else {
            return []
        }
        
        let photo = results[index]
        
        // Use the actual PHAsset to get a fresh image for classification
        let imageManager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.isSynchronous = false
        
        return await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: photo.asset,
                targetSize: CGSize(width: 300, height: 300),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                guard let image = image else {
                    continuation.resume(returning: [])
                    return
                }
                
                Task { @MainActor in
                    // Run classification to get predictions with confidence
                    let classificationResult = await self.classifyPhoto(image: image, metadata: photo.metadata)
                    
                    // Store predictions in the photo (but keep .unrated as confirmed tag)
                    var updatedPhoto = self.results[index]
                    updatedPhoto.predictedTags = classificationResult.tags.subtracting([.unrated])
                    updatedPhoto.tagConfidence = classificationResult.confidence
                    updatedPhoto.relatedPhotoIds = classificationResult.relatedIds
                    self.results[index] = updatedPhoto
                    
                    // Update the related photos to include bidirectional relationships
                    for relatedId in classificationResult.relatedIds {
                        if let relatedIndex = self.results.firstIndex(where: { $0.id == relatedId }) {
                            var relatedPhoto = self.results[relatedIndex]
                            if !relatedPhoto.relatedPhotoIds.contains(photoId) {
                                relatedPhoto.relatedPhotoIds.append(photoId)
                                self.results[relatedIndex] = relatedPhoto
                                print("  🔗 Added bidirectional relationship: \(relatedId) ↔ \(photoId)")
                            }
                        }
                    }
                    
                    let timestamp = Self.timestampFormatter.string(from: Date())
                    print("\(timestamp) 🔮 Generated predictions for \(photoId): \(classificationResult.tags.subtracting([.unrated]))")
                    
                    self.objectWillChange.send()
                    continuation.resume(returning: classificationResult.tags.subtracting([.unrated]))
                }
            }
        }
    }
    
    // Classify a photo after training (when user gives feedback)
    func classifyPhotoPostTraining(_ photoId: String) async -> Set<PhotoTag> {
        guard let index = results.firstIndex(where: { $0.id == photoId }) else {
            return [.unrated]
        }
        
        let photo = results[index]
        // Get the actual UIImage from the thumbnail for classification
        guard let uiImage = extractUIImage(from: photo.thumbnail) else {
            return [.unrated]
        }
        
        // Now perform the actual classification
        let classificationResult = await classifyPhoto(image: uiImage, metadata: photo.metadata)
        
        // Update the photo with classified tags
        var updatedResult = photo
        updatedResult.tags = classificationResult.tags
        updatedResult.tagConfidence = classificationResult.confidence
        updatedResult.relatedPhotoIds = classificationResult.relatedIds
        results[index] = updatedResult
        
        objectWillChange.send()
        return classificationResult.tags
    }
    
    // Helper to extract UIImage from SwiftUI Image (simplified)
    private func extractUIImage(from swiftUIImage: Image) -> UIImage? {
        // This is a simplified approach - in production you'd store the original UIImage
        // For now, we'll use a placeholder approach
        return nil // Will need to be implemented properly
    }
    
    // Clean up unrated tags for photos that were rated during training
    func finalizeTrainingSession() {
        let timestamp = Self.timestampFormatter.string(from: Date())
        print("\(timestamp) 🎯 Finalizing training session - removing unrated tags from rated photos")
        
        for photoId in ratedPhotos {
            if let index = results.firstIndex(where: { $0.id == photoId }) {
                let currentTags = results[index].tags
                if currentTags.contains(.unrated) {
                    let finalTags = currentTags.subtracting([.unrated])
                    var updatedResult = results[index]
                    updatedResult.tags = finalTags
                    results[index] = updatedResult
                    print("\(timestamp) 🎯 Removed .unrated from photo \(photoId)")
                }
            }
        }
        
        // Force UI refresh
        objectWillChange.send()
        print("\(timestamp) 🎯 Training session finalized")
    }
    
    // MARK: - Advanced Duplicate Detection
    
    private func areSimilarImages(_ photo1: PhotoScanResult, _ photo2: PhotoScanResult) -> Bool {
        // Simplified similarity check - in production, use perceptual hashing
        let _ = LearningService.shared.getClassificationRules()
        
        // Check if dimensions are very similar
        let size1 = photo1.metadata.dimensions
        let size2 = photo2.metadata.dimensions
        
        let aspectRatio1 = size1.width / size1.height
        let aspectRatio2 = size2.width / size2.height
        
        let aspectRatioSimilarity = abs(aspectRatio1 - aspectRatio2) < 0.1
        let sizeSimilarity = abs(size1.width - size2.width) < 100 && abs(size1.height - size2.height) < 100
        
        return aspectRatioSimilarity && sizeSimilarity
    }
    
    // MARK: - Batch Processing with Learning Integration
    
    func processBatchWithLearning() async {
        guard !isScanning else { return }
        
        isScanning = true
        
        // Process photos in batches and apply learning
        let unprocessedPhotos = results.filter { !ratedPhotos.contains($0.id) }
        
        for batch in unprocessedPhotos.chunked(into: 10) {
            await processBatch(batch)
            
            // Update thresholds after each batch if we have enough feedback
            let feedbackCount = LearningService.shared.getAllFeedback().count
            if feedbackCount > 0 && feedbackCount % 10 == 0 {
                LearningService.shared.updateClassificationRules()
                print("🎯 Updated ML thresholds after processing batch (total feedback: \(feedbackCount))")
            }
            
            // Brief pause to prevent overwhelming the system
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
        
        await MainActor.run {
            self.isScanning = false
            self.calculateTrainingConfidence()
        }
    }
    
    private func processBatch(_ batch: [PhotoScanResult]) async {
        for _ in batch {
            // Re-classify the photo with updated thresholds
            // This would be called when processing new photos or re-evaluating existing ones
            await MainActor.run {
                // Update UI if needed
            }
        }
    }
}

// MARK: - Array Extension for Batch Processing

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

