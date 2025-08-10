import SwiftUI
import Photos

// MARK: - Debug Logging Utility
struct DebugLogger {
    static func log(_ message: String, category: String = "GENERAL") {
        let timestamp = DateFormatter.debugTimestamp.string(from: Date())
        print("[\(timestamp)] 🐞 \(category): \(message)")
    }
    
    static func logUserAction(_ action: String, details: String = "") {
        let timestamp = DateFormatter.debugTimestamp.string(from: Date())
        print("[\(timestamp)] 👆 USER_ACTION: \(action) \(details)")
    }
    
    static func logImageState(_ message: String, imageId: String) {
        let timestamp = DateFormatter.debugTimestamp.string(from: Date())
        print("[\(timestamp)] 🖼️ IMAGE_STATE: \(message) [ID: \(imageId.prefix(8))...]")
    }
}

extension DateFormatter {
    static let debugTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
import CryptoKit
import CoreImage
import Accelerate
import UIKit
import CoreLocation
import Vision

// MARK: - Learning Service Data Structures
struct FeedbackEntry: Codable {
    let id: String
    let photoId: String
    let timestamp: Date
    let predictedTags: Set<PhotoTag>
    let actualTags: Set<PhotoTag>
    let isCorrect: Bool
    let metadata: PhotoMetadata
    
    enum CodingKeys: String, CodingKey {
        case id, photoId, timestamp, predictedTags, actualTags, isCorrect, metadata
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        photoId = try container.decode(String.self, forKey: .photoId)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        
        // Handle Set<PhotoTag> decoding
        let predictedArray = try container.decode([String].self, forKey: .predictedTags)
        predictedTags = Set(predictedArray.compactMap { PhotoTag(rawValue: $0) })
        
        let actualArray = try container.decode([String].self, forKey: .actualTags)
        actualTags = Set(actualArray.compactMap { PhotoTag(rawValue: $0) })
        
        isCorrect = try container.decode(Bool.self, forKey: .isCorrect)
        metadata = try container.decode(PhotoMetadata.self, forKey: .metadata)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(photoId, forKey: .photoId)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(Array(predictedTags.map { $0.rawValue }), forKey: .predictedTags)
        try container.encode(Array(actualTags.map { $0.rawValue }), forKey: .actualTags)
        try container.encode(isCorrect, forKey: .isCorrect)
        try container.encode(metadata, forKey: .metadata)
    }
}

// MARK: - Training Data Export Structure
struct TrainingDataExport: Codable {
    let version: String
    let exportDate: Date
    let feedbackEntries: [FeedbackEntry]
    let classificationRules: ClassificationRules
    let trainingStats: TrainingStats
    
    struct TrainingStats: Codable {
        let totalFeedback: Int
        let correctPredictions: Int
        let incorrectPredictions: Int
        let accuracy: Double
        let lastUpdated: Date
    }
}

// MARK: - Learning Service
class LearningService: ObservableObject {
    static let shared = LearningService()
    
    private let userDefaults = UserDefaults.standard
    private let feedbackKey = "ml_training_feedback"
    private let rulesKey = "classification_rules"
    
    // MARK: - Data Structures
    struct ClassificationRules: Codable {
        var blurThreshold: Double
        var textDensityThreshold: Double
        var lowQualityThreshold: Double
        var duplicateHashThreshold: Double
        var confidenceThreshold: Double
        var lastUpdated: Date
        
        static let `default` = ClassificationRules(
            blurThreshold: 0.05,
            textDensityThreshold: 0.3,
            lowQualityThreshold: 0.4,
            duplicateHashThreshold: 0.95,
            confidenceThreshold: 0.7,
            lastUpdated: Date()
        )
    }
    
    private init() {}
    
    // MARK: - Core Methods
    func recordFeedback(
        for photoId: String,
        actualTags: Set<PhotoTag>,
        predictedTags: Set<PhotoTag>,
        isCorrect: Bool,
        metadata: PhotoMetadata
    ) {
        let entry = FeedbackEntry(
            id: UUID().uuidString,
            photoId: photoId,
            timestamp: Date(),
            predictedTags: predictedTags,
            actualTags: actualTags,
            isCorrect: isCorrect,
            metadata: metadata
        )
        
        var feedback = getAllFeedback()
        feedback.append(entry)
        saveFeedback(feedback)
        
        print("📚 Learning: Recorded feedback for \(photoId.prefix(8)) - Correct: \(isCorrect)")
        
        // Update classification rules based on new feedback
        updateClassificationRules()
        
        // Notify observers
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }
    
    func getAllFeedback() -> [FeedbackEntry] {
        guard let data = userDefaults.data(forKey: feedbackKey),
              let feedback = try? JSONDecoder().decode([FeedbackEntry].self, from: data) else {
            return []
        }
        return feedback
    }
    
    func getClassificationRules() -> ClassificationRules {
        guard let data = userDefaults.data(forKey: rulesKey),
              let rules = try? JSONDecoder().decode(ClassificationRules.self, from: data) else {
            return .default
        }
        return rules
    }
    
    func updateClassificationRules() {
        let feedback = getAllFeedback()
        guard !feedback.isEmpty else { return }
        
        var rules = getClassificationRules()
        
        // Adaptive threshold learning based on user corrections
        let recentFeedback = feedback.suffix(50) // Use last 50 feedback entries
        
        // Blur threshold adaptation
        let blurCorrections = recentFeedback.filter { entry in
            (entry.predictedTags.contains(.blurry) && !entry.actualTags.contains(.blurry)) ||
            (!entry.predictedTags.contains(.blurry) && entry.actualTags.contains(.blurry))
        }
        
        if blurCorrections.count > 5 {
            // If we're missing blur detection, lower threshold
            let missedBlur = blurCorrections.filter { !$0.predictedTags.contains(.blurry) && $0.actualTags.contains(.blurry) }
            if missedBlur.count > blurCorrections.count / 2 {
                rules.blurThreshold = max(0.01, rules.blurThreshold * 0.9)
                print("📚 Learning: Lowered blur threshold to \(rules.blurThreshold)")
            }
            // If we're over-detecting blur, raise threshold
            else {
                rules.blurThreshold = min(0.15, rules.blurThreshold * 1.1)
                print("📚 Learning: Raised blur threshold to \(rules.blurThreshold)")
            }
        }
        
        // Text density threshold for screenshots
        let screenshotCorrections = recentFeedback.filter { entry in
            (entry.predictedTags.contains(.screenshot) && !entry.actualTags.contains(.screenshot)) ||
            (!entry.predictedTags.contains(.screenshot) && entry.actualTags.contains(.screenshot))
        }
        
        if screenshotCorrections.count > 5 {
            let missedScreenshots = screenshotCorrections.filter { !$0.predictedTags.contains(.screenshot) && $0.actualTags.contains(.screenshot) }
            if missedScreenshots.count > screenshotCorrections.count / 2 {
                rules.textDensityThreshold = max(0.1, rules.textDensityThreshold * 0.85)
                print("📚 Learning: Lowered text density threshold to \(rules.textDensityThreshold)")
            } else {
                rules.textDensityThreshold = min(0.6, rules.textDensityThreshold * 1.15)
                print("📚 Learning: Raised text density threshold to \(rules.textDensityThreshold)")
            }
        }
        
        // Low quality threshold adaptation
        let qualityCorrections = recentFeedback.filter { entry in
            (entry.predictedTags.contains(.lowQuality) && !entry.actualTags.contains(.lowQuality)) ||
            (!entry.predictedTags.contains(.lowQuality) && entry.actualTags.contains(.lowQuality))
        }
        
        if qualityCorrections.count > 3 {
            let missedLowQuality = qualityCorrections.filter { !$0.predictedTags.contains(.lowQuality) && $0.actualTags.contains(.lowQuality) }
            if missedLowQuality.count > qualityCorrections.count / 2 {
                rules.lowQualityThreshold = max(0.2, rules.lowQualityThreshold * 0.9)
                print("📚 Learning: Lowered quality threshold to \(rules.lowQualityThreshold)")
            } else {
                rules.lowQualityThreshold = min(0.7, rules.lowQualityThreshold * 1.1)
                print("📚 Learning: Raised quality threshold to \(rules.lowQualityThreshold)")
            }
        }
        
        rules.lastUpdated = Date()
        saveClassificationRules(rules)
    }
    
    // MARK: - Import/Export Methods
    func importFeedback(_ feedback: [FeedbackEntry]) {
        let existing = getAllFeedback()
        let combined = existing + feedback
        // Remove duplicates based on photoId and timestamp
        let unique = Array(Set(combined.map { $0.id })).compactMap { id in
            combined.first { $0.id == id }
        }
        saveFeedback(unique)
        updateClassificationRules()
        print("📚 Learning: Imported \(feedback.count) feedback entries")
    }
    
    func importRules(_ rules: ClassificationRules) {
        saveClassificationRules(rules)
        print("📚 Learning: Imported classification rules")
    }
    
    func exportTrainingData() -> TrainingDataExport {
        let feedback = getAllFeedback()
        let rules = getClassificationRules()
        
        let stats = TrainingDataExport.TrainingStats(
            totalFeedback: feedback.count,
            correctPredictions: feedback.filter { $0.isCorrect }.count,
            incorrectPredictions: feedback.filter { !$0.isCorrect }.count,
            accuracy: feedback.isEmpty ? 0.0 : Double(feedback.filter { $0.isCorrect }.count) / Double(feedback.count),
            lastUpdated: Date()
        )
        
        return TrainingDataExport(
            version: "1.0",
            exportDate: Date(),
            feedbackEntries: feedback,
            classificationRules: rules,
            trainingStats: stats
        )
    }
    
    func clearAllFeedback() {
        userDefaults.removeObject(forKey: feedbackKey)
        userDefaults.removeObject(forKey: rulesKey)
        print("📚 Learning: Cleared all feedback and rules")
    }
    
    // MARK: - Private Helper Methods
    private func saveFeedback(_ feedback: [FeedbackEntry]) {
        do {
            let data = try JSONEncoder().encode(feedback)
            userDefaults.set(data, forKey: feedbackKey)
        } catch {
            print("❌ Failed to save feedback: \(error)")
        }
    }
    
    private func saveClassificationRules(_ rules: ClassificationRules) {
        do {
            let data = try JSONEncoder().encode(rules)
            userDefaults.set(data, forKey: rulesKey)
        } catch {
            print("❌ Failed to save classification rules: \(error)")
        }
    }
}

struct ContentView: View {
    @StateObject private var quickScanService = QuickScanService()
    
    var body: some View {
        TabView {
            ModernDashboardView(quickScanService: quickScanService)
                .tabItem {
                    Label("Dashboard", systemImage: "house")
                }
            
            ModernCleanupView(quickScanService: quickScanService)
                .tabItem {
                    Label("Cleanup", systemImage: "trash")
                }
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .onAppear {
            // Load persisted results on app start
            quickScanService.loadPersistedResults()
        }
    }
}

struct DashboardView: View {
    @ObservedObject var quickScanService: QuickScanService
    
    var body: some View {
        let _ = print("🏠 DashboardView body computed - isScanning = \(quickScanService.isScanning)")
        let _ = print("🏠 DashboardView body computed - results.count = \(quickScanService.results.count)")
        
        return NavigationView {
            VStack(spacing: 20) {
                if quickScanService.isScanning {
                    VStack(spacing: 12) {
                        ProgressView(value: Double(quickScanService.currentlyProcessed), total: Double(quickScanService.totalToProcess))
                            .progressViewStyle(LinearProgressViewStyle())
                            .scaleEffect(1.2)
                        
                        Text("\(quickScanService.currentlyProcessed)/\(quickScanService.totalToProcess)")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.blue)
                        
                        Text("Scanning photos...")
                            .font(.headline)
                        Text("Analyzing for duplicates, blur, and exposure...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .onAppear {
                        print("🏠 DashboardView: Showing scanning UI")
                    }
                } else if !quickScanService.results.isEmpty {
                    VStack(spacing: 16) {
                        // Scan complete banner
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                            Text("Scan Complete!")
                                .font(.headline)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .padding()
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(12)
                        
                        // Training status banner
                        if quickScanService.isTrainingMode {
                            VStack(spacing: 8) {
                                HStack {
                                    Image(systemName: quickScanService.isTrainingComplete ? "brain.head.profile" : "brain")
                                        .foregroundColor(quickScanService.isTrainingComplete ? .green : .blue)
                                        .font(.title2)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(quickScanService.isTrainingComplete ? "Training Complete!" : "Training Mode")
                                            .font(.headline)
                                            .fontWeight(.semibold)
                                        
                                        Text(quickScanService.isTrainingComplete ? 
                                             "Ready for full scan" : 
                                             "Confidence: \(String(format: "%.1f", quickScanService.trainingConfidence * 100))%")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    if quickScanService.isTrainingComplete {
                                        Button("Start Full Scan") {
                                            quickScanService.startFullScan()
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                }
                                
                                if !quickScanService.isTrainingComplete {
                                    ProgressView(value: quickScanService.trainingConfidence, total: 0.99)
                                        .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                                        .scaleEffect(1.0)
                                }
                            }
                            .padding()
                            .background(quickScanService.isTrainingComplete ? 
                                       Color.green.opacity(0.1) : Color.blue.opacity(0.1))
                            .cornerRadius(12)
                        }
                        
                        StatisticsView(quickScanService: quickScanService)
                        
                        // Show some actual results with better preview
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Recent Analysis:")
                                    .font(.headline)
                                Spacer()
                                NavigationLink("View All", destination: CleanupView(quickScanService: quickScanService))
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 12) {
                                    ForEach(quickScanService.results.prefix(6)) { result in
                                        DashboardPhotoPreview(result: result, quickScanService: quickScanService)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    .onAppear {
                        print("🏠 DashboardView: Showing results with \(quickScanService.results.count) photos")
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        
                        Text("Ready to Scan")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Tap the button below to analyze your photos for duplicates, blurry images, and low quality photos.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                
                Spacer()
                
                VStack(spacing: 12) {
                    if quickScanService.isTrainingMode && !quickScanService.results.isEmpty {
                        Button("🔄 Reset Training Data") {
                            quickScanService.resetTrainingCompletely()
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    }
                    
                    Button(quickScanService.results.isEmpty ? "Start Training" : 
                           (quickScanService.isTrainingComplete ? "Start Full Scan" : "Continue Training")) {
                        print("🔴 BUTTON PRESSED - TRAINING MODE: \(quickScanService.isTrainingMode)")
                        print("🔍 DEBUG: Button pressed - Current scanOffset: \(quickScanService.currentScanOffset)")
                        
                        if quickScanService.isTrainingComplete {
                            quickScanService.startFullScan()
                            return
                        }
                        
                        // Set scanning state immediately for instant UI feedback  
                        quickScanService.isScanning = true
                        // Don't clear results anymore - that's handled in scanAllAssets()
                        quickScanService.currentlyProcessed = 0
                        quickScanService.totalToProcess = 10
                        print("🔴 Set isScanning = true immediately for UI feedback")
                    
                    // Check both read and readWrite permissions
                    let readStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                    print("🔴 Permission status: \(readStatus.rawValue)")
                    
                    // Try with permissions
                    if readStatus == .authorized || readStatus == .limited {
                        print("🔴 Have permissions, starting REAL scan")
                        Task { @MainActor in
                            print("🔴 About to call scanAllAssets()")
                            quickScanService.scanAllAssets()
                            print("🔴 Called scanAllAssets()")
                        }
                    } else {
                        print("🔴 Need permissions, requesting access...")
                        PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                            print("🔴 New permission status: \(newStatus.rawValue)")
                            if newStatus == .authorized || newStatus == .limited {
                                Task { @MainActor in
                                    print("🔴 Got permissions, starting REAL scan")
                                    quickScanService.scanAllAssets()
                                }
                            } else {
                                // Reset scanning state if permission denied
                                Task { @MainActor in
                                    quickScanService.isScanning = false
                                }
                            }
                        }
                    }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(quickScanService.isScanning)
                }
            }
            .padding()
            .navigationTitle("Echo")
        }
    }
}

struct DashboardPhotoPreview: View {
    let result: PhotoScanResult
    @State private var showingDetail = false
    @ObservedObject var quickScanService: QuickScanService
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                result.thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipped()
                    .cornerRadius(8)
                    .onTapGesture {
                        showingDetail = true
                    }
                
                // Quality indicator
                if !result.tags.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(2)
                        .background(Color.red)
                        .clipShape(Circle())
                        .offset(x: 4, y: -4)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(2)
                        .background(Color.green)
                        .clipShape(Circle())
                        .offset(x: 4, y: -4)
                }
            }
            
            if !result.tags.isEmpty {
                Text(result.tags.first?.rawValue.capitalized ?? "Issue")
                    .font(.caption2)
                    .foregroundColor(.red)
                    .fontWeight(.medium)
            } else {
                Text("Good")
                    .font(.caption2)
                    .foregroundColor(.green)
                    .fontWeight(.medium)
            }
        }
        .sheet(isPresented: $showingDetail) {
            if let index = quickScanService.results.firstIndex(where: { $0.id == result.id }) {
                PhotoDetailView(results: quickScanService.results, initialIndex: index, quickScanService: quickScanService)
            }
        }
    }
}

struct StatisticsView: View {
    @ObservedObject var quickScanService: QuickScanService
    
    private var results: [PhotoScanResult] {
        quickScanService.results
    }
    
    private var duplicateCount: Int {
        results.filter { $0.tags.contains(.duplicate) }.count
    }
    
    private var blurryCount: Int {
        results.filter { $0.tags.contains(.blurry) }.count
    }
    
    private var lowQualityCount: Int {
        results.filter { $0.tags.contains(.lowQuality) }.count
    }
    
    private var screenshotCount: Int {
        results.filter { $0.tags.contains(.screenshot) }.count
    }
    
    var body: some View {
        let _ = print("🔍 StatisticsView body computed - results.count = \(results.count)")
        let _ = print("🔍 StatisticsView body computed - quickScanService.results.count = \(quickScanService.results.count)")
        let _ = print("🔍 StatisticsView body computed - isScanning = \(quickScanService.isScanning)")
        
        return VStack(spacing: 16) {
            HStack {
                StatCard(title: "Total Photos", count: results.count, color: .blue, icon: "photo")
                StatCard(title: "Duplicates", count: duplicateCount, color: .orange, icon: "doc.on.doc")
            }
            
            HStack {
                StatCard(title: "Blurry", count: blurryCount, color: .purple, icon: "camera.filters")
                StatCard(title: "Low Quality", count: lowQualityCount, color: .red, icon: "exclamationmark.triangle")
            }
            
            HStack {
                StatCard(title: "Screenshots", count: screenshotCount, color: .blue, icon: "rectangle.on.rectangle")
                StatCard(title: "Good Quality", count: results.count - duplicateCount - blurryCount - lowQualityCount - screenshotCount, color: .green, icon: "checkmark.circle")
            }
        }
        .onAppear {
            print("📊 StatisticsView onAppear with \(results.count) results")
        }
        .onChange(of: results.count) { newValue in
            print("📊 StatisticsView onChange: results count changed to \(newValue)")
        }
        .onChange(of: quickScanService.results.count) { newValue in
            print("📊 StatisticsView onChange: quickScanService.results.count changed to \(newValue)")
        }
        .onChange(of: quickScanService.isScanning) { newValue in
            print("📊 StatisticsView onChange: isScanning changed to \(newValue)")
        }
        .onChange(of: quickScanService.refreshTrigger) { newValue in
            print("📊 StatisticsView onChange: refreshTrigger changed to \(newValue)")
        }
    }
}


struct CleanupView: View {
    @ObservedObject var quickScanService: QuickScanService
    @State private var selectedFilter: PhotoFilter = .all
    
    enum PhotoFilter: String, CaseIterable {
        case all = "All Photos"
        case blurry = "Blurry"
        case lowQuality = "Low Quality"
        case duplicate = "Duplicates"
        case screenshot = "Screenshots"
        case good = "Good Quality"
    }
    
    private var filteredResults: [PhotoScanResult] {
        switch selectedFilter {
        case .all:
            return quickScanService.results
        case .blurry:
            return quickScanService.results.filter { $0.tags.contains(.blurry) }
        case .lowQuality:
            return quickScanService.results.filter { $0.tags.contains(.lowQuality) }
        case .duplicate:
            return quickScanService.results.filter { $0.tags.contains(.duplicate) }
        case .screenshot:
            return quickScanService.results.filter { $0.tags.contains(.screenshot) }
        case .good:
            return quickScanService.results.filter { $0.tags.isEmpty }
        }
    }
    
    var body: some View {
        NavigationView {
            VStack {
                if quickScanService.results.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "photo.badge.checkmark")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        
                        Text("No Scan Results")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Run a scan from the Dashboard tab to see photos that need cleanup.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        // Segmented control for filtering
                        Picker("Filter", selection: $selectedFilter) {
                            ForEach(PhotoFilter.allCases, id: \.self) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding()
                        
                        // Results count
                        HStack {
                            Text("\(filteredResults.count) photos")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        
                        // Photos grid
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                                ForEach(filteredResults) { result in
                                    PhotoGridItem(result: result, filteredResults: filteredResults, quickScanService: quickScanService)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Cleanup")
        }
    }
}

struct PhotoGridItem: View {
    let result: PhotoScanResult
    let filteredResults: [PhotoScanResult]
    @ObservedObject var quickScanService: QuickScanService
    @State private var showingDetail = false
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            result.thumbnail
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 120, height: 120)
                .clipped()
                .onTapGesture {
                    showingDetail = true
                }
            
            // Quality badge
            if !result.tags.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(result.tags), id: \.self) { tag in
                        Text(tag.rawValue.capitalized)
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(backgroundColorForTag(tag))
                            .cornerRadius(4)
                    }
                }
                .padding(4)
            } else {
                Text("✓")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(4)
                    .background(Color.green)
                    .clipShape(Circle())
                    .padding(4)
            }
        }
        .sheet(isPresented: $showingDetail) {
            if let index = filteredResults.firstIndex(where: { $0.id == result.id }) {
                PhotoDetailView(results: filteredResults, initialIndex: index, quickScanService: quickScanService)
            }
        }
    }
    
    private func backgroundColorForTag(_ tag: PhotoTag) -> Color {
        switch tag {
        case .blurry:
            return .purple
        case .lowQuality:
            return .red
        case .duplicate:
            return .orange
        case .screenshot:
            return .blue
        case .unrated:
            return .gray
        }
    }
}

struct PhotoDetailView: View {
    let results: [PhotoScanResult]
    let initialIndex: Int
    @ObservedObject var quickScanService: QuickScanService
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var fullSizeImage: Image?
    @StateObject private var imageLoader = FullSizeImageLoader()
    @StateObject private var learningService = LearningService.shared
    
    init(results: [PhotoScanResult], initialIndex: Int, quickScanService: QuickScanService) {
        self.results = results
        self.initialIndex = initialIndex
        self.quickScanService = quickScanService
        self._currentIndex = State(initialValue: initialIndex)
    }
    
    private var currentResult: PhotoScanResult {
        results[currentIndex]
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if let fullSizeImage = fullSizeImage {
                    fullSizeImage
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipped()
                } else {
                    // Show thumbnail while loading full size
                    currentResult.thumbnail
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipped()
                        .overlay(
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)
                        )
                }
                
                // Navigation indicators
                HStack {
                    if currentIndex > 0 {
                        VStack {
                            Spacer()
                            Button(action: { navigateToPhoto(currentIndex - 1) }) {
                                Image(systemName: "chevron.left.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.white.opacity(0.8))
                                    .background(Color.black.opacity(0.5))
                                    .clipShape(Circle())
                            }
                            Spacer()
                        }
                        .padding(.leading)
                    }
                    
                    Spacer()
                    
                    if currentIndex < results.count - 1 {
                        VStack {
                            Spacer()
                            Button(action: { navigateToPhoto(currentIndex + 1) }) {
                                Image(systemName: "chevron.right.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.white.opacity(0.8))
                                    .background(Color.black.opacity(0.5))
                                    .clipShape(Circle())
                            }
                            Spacer()
                        }
                        .padding(.trailing)
                    }
                }
            }
            .gesture(
                DragGesture()
                    .onEnded { value in
                        let threshold: CGFloat = 50
                        if value.translation.width > threshold && currentIndex > 0 {
                            // Swipe right - go to previous
                            navigateToPhoto(currentIndex - 1)
                        } else if value.translation.width < -threshold && currentIndex < results.count - 1 {
                            // Swipe left - go to next
                            navigateToPhoto(currentIndex + 1)
                        }
                    }
            )
            .navigationTitle("Photo Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 8) {
                        // Photo counter
                        Text("\(currentIndex + 1) of \(results.count)")
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                        
                        VStack(alignment: .trailing, spacing: 4) {
                            if !currentResult.tags.isEmpty {
                                ForEach(Array(currentResult.tags), id: \.self) { tag in
                                    Text(tag.rawValue.capitalized)
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(backgroundColorForTag(tag))
                                        .cornerRadius(6)
                                }
                            } else {
                                Text("Good Quality")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.green)
                                    .cornerRadius(6)
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    // Show duplicate viewer if this photo is marked as duplicate
                    if currentResult.tags.contains(.duplicate) {
                        DuplicateViewerInterface(result: currentResult, quickScanService: quickScanService)
                            .padding(.horizontal)
                    }
                    
                    FeedbackInterface(result: currentResult, quickScanService: quickScanService)
                        .padding()
                        .background(.ultraThinMaterial)
                        .id(currentResult.id) // Force recreation when result changes
                }
            }
        }
        .onAppear {
            loadCurrentImage()
        }
        .onChange(of: currentIndex) { _ in
            loadCurrentImage()
        }
    }
    
    private func navigateToPhoto(_ index: Int) {
        withAnimation(.easeInOut(duration: 0.3)) {
            currentIndex = index
            fullSizeImage = nil // Reset image to show loading
        }
    }
    
    private func loadCurrentImage() {
        imageLoader.loadFullSizeImage(for: currentResult.asset) { image in
            DispatchQueue.main.async {
                self.fullSizeImage = image
            }
        }
    }
    
    private func backgroundColorForTag(_ tag: PhotoTag) -> Color {
        switch tag {
        case .blurry:
            return .purple
        case .lowQuality:
            return .red
        case .duplicate:
            return .orange
        case .screenshot:
            return .blue
        case .unrated:
            return .gray
        }
    }
}

class FullSizeImageLoader: ObservableObject {
    private let imageManager = PHCachingImageManager()
    
    func loadFullSizeImage(for asset: PHAsset, completion: @escaping (Image?) -> Void) {
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true
        
        let targetSize = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
        
        imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options) { uiImage, _ in
            let image = uiImage != nil ? Image(uiImage: uiImage!) : nil
            completion(image)
        }
    }
}

struct SettingsView: View {
    @StateObject private var quickScanService = QuickScanService()
    @State private var showingExportSheet = false
    @State private var showingImportSheet = false
    @State private var exportedData = ""
    @State private var importData = ""
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationView {
            List {
                Section("Training Data Backup") {
                    Button("Export Training Data") {
                        if let data = quickScanService.exportTrainingData() {
                            exportedData = data
                            showingExportSheet = true
                        } else {
                            alertMessage = "Failed to export training data"
                            showingAlert = true
                        }
                    }
                    
                    Button("Import Training Data") {
                        showingImportSheet = true
                    }
                    
                    Button("Validate Duplicate Tags") {
                        quickScanService.validateDuplicateTags()
                    }
                    .foregroundColor(.blue)
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Training Progress")
                        Spacer()
                        Text("\(String(format: "%.1f", quickScanService.trainingConfidence * 100))%")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingExportSheet) {
                NavigationView {
                    VStack(spacing: 16) {
                        Text("Training Data Export")
                            .font(.headline)
                            .padding()
                        
                        Text("Copy this data to backup your training progress:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        ScrollView {
                            Text(exportedData)
                                .font(.system(.caption, design: .monospaced))
                                .padding()
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(8)
                        }
                        .padding()
                        
                        Button("Copy to Clipboard") {
                            UIPasteboard.general.string = exportedData
                            alertMessage = "Training data copied to clipboard!"
                            showingAlert = true
                            showingExportSheet = false
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Spacer()
                    }
                    .navigationTitle("Export")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                showingExportSheet = false
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingImportSheet) {
                NavigationView {
                    VStack(spacing: 16) {
                        Text("Training Data Import")
                            .font(.headline)
                            .padding()
                        
                        Text("Paste your exported training data below:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        TextEditor(text: $importData)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(8)
                            .frame(minHeight: 200)
                            .padding()
                        
                        Button("Import Training Data") {
                            if quickScanService.importTrainingData(importData) {
                                alertMessage = "Training data imported successfully!"
                                showingImportSheet = false
                            } else {
                                alertMessage = "Failed to import training data. Please check the format."
                            }
                            showingAlert = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(importData.isEmpty)
                        
                        Spacer()
                    }
                    .navigationTitle("Import")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Cancel") {
                                showingImportSheet = false
                            }
                        }
                    }
                }
            }
            .alert("Training Data", isPresented: $showingAlert) {
                Button("OK") { }
            } message: {
                Text(alertMessage)
            }
        }
    }
}

enum PhotoTag: String, CaseIterable {
    case duplicate = "duplicate"
    case blurry = "blurry"
    case lowQuality = "lowQuality"
    case screenshot = "screenshot"
    case unrated = "unrated"
}

struct PhotoScanResult: Identifiable {
    let id: String
    let thumbnail: Image
    var tags: Set<PhotoTag>
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

struct PersistablePhotoResult: Codable {
    let id: String
    let tags: [String]
    let exactHash: String
    let perceptualHash: UInt64
    let metadata: PhotoMetadata
}

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

    
    // Persistent storage for photo hashes to detect duplicates across scans
    private var storedPhotoHashes: [String: String] {
        get {
            guard let data = store.data(forKey: photoHashesKey),
                  let hashes = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return hashes
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            store.set(data, forKey: photoHashesKey)
        }
    }
    
    private var scanOffset: Int {
        get { store.integer(forKey: scanOffsetKey) }
        set { store.set(newValue, forKey: scanOffsetKey) }
    }
    
    // Public getter for debugging
    var currentScanOffset: Int {
        return scanOffset
    }
    
    private var ratedPhotos: Set<String> {
        get {
            guard let data = store.data(forKey: ratedPhotosKey),
                  let photos = try? JSONDecoder().decode(Set<String>.self, from: data) else {
                return []
            }
            return photos
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            store.set(data, forKey: ratedPhotosKey)
        }
    }
    @Published var isTrainingMode = true // Are we in training mode or full scan mode?
    @Published var trainingConfidence = 0.0 // Current ML confidence level
    @Published var isTrainingComplete = false // Has training reached 99% confidence?
    
    init() {
        print("🏁 QuickScanService initializing...")
        print("🏁 Current scanOffset: \(scanOffset)")
        print("🏁 Rated photos count: \(ratedPhotos.count)")
        print("🏁 Stored hashes count: \(storedPhotoHashes.count)")
        
        // Load persisted results
        loadPersistedResults()
        print("🏁 Loaded \(results.count) persisted results")
        
        // Try to calculate confidence on startup
        if !ratedPhotos.isEmpty {
            calculateTrainingConfidence()
            print("🏁 Restored training confidence: \(trainingConfidence * 100)%")
        }
        
        print("🏁 QuickScanService initialization complete")
    }
    
    func loadPersistedResults() {
        guard let data = store.data(forKey: resultsKey),
              let persistableResults = try? JSONDecoder().decode([PersistablePhotoResult].self, from: data) else {
            print("🏁 No persisted results found")
            return
        }
        
        print("🏁 Found \(persistableResults.count) persisted results, reconstructing...")
        
        // Reconstruct PhotoScanResults by fetching assets again
        Task { @MainActor in
            var reconstructedResults: [PhotoScanResult] = []
            
            for persistable in persistableResults {
                // Try to fetch the asset by its identifier
                let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [persistable.id], options: nil)
                if let asset = fetchResult.firstObject {
                    // Generate thumbnail again
                    let thumbnail = await generateThumbnail(for: asset)
                    let result = PhotoScanResult(from: persistable, asset: asset, thumbnail: thumbnail)
                    reconstructedResults.append(result)
                } else {
                    print("⚠️ Could not find asset \(persistable.id.prefix(8)), skipping")
                }
            }
            
            results = reconstructedResults
            print("🏁 Successfully reconstructed \(results.count) results")
            objectWillChange.send()
        }
    }
    
    private func saveResults() {
        let persistableResults = results.map { $0.toPersistableResult() }
        
        do {
            let data = try JSONEncoder().encode(persistableResults)
            store.set(data, forKey: resultsKey)
            print("💾 Saved \(persistableResults.count) results to persistent storage")
        } catch {
            print("❌ Failed to save results: \(error)")
        }
    }
    
    func deletePhotos(withIds photoIds: [String]) async {
        guard !photoIds.isEmpty else { return }
        
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: photoIds, options: nil)
        let assetsToDelete = assets.objects(at: IndexSet(0..<assets.count))
        
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assetsToDelete as NSFastEnumeration)
            }
            
            // Remove deleted photos from results
            await MainActor.run {
                results.removeAll { photoIds.contains($0.id) }
                saveResults()
                print("🗑️ Successfully deleted \(photoIds.count) photos")
            }
        } catch {
            print("❌ Failed to delete photos: \(error)")
        }
    }
    
    private func generateThumbnail(for asset: PHAsset) async -> Image {
        return await withCheckedContinuation { continuation in
            var resumed = false
            
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = false
            
            imageManager.requestImage(
                for: asset,
                targetSize: thumbnailSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                
                if let image = image {
                    continuation.resume(returning: Image(uiImage: image))
                } else {
                    // Fallback to a placeholder
                    continuation.resume(returning: Image(systemName: "photo"))
                }
            }
        }
    }
    
    func scanAllAssets() {
        print("🔍 Starting scan...")
        
        // Prevent multiple scans (but don't return early if already scanning - let it proceed if UI called it)
        if isScanning {
            print("⚠️ Scan already in progress, but proceeding since UI requested it")
        }
        
        // Start background task to prevent suspension
        let backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "PhotoScan") {
            print("⚠️ Background task expired")
        }
        
        // UI state should already be set by button press, but ensure it's correct
        if !isScanning {
            isScanning = true
            // Only clear results if starting fresh training (scanOffset = 0)
            if scanOffset == 0 {
                results = []
                print("🆕 Starting fresh training - clearing previous results")
            } else {
                print("🔄 Continuing training - keeping existing results (offset: \(scanOffset))")
            }
            currentlyProcessed = 0
            totalToProcess = 10
        }
        print("📱 Confirmed scanning state is set")
        
        // Check PhotoKit access status
        let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        print("📋 PhotoKit auth status: \(authStatus.rawValue)")
        
        Task {
            print("🚀 Task started, about to call performScan()")
            let scanResults = await performScan()
            print("🏁 performScan() completed with \(scanResults.count) results")
            
            print("🔄 About to process \(scanResults.count) scan results")
            print("🔄 Current results count before processing: \(results.count)")
            objectWillChange.send()
            
            if isTrainingMode {
                // In training mode, append new results to existing ones
                results.append(contentsOf: scanResults)
                print("🎓 Training mode: Appended \(scanResults.count) new results, total: \(results.count)")
            } else {
                // In full scan mode, replace all results
                results = scanResults
                print("🚀 Full scan mode: Set \(scanResults.count) results")
            }
            
            // Save results to persistent storage
            saveResults()
            
            isScanning = false
            refreshTrigger = UUID() // Force UI refresh
            print("🔄 Results count after processing: \(results.count)")
            print("✅ Scan completed with \(scanResults.count) results")
            print("🔄 Sent objectWillChange notification and refreshTrigger")
            
            // End background task
            if backgroundTaskID != UIBackgroundTaskIdentifier.invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                print("🔚 Background task ended")
            }
        }
    }
    
    private func performScan() async -> [PhotoScanResult] {
        print("📷 Starting performScan...")
        
        // Check if we have permission to access photos
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        print("📋 Current auth status in performScan: \(currentStatus.rawValue)")
        
        guard currentStatus == .authorized || currentStatus == .limited else {
            print("❌ No photo access permission in performScan")
            return []
        }
        
        print("📋 About to fetch assets...")
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        print("📸 Found \(assets.count) assets to scan")
        
        guard assets.count > 0 else {
            print("❌ No assets found to scan")
            return []
        }
        
        var scanResults: [PhotoScanResult] = []
        
        // Determine scan range based on mode
        let startIndex: Int
        let endIndex: Int
        let maxToProcess: Int
        
        if isTrainingMode {
            // Training mode: Process next 10 photos (starting from scanOffset)
            let currentOffset = scanOffset
            print("🔍 DEBUG: Current scanOffset value: \(currentOffset)")
            print("🔍 DEBUG: Store value: \(store.integer(forKey: scanOffsetKey))")
            
            startIndex = currentOffset
            endIndex = min(startIndex + 10, assets.count)
            maxToProcess = endIndex - startIndex
            print("📊 Training mode: Scanning photos \(startIndex+1) to \(endIndex) (offset: \(currentOffset))")
        } else {
            // Full scan mode: Process all photos
            startIndex = 0
            endIndex = assets.count
            maxToProcess = assets.count
            await MainActor.run {
                totalToProcess = assets.count
            }
            print("🚀 Full scan mode: Scanning all \(assets.count) photos")
        }
        
        for i in startIndex..<endIndex {
            let asset = assets.object(at: i)
            let relativeIndex = i - startIndex + 1
            print("🔍 Processing asset \(relativeIndex)/\(maxToProcess) (absolute index: \(i+1))")
            
            // Update progress 
            currentlyProcessed = relativeIndex
            
            let thumbnail = await getThumbnail(for: asset)
            let fullImage = await getFullImage(for: asset)
            
            // Extract metadata first
            let metadata = await extractMetadata(for: asset)
            print("📋 Asset \(i+1) metadata: screenshot=\(metadata.isScreenshot), source=\(metadata.source ?? "unknown"), textDensity=\(metadata.textDensity)")
            
            // Get learned classification rules
            let rules = learningService.getClassificationRules()
            print("🧠 Using learned rules: blurThreshold=\(rules.blurThreshold), textThreshold=\(rules.textDensityThresholdForScreenshot)")
            
            // Analyze the photo with smart classification using learned rules
            var tags: Set<PhotoTag> = []
            
            // Screenshot detection (enhanced with learned rules)
            let isScreenshotByMetadata = metadata.isScreenshot
            let isScreenshotByTextDensity = metadata.textDensity > rules.textDensityThresholdForScreenshot
            
            if isScreenshotByMetadata || isScreenshotByTextDensity {
                tags.insert(.screenshot)
                print("📱 Asset \(i+1) is a screenshot (metadata: \(isScreenshotByMetadata), textDensity: \(isScreenshotByTextDensity))")
            }
            
            // Check for blur using learned threshold (skip for screenshots)
            if !tags.contains(.screenshot), let cgImage = fullImage {
                let blurScore = await calculateBlurScore(cgImage: cgImage)
                if blurScore < rules.blurThreshold {
                    tags.insert(.blurry)
                    print("📷 Asset \(i+1) is VERY blurry (Laplacian score: \(blurScore), threshold: \(rules.blurThreshold))")
                } else {
                    print("📷 Asset \(i+1) is acceptable (Laplacian score: \(blurScore), threshold: \(rules.blurThreshold))")
                }
            }
            
            // Smart low quality check using learned rules (skip for screenshots and text-heavy images)
            if !tags.contains(.screenshot) && metadata.textDensity < rules.textDensityThresholdForScreenshot, let cgImage = fullImage {
                let brightness = await calculateBrightness(cgImage: cgImage)
                if brightness < rules.lowQualityThreshold {
                    tags.insert(.lowQuality)
                    print("🌑 Asset \(i+1) is low quality (brightness: \(brightness), threshold: \(rules.lowQualityThreshold))")
                }
            } else if metadata.textDensity >= rules.textDensityThresholdForScreenshot {
                print("📝 Asset \(i+1) is text-heavy, skipping low quality check (textDensity: \(metadata.textDensity), threshold: \(rules.textDensityThresholdForScreenshot))")
            }
            
            // Add unrated tag if photo hasn't been rated yet
            if !ratedPhotos.contains(asset.localIdentifier) {
                tags.insert(.unrated)
                print("🏷️ Asset \(relativeIndex) marked as unrated")
            }
            
            // Create hash for duplicates
            let exactHash = await createSHA256Hash(for: asset)
            
            // Check against persistent storage for duplicates from previous scans (excluding current photo)
            let currentHashes = storedPhotoHashes
            if let existingAsset = currentHashes.first(where: { $0.key != asset.localIdentifier && $0.value == exactHash }) {
                print("🔄 Found duplicate across scans: \(asset.localIdentifier) matches \(existingAsset.key)")
                tags.insert(.duplicate)
            }
            
            // Always store this photo's hash for future duplicate detection
            var updatedHashes = currentHashes
            updatedHashes[asset.localIdentifier] = exactHash
            storedPhotoHashes = updatedHashes
            print("💾 Stored hash for \(asset.localIdentifier) - Total hashes: \(updatedHashes.count)")
            
            let result = PhotoScanResult(
                id: asset.localIdentifier,
                thumbnail: thumbnail,
                tags: tags,
                asset: asset,
                exactHash: exactHash,
                perceptualHash: 0,
                metadata: metadata
            )
            
            scanResults.append(result)
            print("✅ Successfully processed asset \(relativeIndex) - Tags: \(tags.map { $0.rawValue })")
        }
        
        // Update scan offset for next rescan
        print("🔍 DEBUG: About to update scanOffset from \(scanOffset) to \(endIndex)")
        scanOffset = endIndex
        print("🔍 DEBUG: After update - scanOffset: \(scanOffset), store value: \(store.integer(forKey: scanOffsetKey))")
        print("📊 Updated scan offset to \(scanOffset) for next rescan")
        
        // After processing individual photos, check for visual duplicates
        scanResults = await findVisualDuplicates(in: scanResults)
        
        print("📊 Scan complete with \(scanResults.count) results")
        return scanResults
    }
    
    private func getThumbnail(for asset: PHAsset) async -> Image {
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            
            imageManager.requestImage(for: asset, targetSize: thumbnailSize, contentMode: .aspectFill, options: options) { uiImage, _ in
                let image = uiImage != nil ? Image(uiImage: uiImage!) : Image(systemName: "photo")
                continuation.resume(returning: image)
            }
        }
    }
    
    private func getFullImage(for asset: PHAsset) async -> CGImage? {
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            
            imageManager.requestImage(for: asset, targetSize: fullImageSize, contentMode: .aspectFit, options: options) { uiImage, _ in
                continuation.resume(returning: uiImage?.cgImage)
            }
        }
    }
    
    private func calculateBlurScore(cgImage: CGImage) async -> Double {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Use Laplacian edge detection for more accurate blur detection
                let width = cgImage.width
                let height = cgImage.height
                let bytesPerPixel = 4
                let bytesPerRow = width * bytesPerPixel
                let dataSize = height * bytesPerRow
                
                var pixelData = [UInt8](repeating: 0, count: dataSize)
                
                guard let context = CGContext(
                    data: &pixelData,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else {
                    continuation.resume(returning: 1.0) // Assume sharp if can't process
                    return
                }
                
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                
                // Convert to grayscale and apply Laplacian kernel
                var grayPixels = [UInt8](repeating: 0, count: width * height)
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = (y * width + x) * bytesPerPixel
                        if offset < pixelData.count - 3 {
                            let r = Double(pixelData[offset])
                            let g = Double(pixelData[offset + 1])
                            let b = Double(pixelData[offset + 2])
                            // Convert to grayscale using luminance formula
                            let gray = UInt8(0.299 * r + 0.587 * g + 0.114 * b)
                            grayPixels[y * width + x] = gray
                        }
                    }
                }
                
                // Apply Laplacian kernel (3x3)
                // [ 0 -1  0]
                // [-1  4 -1] 
                // [ 0 -1  0]
                var laplacianSum: Double = 0
                var validPixels = 0
                
                // Skip border pixels to avoid bounds checking
                for y in 1..<(height-1) {
                    for x in 1..<(width-1) {
                        let center = Int(grayPixels[y * width + x])
                        let top = Int(grayPixels[(y-1) * width + x])
                        let bottom = Int(grayPixels[(y+1) * width + x])
                        let left = Int(grayPixels[y * width + (x-1)])
                        let right = Int(grayPixels[y * width + (x+1)])
                        
                        // Apply Laplacian kernel
                        let laplacian = abs(4 * center - top - bottom - left - right)
                        laplacianSum += Double(laplacian)
                        validPixels += 1
                    }
                }
                
                // Calculate average Laplacian response
                let avgLaplacian = validPixels > 0 ? laplacianSum / Double(validPixels) : 0.0
                
                // Normalize to 0-1 scale (higher values = sharper)
                // Based on empirical testing, sharp images typically have avgLaplacian > 15-20
                let normalizedScore = min(avgLaplacian / 100.0, 1.0)
                
                print("🔍 Blur analysis: avgLaplacian=\(avgLaplacian), normalizedScore=\(normalizedScore)")
                continuation.resume(returning: normalizedScore)
            }
        }
    }
    
    private func calculateBrightness(cgImage: CGImage) async -> Double {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let width = cgImage.width
                let height = cgImage.height
                let bytesPerPixel = 4
                let bytesPerRow = width * bytesPerPixel
                let dataSize = height * bytesPerRow
                
                var pixelData = [UInt8](repeating: 0, count: dataSize)
                
                guard let context = CGContext(
                    data: &pixelData,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else {
                    continuation.resume(returning: 0.5)
                    return
                }
                
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                
                var totalBrightness: Int64 = 0
                let sampleEvery = max(1, width / 50) // Sample for performance
                var samples = 0
                
                for y in stride(from: 0, to: height, by: sampleEvery) {
                    for x in stride(from: 0, to: width, by: sampleEvery) {
                        let offset = (y * width + x) * bytesPerPixel
                        if offset < pixelData.count - 3 {
                            let r = Int64(pixelData[offset])
                            let g = Int64(pixelData[offset + 1])
                            let b = Int64(pixelData[offset + 2])
                            let brightness = (r + g + b) / 3
                            totalBrightness += brightness
                            samples += 1
                        }
                    }
                }
                
                if samples > 0 {
                    let avgBrightness = Double(totalBrightness) / Double(samples) / 255.0
                    continuation.resume(returning: avgBrightness)
                } else {
                    continuation.resume(returning: 0.5)
                }
            }
        }
    }
    
    private func createSHA256Hash(for asset: PHAsset) async -> String {
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            
            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard let imageData = data else {
                    continuation.resume(returning: "no-data-\(asset.localIdentifier)")
                    return
                }
                
                let hash = SHA256.hash(data: imageData)
                let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
                continuation.resume(returning: hashString)
            }
        }
    }
    
    private func extractMetadata(for asset: PHAsset) async -> PhotoMetadata {
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            
            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, orientation, info in
                let creationDate = asset.creationDate
                let location = asset.location
                let dimensions = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
                
                // Detect screenshots using various methods
                var isScreenshot = false
                var source: String?
                var textDensity: Double = 0.0
                
                // Method 1: Check UTI type for screenshot
                if let uti = dataUTI {
                    print("📋 UTI: \(uti)")
                    if uti.contains("screenshot") {
                        isScreenshot = true
                        source = "Screenshot"
                    }
                }
                
                // Method 2: Check creation source metadata
                if let info = info,
                   let creationRequestId = info["PHImageResultRequestIDKey"] as? NSNumber {
                    // Screenshots often have specific creation patterns
                    print("📋 Creation request ID: \(creationRequestId)")
                }
                
                // Method 3: Analyze filename pattern (if available)
                if asset.mediaSubtypes.contains(.photoScreenshot) {
                    isScreenshot = true
                    source = "Screenshot"
                }
                
                // Method 4: Check asset source type
                if asset.sourceType == .typeUserLibrary {
                    // Could be screenshot, check other indicators
                    if let date = creationDate {
                        // Screenshots often have very precise timestamps (to the second)
                        let timeInterval = date.timeIntervalSince1970
                        let fractionalPart = timeInterval.truncatingRemainder(dividingBy: 1)
                        if fractionalPart == 0.0 { // Exactly on the second
                            // Additional screenshot indicator
                        }
                    }
                }
                
                // Method 5: Analyze image for text content using Vision framework
                if let imageData = data, let image = UIImage(data: imageData) {
                    Task {
                        let density = await self.calculateTextDensity(image: image)
                        textDensity = density
                        
                        // High text density often indicates screenshots
                        if density > 0.5 && !isScreenshot {
                            isScreenshot = true
                            source = "Text-heavy image (likely screenshot)"
                        }
                        
                        let metadata = PhotoMetadata(
                            creationDate: creationDate,
                            location: location,
                            source: source,
                            dimensions: dimensions,
                            isScreenshot: isScreenshot,
                            textDensity: textDensity
                        )
                        
                        continuation.resume(returning: metadata)
                    }
                } else {
                    let metadata = PhotoMetadata(
                        creationDate: creationDate,
                        location: location,
                        source: source,
                        dimensions: dimensions,
                        isScreenshot: isScreenshot,
                        textDensity: textDensity
                    )
                    
                    continuation.resume(returning: metadata)
                }
            }
        }
    }
    
    private func calculateTextDensity(image: UIImage) async -> Double {
        return await withCheckedContinuation { continuation in
            guard let cgImage = image.cgImage else {
                continuation.resume(returning: 0.0)
                return
            }
            
            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: 0.0)
                    return
                }
                
                // Calculate text density based on coverage area
                let imageArea = Double(cgImage.width * cgImage.height)
                var textArea: Double = 0.0
                
                for observation in observations {
                    let boundingBox = observation.boundingBox
                    let area = boundingBox.width * boundingBox.height * imageArea
                    textArea += area
                }
                
                let density = min(textArea / imageArea, 1.0)
                continuation.resume(returning: density)
            }
            
            request.recognitionLevel = .fast
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }
    
    private func findVisualDuplicates(in results: [PhotoScanResult]) async -> [PhotoScanResult] {
        var updatedResults = results
        
        // Primary duplicate detection: Visual similarity (matching hashes)
        for i in 0..<updatedResults.count {
            for j in (i+1)..<updatedResults.count {
                // Check for exact visual match (same hash)
                if updatedResults[i].exactHash == updatedResults[j].exactHash {
                    print("🔍 VISUAL DUPLICATE FOUND:")
                    print("📷 Photo \(i+1): \(updatedResults[i].id.prefix(8))")
                    print("📷 Photo \(j+1): \(updatedResults[j].id.prefix(8))")
                    print("🎯 Hash match: \(updatedResults[i].exactHash.prefix(8))")
                    
                    // Check temporal proximity for additional context (but not required)
                    if let date1 = updatedResults[i].metadata.creationDate,
                       let date2 = updatedResults[j].metadata.creationDate {
                        let timeDifference = abs(date1.timeIntervalSince(date2))
                        print("⏰ Time difference: \(timeDifference)s \(timeDifference <= 30 ? "(likely burst/multiple saves)" : "(saved at different times)")")
                    }
                    
                    // Mark as duplicates - visual similarity is the primary criteria
                    updatedResults[i].tags.insert(.duplicate)
                    updatedResults[j].tags.insert(.duplicate)
                }
            }
        }
        
        return updatedResults
    }
    
    func markPhotoAsRated(_ assetId: String) {
        DebugLogger.log("markPhotoAsRated called for \(assetId.prefix(8))", category: "RATING")
        
        var currentRated = ratedPhotos
        currentRated.insert(assetId)
        ratedPhotos = currentRated // This will trigger persistent storage
        DebugLogger.log("Added to ratedPhotos set, total rated: \(ratedPhotos.count)", category: "RATING")
        
        // Update the result to remove unrated tag
        if let index = results.firstIndex(where: { $0.id == assetId }) {
            let oldTags = results[index].tags
            results[index].tags.remove(.unrated)
            objectWillChange.send()
            refreshTrigger = UUID()
            DebugLogger.log("Removed unrated tag from photo \(assetId.prefix(8)): \(oldTags) -> \(results[index].tags)", category: "RATING")
        } else {
            DebugLogger.log("ERROR: Photo not found when marking as rated: \(assetId.prefix(8))", category: "RATING_ERROR")
        }
    }
    
    func updatePhotoTags(assetId: String, newTags: Set<PhotoTag>) {
        DebugLogger.log("updatePhotoTags called for \(assetId.prefix(8)) with tags: \(newTags)", category: "TAG_UPDATE")
        
        if let index = results.firstIndex(where: { $0.id == assetId }) {
            let oldTags = results[index].tags
            DebugLogger.log("Found photo at index \(index), old tags: \(oldTags)", category: "TAG_UPDATE")
            
            // Keep unrated tag if photo isn't rated yet
            var updatedTags = newTags
            if !isPhotoRated(assetId) {
                updatedTags.insert(.unrated)
                DebugLogger.log("Photo not rated yet, keeping unrated tag", category: "TAG_UPDATE")
            }
            
            results[index].tags = updatedTags
            saveResults() // Save after tag change
            objectWillChange.send()
            refreshTrigger = UUID()
            DebugLogger.log("Updated tags for photo \(assetId.prefix(8)): \(oldTags) -> \(updatedTags)", category: "TAG_UPDATE")
        } else {
            DebugLogger.log("ERROR: Photo not found in results for tag update: \(assetId.prefix(8))", category: "TAG_UPDATE_ERROR")
        }
    }
    
    func isPhotoRated(_ assetId: String) -> Bool {
        return ratedPhotos.contains(assetId)
    }
    
    func exportTrainingData() -> String? {
        let trainingData = TrainingDataExport(
            scanOffset: scanOffset,
            ratedPhotos: Array(ratedPhotos),
            photoHashes: storedPhotoHashes,
            trainingConfidence: trainingConfidence,
            isTrainingComplete: isTrainingComplete,
            feedback: learningService.getAllFeedback(),
            rules: learningService.getClassificationRules(),
            exportDate: Date()
        )
        
        do {
            let jsonData = try JSONEncoder().encode(trainingData)
            let jsonString = String(data: jsonData, encoding: .utf8)
            print("📦 Exported training data: \(ratedPhotos.count) rated photos, \(trainingConfidence * 100)% confidence")
            return jsonString
        } catch {
            print("❌ Failed to export training data: \(error)")
            return nil
        }
    }
    
    func importTrainingData(_ jsonString: String) -> Bool {
        do {
            guard let jsonData = jsonString.data(using: .utf8) else { return false }
            let trainingData = try JSONDecoder().decode(TrainingDataExport.self, from: jsonData)
            
            // Restore all training state
            scanOffset = trainingData.scanOffset
            ratedPhotos = Set(trainingData.ratedPhotos)
            storedPhotoHashes = trainingData.photoHashes
            trainingConfidence = trainingData.trainingConfidence
            isTrainingComplete = trainingData.isTrainingComplete
            
            // Restore feedback and rules
            learningService.importFeedback(trainingData.feedback)
            learningService.importRules(trainingData.rules)
            
            objectWillChange.send()
            refreshTrigger = UUID()
            
            print("📥 Imported training data: \(ratedPhotos.count) rated photos, \(trainingConfidence * 100)% confidence")
            print("📅 Original export date: \(trainingData.exportDate)")
            return true
        } catch {
            print("❌ Failed to import training data: \(error)")
            return false
        }
    }
    
    func resetTraining() {
        print("🔄 Resetting training...")
        scanOffset = 0
        
        // Properly clear persistent storage
        let emptyRated: Set<String> = []
        ratedPhotos = emptyRated
        
        let emptyHashes: [String: String] = [:]
        storedPhotoHashes = emptyHashes
        
        results = []
        isTrainingMode = true
        trainingConfidence = 0.0
        isTrainingComplete = false
        objectWillChange.send()
        refreshTrigger = UUID()
        
        print("🔄 Training reset complete - Offset: \(scanOffset), Rated: \(ratedPhotos.count), Hashes: \(storedPhotoHashes.count)")
    }
    
    func calculateTrainingConfidence() {
        let totalRatedPhotos = ratedPhotos.count
        print("🧠 Calculating confidence: \(totalRatedPhotos) rated photos")
        
        if totalRatedPhotos == 0 {
            trainingConfidence = 0.0
            print("🧠 No rated photos yet, confidence = 0%")
            return
        }
        
        // Get feedback from learning service to calculate confidence
        let feedbackData = learningService.getAllFeedback()
        print("🧠 Retrieved \(feedbackData.count) feedback entries from storage")
        
        var correctPredictions = 0
        var totalPredictions = 0
        
        for feedback in feedbackData {
            totalPredictions += 1
            if feedback.isCorrect {
                correctPredictions += 1
            }
            print("🧠 Feedback: \(feedback.assetId.prefix(8)) - Correct: \(feedback.isCorrect)")
        }
        
        if totalPredictions > 0 {
            trainingConfidence = Double(correctPredictions) / Double(totalPredictions)
        } else {
            // If no feedback stored but we have rated photos, something is wrong
            print("⚠️ Warning: Have \(totalRatedPhotos) rated photos but no feedback entries!")
            trainingConfidence = 0.0
        }
        
        // Check if training is complete (99% confidence and at least 20 rated photos)
        isTrainingComplete = trainingConfidence >= 0.99 && totalRatedPhotos >= 20
        
        print("📊 Training confidence: \(String(format: "%.1f", trainingConfidence * 100))% (\(correctPredictions)/\(totalPredictions)) - Rated: \(totalRatedPhotos)")
        if isTrainingComplete {
            print("🎓 Training complete! Ready for full scan.")
        }
        
        objectWillChange.send()
    }
    
    func updateMLThresholds() {
        print("🧠 Updating ML thresholds based on feedback...")
        let feedbackData = learningService.getAllFeedback()
        
        // Analyze blur detection feedback
        let blurFeedback = feedbackData.filter { 
            $0.predictedTags.contains("blurry") || $0.actualTags.contains("blurry")
        }
        
        // Analyze low quality feedback  
        let lowQualityFeedback = feedbackData.filter {
            $0.predictedTags.contains("lowQuality") || $0.actualTags.contains("lowQuality")
        }
        
        // Analyze screenshot feedback
        let screenshotFeedback = feedbackData.filter {
            $0.predictedTags.contains("screenshot") || $0.actualTags.contains("screenshot")
        }
        
        print("🧠 Analyzed feedback: Blur=\(blurFeedback.count), LowQuality=\(lowQualityFeedback.count), Screenshot=\(screenshotFeedback.count)")
        
        // This will improve over time as we get more feedback
        learningService.updateClassificationRules()
    }
    
    func startFullScan() {
        print("🚀 Starting full photo library scan...")
        isTrainingMode = false
        scanOffset = 0
        results = []
        // This will scan all photos, not just 10
        scanAllAssets()
    }
    
    func resetTrainingCompletely() {
        print("🔄 COMPLETE RESET - Clearing all training data...")
        
        // Clear all data
        results = []
        scanOffset = 0
        trainingConfidence = 0.0
        isTrainingComplete = false
        isTrainingMode = true
        
        // Clear UserDefaults
        UserDefaults.standard.removeObject(forKey: "quickScanResults")
        UserDefaults.standard.removeObject(forKey: "scanOffset")
        UserDefaults.standard.removeObject(forKey: "ratedPhotosCount")
        UserDefaults.standard.removeObject(forKey: "trainingConfidence")
        UserDefaults.standard.removeObject(forKey: "isTrainingComplete")
        UserDefaults.standard.removeObject(forKey: "storedPhotoHashes")
        
        // Clear learning service data
        LearningService.shared.clearAllFeedback()
        
        print("🔄 Reset complete - ready for fresh training")
        objectWillChange.send()
    }
    
    func cleanupIncorrectDuplicateTags() {
        // Run cleanup in background to avoid SwiftUI publishing errors
        Task {
            await MainActor.run {
                print("🧹 Cleaning up incorrect duplicate tags...")
                var cleanedCount = 0
                
                for i in 0..<results.count {
                    if results[i].tags.contains(.duplicate) {
                        let targetHash = results[i].exactHash
                        let matchingPhotos = results.filter { $0.exactHash == targetHash }
                        
                        // If this photo is the only one with this hash, remove the duplicate tag
                        if matchingPhotos.count == 1 {
                            print("🧹 Removing incorrect duplicate tag from \(results[i].id.prefix(8)) - unique hash \(targetHash.prefix(8))")
                            results[i].tags.remove(.duplicate)
                            cleanedCount += 1
                        }
                    }
                }
                
                if cleanedCount > 0 {
                    print("🧹 Cleaned up \(cleanedCount) incorrect duplicate tags")
                    saveResults()
                    objectWillChange.send()
                }
            }
        }
    }
    
    func findDuplicatesFor(assetId: String) -> [PhotoScanResult] {
        guard let targetResult = results.first(where: { $0.asset.localIdentifier == assetId }) else { 
            print("❌ Target photo \(assetId.prefix(8)) not found in results array")
            return [] 
        }
        
        print("🔍 Looking for duplicates of photo \(assetId.prefix(8))")
        print("🔍 Target photo has duplicate tag: \(targetResult.tags.contains(.duplicate))")
        print("🔍 Target photo creation date: \(targetResult.metadata.creationDate?.description ?? "nil")")
        print("🔍 Target photo hash: \(targetResult.exactHash.prefix(8))")
        print("🔍 Total photos in results: \(results.count)")
        
        // Clean up incorrect duplicate tags first
        cleanupIncorrectDuplicateTags()
        
        // Find exact hash matches (these are definitely duplicates of this photo)
        let exactMatches = results.filter { result in
            let matches = result.asset.localIdentifier != assetId && result.exactHash == targetResult.exactHash
            if matches {
                print("🔍 Found exact hash match: \(result.asset.localIdentifier.prefix(8)) with hash \(result.exactHash.prefix(8))")
            }
            return matches
        }
        
        // Debug: Show all photos with duplicate tags and their hashes
        let allDuplicateTaggedPhotos = results.filter { $0.tags.contains(.duplicate) }
        print("🔍 All photos with duplicate tags in results (\(allDuplicateTaggedPhotos.count)):")
        for duplicatePhoto in allDuplicateTaggedPhotos {
            print("🔍   - \(duplicatePhoto.asset.localIdentifier.prefix(8)): hash \(duplicatePhoto.exactHash.prefix(8))")
        }
        
        // Find temporal duplicates (photos taken within 5 seconds of this specific photo)
        let temporalMatches = results.filter { result in
            guard result.asset.localIdentifier != assetId,
                  let targetDate = targetResult.metadata.creationDate,
                  let resultDate = result.metadata.creationDate else { return false }
            
            let timeDifference = abs(targetDate.timeIntervalSince(resultDate))
            let matches = timeDifference <= 5.0
            if matches {
                print("🔍 Found temporal match: \(result.asset.localIdentifier.prefix(8)) (diff: \(timeDifference)s)")
            }
            return matches
        }
        
        // If no exact or temporal matches found, but this photo has duplicate tag,
        // find other photos that also have duplicate tags and could be related
        var relatedDuplicates: [PhotoScanResult] = []
        if exactMatches.isEmpty && temporalMatches.isEmpty && targetResult.tags.contains(.duplicate) {
            print("🔍 No direct matches found, searching for related duplicate groups...")
            
            // Find photos with duplicate tags that might be in the same group
            let allDuplicatePhotos = results.filter { result in
                result.asset.localIdentifier != assetId && result.tags.contains(.duplicate)
            }
            
            // Check if any of these duplicate photos are temporal matches with the target
            relatedDuplicates = allDuplicatePhotos.filter { duplicate in
                guard let targetDate = targetResult.metadata.creationDate,
                      let duplicateDate = duplicate.metadata.creationDate else { return false }
                
                let timeDifference = abs(targetDate.timeIntervalSince(duplicateDate))
                let isRelated = timeDifference <= 10.0 // Slightly more lenient for fallback
                if isRelated {
                    print("🔍 Found related duplicate: \(duplicate.id.prefix(8)) (diff: \(timeDifference)s)")
                }
                return isRelated
            }
        }
        
        // Combine all matches
        var allDuplicates = Set<String>()
        var duplicateResults: [PhotoScanResult] = []
        
        for match in (exactMatches + temporalMatches + relatedDuplicates) {
            if !allDuplicates.contains(match.id) {
                allDuplicates.insert(match.id)
                duplicateResults.append(match)
            }
        }
        
        print("🔍 Found \(duplicateResults.count) duplicates for photo \(assetId.prefix(8))")
        print("🔍 Exact: \(exactMatches.count), Temporal: \(temporalMatches.count), Related: \(relatedDuplicates.count)")
        
        return duplicateResults
    }
    
    func removeDuplicateTag(from assetId: String) {
        if let index = results.firstIndex(where: { $0.id == assetId }) {
            let hadDuplicateTag = results[index].tags.contains(.duplicate)
            results[index].tags.remove(.duplicate)
            saveResults() // Save after tag change
            objectWillChange.send()
            refreshTrigger = UUID()
            print("🏷️ Removed duplicate tag from photo \(assetId.prefix(8)) (had tag: \(hadDuplicateTag))")
        } else {
            print("❌ Could not find photo \(assetId.prefix(8)) in results array to remove duplicate tag")
        }
    }
    
    func validateDuplicateTags() {
        // Remove duplicate tags from photos that don't actually have duplicates
        var updatedResults = results
        var changedCount = 0
        
        for i in 0..<updatedResults.count {
            if updatedResults[i].tags.contains(.duplicate) {
                let duplicates = findDuplicatesFor(assetId: updatedResults[i].id)
                if duplicates.isEmpty {
                    updatedResults[i].tags.remove(.duplicate)
                    changedCount += 1
                    print("🔄 Removed incorrect duplicate tag from \(updatedResults[i].id.prefix(8))")
                }
            }
        }
        
        if changedCount > 0 {
            results = updatedResults
            objectWillChange.send()
            refreshTrigger = UUID()
            print("✅ Validated duplicate tags: removed \(changedCount) incorrect tags")
        }
    }
}

struct DuplicateViewerInterface: View {
    let result: PhotoScanResult
    @ObservedObject var quickScanService: QuickScanService
    @State private var showingDuplicates = false
    @State private var duplicates: [PhotoScanResult] = []
    
    var body: some View {
        HStack {
            Image(systemName: "doc.on.doc.fill")
                .foregroundColor(.orange)
            
            Text("This photo has duplicates")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Button("View Duplicates") {
                print("🎬 Button pressed: Looking for duplicates of \(result.asset.localIdentifier.prefix(8))")
                let foundDuplicates = quickScanService.findDuplicatesFor(assetId: result.asset.localIdentifier)
                print("🎬 Button result: Found \(foundDuplicates.count) duplicates")
                duplicates = foundDuplicates
                showingDuplicates = true
                print("🎬 Sheet will show with \(duplicates.count) duplicates")
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.2))
            .foregroundColor(.orange)
            .cornerRadius(8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .sheet(isPresented: $showingDuplicates) {
            DuplicateManagerView(
                originalPhoto: result,
                duplicates: duplicates,
                quickScanService: quickScanService
            )
        }
    }
}

struct FeedbackInterface: View {
    let result: PhotoScanResult
    @StateObject private var learningService = LearningService.shared
    @ObservedObject var quickScanService: QuickScanService
    @State private var showingFeedbackOptions = false
    @State private var selectedFeedback: FeedbackState? = nil
    @State private var photoId: String = ""
    
    enum FeedbackState {
        case correct, incorrect
    }
    
    init(result: PhotoScanResult, quickScanService: QuickScanService) {
        self.result = result
        self.quickScanService = quickScanService
        self._photoId = State(initialValue: result.asset.localIdentifier)
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Show different message based on rating status
            if quickScanService.isPhotoRated(result.asset.localIdentifier) {
                Text("Update your rating for this photo")
                    .font(.headline)
                    .foregroundColor(.primary)
            } else {
                Text("Is this classification correct?")
                    .font(.headline)
                    .foregroundColor(.primary)
            }
            
            HStack(spacing: 20) {
                // Correct classification
                Button(action: {
                    selectedFeedback = .correct
                    quickScanService.markPhotoAsRated(result.asset.localIdentifier)
                    learningService.recordFeedback(
                        for: result.asset.localIdentifier,
                        actualTags: result.tags.subtracting([.unrated]),
                        predictedTags: result.tags.subtracting([.unrated]),
                        isCorrect: true,
                        metadata: result.metadata
                    )
                    quickScanService.calculateTrainingConfidence()
                    quickScanService.updateMLThresholds()
                    print("✅ Marked classification as CORRECT")
                }) {
                    Label("Correct", systemImage: "hand.thumbsup.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(getButtonColor(for: .correct))
                        .cornerRadius(25)
                        .scaleEffect(selectedFeedback == .correct ? 1.05 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: selectedFeedback)
                }
                
                // Incorrect classification
                Button(action: {
                    selectedFeedback = .incorrect
                    showingFeedbackOptions = true
                    print("❌ Opening correction interface")
                }) {
                    Label("Incorrect", systemImage: "hand.thumbsdown.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(getButtonColor(for: .incorrect))
                        .cornerRadius(25)
                        .scaleEffect(selectedFeedback == .incorrect ? 1.05 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: selectedFeedback)
                }
            }
            .disabled(quickScanService.isPhotoRated(result.asset.localIdentifier))
            
            // Show confirmation message
            if let feedback = selectedFeedback {
                HStack {
                    Image(systemName: feedback == .correct ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(feedback == .correct ? .green : .orange)
                    Text(feedback == .correct ? "Thanks! Marked as correct" : "Opening correction options...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .transition(.opacity.combined(with: .slide))
                .animation(.easeInOut(duration: 0.3), value: selectedFeedback)
            } else if quickScanService.isPhotoRated(result.asset.localIdentifier) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                    Text("Previously rated")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .sheet(isPresented: $showingFeedbackOptions) {
            FeedbackCorrectionView(result: result, quickScanService: quickScanService, learningService: learningService)
        }
        .onAppear {
            // Reset feedback state for unrated photos
            if !quickScanService.isPhotoRated(result.asset.localIdentifier) {
                selectedFeedback = nil
            }
            photoId = result.asset.localIdentifier
        }
        .onChange(of: result.asset.localIdentifier) { newId in
            // Reset state when photo changes (swiping)
            if photoId != newId {
                selectedFeedback = nil
                showingFeedbackOptions = false
                photoId = newId
                print("🔄 Photo changed, reset feedback state: \(photoId.prefix(8)) -> \(newId.prefix(8))")
            }
        }
    }
    
    private func getButtonColor(for state: FeedbackState) -> Color {
        let isRated = quickScanService.isPhotoRated(result.asset.localIdentifier)
        
        if isRated {
            return state == .correct ? Color.green.opacity(0.5) : Color.red.opacity(0.5)
        } else if selectedFeedback == state {
            return state == .correct ? Color.green : Color.red
        } else if selectedFeedback != nil && selectedFeedback != state {
            return state == .correct ? Color.green.opacity(0.3) : Color.red.opacity(0.3)
        } else {
            return state == .correct ? Color.green : Color.red
        }
    }
}

struct DuplicateManagerView: View {
    let originalPhoto: PhotoScanResult
    let duplicates: [PhotoScanResult]
    @ObservedObject var quickScanService: QuickScanService
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhotos: Set<String> = []
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                // Header info
                VStack(spacing: 8) {
                    Text("Duplicate Management")
                        .font(.headline)
                    
                    if duplicates.isEmpty {
                        Text("No duplicates found for this photo")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Found \(duplicates.count) potential duplicate(s)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .onAppear {
                    print("📋 DuplicateManagerView appeared with \(duplicates.count) duplicates for photo \(originalPhoto.asset.localIdentifier.prefix(8))")
                }
                
                if duplicates.isEmpty {
                    // No duplicates found - offer to remove duplicate tag
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.green)
                        
                        Text("This photo appears to be unique")
                            .font(.title3)
                            .fontWeight(.semibold)
                        
                        Text("Would you like to remove the duplicate tag?")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button("Remove Duplicate Tag") {
                            quickScanService.removeDuplicateTag(from: originalPhoto.asset.localIdentifier)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    // Show duplicates in a grid
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                            // Original photo
                            DuplicatePhotoCard(
                                result: originalPhoto,
                                isOriginal: true,
                                isSelected: false,
                                onSelectionChange: { _ in }
                            )
                            
                            // Duplicate photos
                            ForEach(duplicates, id: \.id) { duplicate in
                                DuplicatePhotoCard(
                                    result: duplicate,
                                    isOriginal: false,
                                    isSelected: selectedPhotos.contains(duplicate.id),
                                    onSelectionChange: { isSelected in
                                        if isSelected {
                                            selectedPhotos.insert(duplicate.id)
                                        } else {
                                            selectedPhotos.remove(duplicate.id)
                                        }
                                    }
                                )
                            }
                        }
                        .padding()
                    }
                    
                    // Action buttons
                    VStack(spacing: 12) {
                        if !selectedPhotos.isEmpty {
                            Button("Remove Duplicate Tag from Selected (\(selectedPhotos.count))") {
                                print("🗑️ Removing duplicate tags from \(selectedPhotos.count) selected photos")
                                for photoId in selectedPhotos {
                                    print("🗑️ Removing duplicate tag from: \(photoId.prefix(8))")
                                    quickScanService.removeDuplicateTag(from: photoId)
                                }
                                print("🗑️ Finished removing tags from selected photos")
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        
                        Button("Remove All Duplicate Tags") {
                            quickScanService.removeDuplicateTag(from: originalPhoto.asset.localIdentifier)
                            for duplicate in duplicates {
                                quickScanService.removeDuplicateTag(from: duplicate.asset.localIdentifier)
                            }
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    }
                    .padding()
                }
                
                Spacer()
            }
            .navigationTitle("Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct DuplicatePhotoCard: View {
    let result: PhotoScanResult
    let isOriginal: Bool
    let isSelected: Bool
    let onSelectionChange: (Bool) -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .topLeading) {
                    result.thumbnail
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 120)
                        .clipped()
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 3)
                        )
                    
                    // Original badge
                    if isOriginal {
                        Text("ORIGINAL")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .cornerRadius(4)
                            .padding(6)
                    }
                }
                
                // Selection button for duplicates
                if !isOriginal {
                    Button(action: {
                        onSelectionChange(!isSelected)
                    }) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundColor(isSelected ? .blue : .gray)
                            .background(Color.white)
                            .clipShape(Circle())
                    }
                    .padding(6)
                }
            }
            
            // Photo info
            VStack(spacing: 2) {
                if let date = result.metadata.creationDate {
                    Text(date, style: .date)
                        .font(.caption2)
                        .foregroundColor(.primary)
                    Text(date, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("No date")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Text("\(Int(result.metadata.dimensions.width))×\(Int(result.metadata.dimensions.height))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct FeedbackCorrectionView: View {
    let result: PhotoScanResult
    @ObservedObject var quickScanService: QuickScanService
    @ObservedObject var learningService: LearningService
    @Environment(\.dismiss) private var dismiss
    @State private var correctedTags: Set<PhotoTag> = []
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Photo preview
                result.thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 150)
                    .cornerRadius(12)
                    .padding(.horizontal)
                
                Text("What should this photo be tagged as?")
                    .font(.headline)
                    .padding()
                
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(PhotoTag.allCases, id: \.self) { tag in
                        HStack {
                            Button(action: {
                                if correctedTags.contains(tag) {
                                    correctedTags.remove(tag)
                                } else {
                                    correctedTags.insert(tag)
                                }
                            }) {
                                HStack {
                                    Image(systemName: correctedTags.contains(tag) ? "checkmark.square.fill" : "square")
                                        .foregroundColor(correctedTags.contains(tag) ? .blue : .gray)
                                    Text(tag.rawValue.capitalized)
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(8)
                            }
                        }
                    }
                    
                    Button(action: {
                        correctedTags.removeAll()
                    }) {
                        HStack {
                            Image(systemName: correctedTags.isEmpty ? "checkmark.square.fill" : "square")
                                .foregroundColor(correctedTags.isEmpty ? .blue : .gray)
                            Text("Good Quality (No Issues)")
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(8)
                    }
                }
                .padding(.horizontal)
                
                Spacer()
                
                Button("Submit Correction") {
                    // Update the actual result's tags
                    quickScanService.updatePhotoTags(assetId: result.asset.localIdentifier, newTags: correctedTags)
                    
                    // Mark photo as rated
                    quickScanService.markPhotoAsRated(result.asset.localIdentifier)
                    
                    // Record the corrected feedback
                    learningService.recordFeedback(
                        for: result.asset.localIdentifier,
                        actualTags: correctedTags,
                        predictedTags: result.tags.subtracting([.unrated]),
                        isCorrect: false,
                        metadata: result.metadata
                    )
                    
                    // Update training confidence
                    quickScanService.calculateTrainingConfidence()
                    quickScanService.updateMLThresholds()
                    
                    print("🔄 Submitted correction: predicted=\(result.tags), actual=\(correctedTags)")
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .navigationTitle("Correct Classification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            correctedTags = result.tags
        }
    }
}

// Persistent learning service
class LearningService: ObservableObject {
    static let shared = LearningService()
    
    private let store = UserDefaults.standard
    private let feedbackKey = "photo_classification_feedback"
    
    private init() {
        // Initialize UserDefaults
    }
    
    func recordFeedback(
        for assetId: String,
        actualTags: Set<PhotoTag>,
        predictedTags: Set<PhotoTag>,
        isCorrect: Bool,
        metadata: PhotoMetadata
    ) {
        let feedback = ClassificationFeedback(
            assetId: assetId,
            actualTags: Array(actualTags.map { $0.rawValue }),
            predictedTags: Array(predictedTags.map { $0.rawValue }),
            isCorrect: isCorrect,
            timestamp: Date(),
            metadata: FeedbackMetadata(
                isScreenshot: metadata.isScreenshot,
                textDensity: metadata.textDensity,
                dimensions: [metadata.dimensions.width, metadata.dimensions.height],
                source: metadata.source
            )
        )
        
        // Get existing feedback
        var allFeedback = getAllFeedback()
        allFeedback.append(feedback)
        
        // Store in iCloud
        do {
            let data = try JSONEncoder().encode(allFeedback)
            store.set(data, forKey: feedbackKey)
            
            print("💾 Stored feedback locally: \(allFeedback.count) total entries")
            
            // Update classification rules based on new feedback
            updateClassificationRules()
        } catch {
            print("❌ Failed to store feedback: \(error)")
        }
    }
    
    func getAllFeedback() -> [ClassificationFeedback] {
        guard let data = store.data(forKey: feedbackKey) else { return [] }
        
        do {
            let feedback = try JSONDecoder().decode([ClassificationFeedback].self, from: data)
            return feedback
        } catch {
            print("❌ Failed to decode feedback: \(error)")
            return []
        }
    }
    
    func updateClassificationRules() {
        let feedback = getAllFeedback()
        print("🧠 Learning from \(feedback.count) feedback entries...")
        
        // Analyze feedback patterns and store improved rules
        let rules = analyzePatterns(feedback: feedback)
        
        do {
            let rulesData = try JSONEncoder().encode(rules)
            store.set(rulesData, forKey: "classification_rules")
            print("📚 Updated classification rules based on feedback")
        } catch {
            print("❌ Failed to store rules: \(error)")
        }
    }
    
    private func analyzePatterns(feedback: [ClassificationFeedback]) -> ClassificationRules {
        var rules = ClassificationRules()
        
        // Analyze screenshot detection accuracy
        let screenshotFeedback = feedback.filter { $0.metadata.isScreenshot }
        if screenshotFeedback.count >= 3 {
            let accuracy = Double(screenshotFeedback.filter { $0.isCorrect }.count) / Double(screenshotFeedback.count)
            rules.screenshotDetectionConfidence = accuracy
        }
        
        // Analyze text density patterns for screenshots
        let textHeavyCorrections = feedback.filter { 
            $0.metadata.textDensity > 0.3 && !$0.isCorrect 
        }
        if textHeavyCorrections.count >= 2 {
            rules.textDensityThresholdForScreenshot = 0.4 // Increase threshold
        }
        
        // Analyze blur detection patterns
        let blurFeedback = feedback.filter { 
            $0.predictedTags.contains("blurry") || $0.actualTags.contains("blurry")
        }
        if blurFeedback.count >= 3 {
            let falsePositives = blurFeedback.filter { 
                $0.predictedTags.contains("blurry") && !$0.actualTags.contains("blurry")
            }
            if falsePositives.count > blurFeedback.count / 2 {
                rules.blurThreshold = 0.03 // Make even more strict
            }
        }
        
        return rules
    }
    
    func getClassificationRules() -> ClassificationRules {
        guard let data = store.data(forKey: "classification_rules") else {
            return ClassificationRules() // Default rules
        }
        
        do {
            return try JSONDecoder().decode(ClassificationRules.self, from: data)
        } catch {
            print("❌ Failed to decode rules: \(error)")
            return ClassificationRules()
        }
    }
    
    func importFeedback(_ feedback: [ClassificationFeedback]) {
        do {
            let data = try JSONEncoder().encode(feedback)
            store.set(data, forKey: feedbackKey)
            print("📥 Imported \(feedback.count) feedback entries")
        } catch {
            print("❌ Failed to import feedback: \(error)")
        }
    }
    
    func importRules(_ rules: ClassificationRules) {
        do {
            let rulesData = try JSONEncoder().encode(rules)
            store.set(rulesData, forKey: "classification_rules")
            print("📥 Imported classification rules")
        } catch {
            print("❌ Failed to import rules: \(error)")
        }
    }
    
    func clearAllFeedback() {
        store.removeObject(forKey: feedbackKey)
        store.removeObject(forKey: "classification_rules")
        print("🧹 Cleared all learning service feedback and rules")
    }
}

struct ClassificationFeedback: Codable {
    let assetId: String
    let actualTags: [String]
    let predictedTags: [String]
    let isCorrect: Bool
    let timestamp: Date
    let metadata: FeedbackMetadata
}

struct FeedbackMetadata: Codable {
    let isScreenshot: Bool
    let textDensity: Double
    let dimensions: [Double]
    let source: String?
}

struct ClassificationRules: Codable {
    var screenshotDetectionConfidence: Double = 0.9
    var textDensityThresholdForScreenshot: Double = 0.3
    var blurThreshold: Double = 0.05
    var lowQualityThreshold: Double = 0.2
    var temporalDuplicateThreshold: Double = 5.0
    
    private enum CodingKeys: String, CodingKey {
        case screenshotDetectionConfidence
        case textDensityThresholdForScreenshot
        case blurThreshold
        case lowQualityThreshold
        case temporalDuplicateThreshold
        case underexposureThreshold // Old key for backwards compatibility
    }
    
    init() {
        // Default initializer with default values
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        screenshotDetectionConfidence = try container.decodeIfPresent(Double.self, forKey: .screenshotDetectionConfidence) ?? 0.9
        textDensityThresholdForScreenshot = try container.decodeIfPresent(Double.self, forKey: .textDensityThresholdForScreenshot) ?? 0.3
        blurThreshold = try container.decodeIfPresent(Double.self, forKey: .blurThreshold) ?? 0.05
        temporalDuplicateThreshold = try container.decodeIfPresent(Double.self, forKey: .temporalDuplicateThreshold) ?? 5.0
        
        // Handle backwards compatibility - try the new key first, then fall back to old key
        if let newThreshold = try container.decodeIfPresent(Double.self, forKey: .lowQualityThreshold) {
            lowQualityThreshold = newThreshold
        } else if let oldThreshold = try container.decodeIfPresent(Double.self, forKey: .underexposureThreshold) {
            lowQualityThreshold = oldThreshold
        } else {
            lowQualityThreshold = 0.2
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(screenshotDetectionConfidence, forKey: .screenshotDetectionConfidence)
        try container.encode(textDensityThresholdForScreenshot, forKey: .textDensityThresholdForScreenshot)
        try container.encode(blurThreshold, forKey: .blurThreshold)
        try container.encode(lowQualityThreshold, forKey: .lowQualityThreshold)
        try container.encode(temporalDuplicateThreshold, forKey: .temporalDuplicateThreshold)
    }
}

struct TrainingDataExport: Codable {
    let scanOffset: Int
    let ratedPhotos: [String]
    let photoHashes: [String: String]
    let trainingConfidence: Double
    let isTrainingComplete: Bool
    let feedback: [ClassificationFeedback]
    let rules: ClassificationRules
    let exportDate: Date
}


// MARK: - New Modern UI Components

struct ModernDashboardView: View {
    @ObservedObject var quickScanService: QuickScanService
    @State private var showingTraining = false
    @State private var animateProgress = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Training Progress Card
                    TrainingProgressCard(
                        quickScanService: quickScanService,
                        showingTraining: $showingTraining
                    )
                    .padding(.horizontal)
                    
                    // Quick Stats
                    QuickStatsView(quickScanService: quickScanService)
                        .padding(.horizontal)
                    
                    // Training Focus
                    if !quickScanService.isTrainingComplete {
                        TrainingFocusCard(quickScanService: quickScanService)
                            .padding(.horizontal)
                    }
                    
                    // Recent Activity
                    if !quickScanService.results.isEmpty {
                        RecentActivityView(quickScanService: quickScanService)
                    }
                }
                .padding(.vertical)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Echo")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        // Settings action
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.blue)
                    }
                }
            }
        }
        .sheet(isPresented: $showingTraining) {
            TrainingView(quickScanService: quickScanService)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0)) {
                animateProgress = true
            }
        }
    }
}

struct TrainingProgressCard: View {
    @ObservedObject var quickScanService: QuickScanService
    @Binding var showingTraining: Bool
    @State private var animateGradient = false
    
    var progressPercentage: Int {
        Int(quickScanService.trainingConfidence * 100)
    }
    
    var photosTrainedCount: Int {
        quickScanService.results.filter { !$0.tags.contains(.unrated) }.count
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Training Progress", systemImage: "brain")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text("\(photosTrainedCount) photos trained")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }
                
                Spacer()
                
                // Circular progress indicator
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 4)
                        .frame(width: 60, height: 60)
                    
                    Circle()
                        .trim(from: 0, to: quickScanService.trainingConfidence)
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: 60, height: 60)
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(), value: quickScanService.trainingConfidence)
                    
                    Text("\(progressPercentage)%")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
            }
            
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.3))
                        .frame(height: 12)
                    
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white)
                        .frame(
                            width: geometry.size.width * quickScanService.trainingConfidence,
                            height: 12
                        )
                        .animation(.spring(), value: quickScanService.trainingConfidence)
                }
            }
            .frame(height: 12)
            
            // Action buttons
            HStack(spacing: 12) {
                if quickScanService.isTrainingComplete {
                    Button(action: {
                        quickScanService.startFullScan()
                    }) {
                        Label("Start Full Scan", systemImage: "bolt.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white)
                            .cornerRadius(12)
                    }
                } else {
                    Button(action: {
                        if quickScanService.results.isEmpty {
                            // Start initial training
                            quickScanService.isScanning = true
                            quickScanService.scanAllAssets()
                        } else {
                            // Continue training
                            showingTraining = true
                        }
                    }) {
                        Label(
                            quickScanService.results.isEmpty ? "Start Training" : "Continue Training",
                            systemImage: "play.fill"
                        )
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white)
                        .cornerRadius(12)
                    }
                    
                    if !quickScanService.results.isEmpty {
                        Button(action: {
                            quickScanService.scanAllAssets()
                        }) {
                            Label("Scan More", systemImage: "plus.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.3))
                                .cornerRadius(12)
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: animateGradient ? [Color.blue, Color.purple] : [Color.purple, Color.blue],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: animateGradient)
        )
        .cornerRadius(20)
        .shadow(color: Color.blue.opacity(0.3), radius: 20, y: 10)
        .onAppear {
            animateGradient = true
        }
    }
}

struct QuickStatsView: View {
    @ObservedObject var quickScanService: QuickScanService
    
    var stats: [(String, Int, Color, String)] {
        let results = quickScanService.results
        return [
            ("Duplicates", results.filter { $0.tags.contains(.duplicate) }.count, .orange, "doc.on.doc"),
            ("Blurry", results.filter { $0.tags.contains(.blurry) }.count, .purple, "camera.filters"),
            ("Low Quality", results.filter { $0.tags.contains(.lowQuality) }.count, .red, "exclamationmark.triangle"),
            ("Good", results.filter { $0.tags.isEmpty || $0.tags == [.unrated] }.count, .green, "checkmark.circle")
        ]
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Stats")
                .font(.headline)
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(stats, id: \.0) { stat in
                    StatCard(
                        title: stat.0,
                        count: stat.1,
                        color: stat.2,
                        icon: stat.3
                    )
                }
            }
        }
    }
}

struct StatCard: View {
    let title: String
    let count: Int
    let color: Color
    let icon: String
    @State private var animateCount = false
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                Spacer()
            }
            
            HStack {
                Text("\(animateCount ? count : 0)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(color)
                    .animation(.spring(), value: animateCount)
                Spacer()
            }
            
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                animateCount = true
            }
        }
    }
}

struct TrainingFocusCard: View {
    @ObservedObject var quickScanService: QuickScanService
    
    var focusMessage: String {
        let results = quickScanService.results
        let blurryCount = results.filter { $0.tags.contains(.blurry) }.count
        let screenshotCount = results.filter { $0.tags.contains(.screenshot) }.count
        
        if quickScanService.trainingConfidence < 0.5 {
            return "Keep training to improve accuracy! The AI is learning your preferences."
        } else if blurryCount > screenshotCount {
            return "Let's improve blur detection accuracy! The AI needs more examples of blurry vs sharp photos."
        } else {
            return "Great progress! Focus on screenshot detection to reach 99% accuracy."
        }
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Label("Training Focus", systemImage: "target")
                    .font(.headline)
                    .foregroundColor(.orange)
                
                Text(focusMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(nil)
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(16)
    }
}

struct RecentActivityView: View {
    @ObservedObject var quickScanService: QuickScanService
    @State private var selectedPhoto: PhotoScanResult?
    
    var recentPhotos: [PhotoScanResult] {
        Array(quickScanService.results.prefix(10))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Analysis")
                    .font(.headline)
                Spacer()
                NavigationLink("View All") {
                    CleanupView(quickScanService: quickScanService)
                }
                .font(.subheadline)
                .foregroundColor(.blue)
            }
            .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recentPhotos) { photo in
                        RecentPhotoCard(photo: photo)
                            .onTapGesture {
                                selectedPhoto = photo
                            }
                    }
                }
                .padding(.horizontal)
            }
        }
        .sheet(item: $selectedPhoto) { photo in
            PhotoDetailSheet(photo: photo, quickScanService: quickScanService)
        }
    }
}

struct RecentPhotoCard: View {
    let photo: PhotoScanResult
    
    var statusIcon: String {
        if photo.tags.isEmpty || photo.tags == [.unrated] {
            return "checkmark.circle.fill"
        } else if photo.tags.contains(.duplicate) {
            return "doc.on.doc.fill"
        } else if photo.tags.contains(.blurry) {
            return "camera.filters"
        } else if photo.tags.contains(.screenshot) {
            return "rectangle.on.rectangle"
        } else {
            return "exclamationmark.triangle.fill"
        }
    }
    
    var statusColor: Color {
        if photo.tags.isEmpty || photo.tags == [.unrated] {
            return .green
        } else if photo.tags.contains(.duplicate) {
            return .orange
        } else if photo.tags.contains(.blurry) {
            return .purple
        } else {
            return .red
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                HighQualityImageView(asset: photo.asset)
                    .frame(width: 100, height: 100)
                    .cornerRadius(12)
                
                Image(systemName: statusIcon)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(4)
                    .background(statusColor)
                    .clipShape(Circle())
                    .offset(x: -4, y: 4)
            }
            
            if !photo.tags.isEmpty && photo.tags != [.unrated] {
                Text(photo.tags.first?.rawValue.capitalized ?? "")
                    .font(.caption2)
                    .foregroundColor(statusColor)
                    .padding(.top, 4)
            }
        }
        .frame(width: 100)
    }
}

struct PhotoDetailSheet: View {
    let photo: PhotoScanResult
    @ObservedObject var quickScanService: QuickScanService
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                HighQualityImageView(asset: photo.asset)
                    .frame(maxHeight: 400)
                    .cornerRadius(20)
                    .padding()
                
                AIPredictionCard(photo: photo)
                    .padding(.horizontal)
                
                Spacer()
                
                if photo.tags.contains(.unrated) {
                    FeedbackInterface(result: photo, quickScanService: quickScanService)
                        .padding()
                }
            }
            .navigationTitle("Photo Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Training View Components

struct TrainingView: View {
    @ObservedObject var quickScanService: QuickScanService
    @State private var currentIndex = 0
    @State private var showingCorrection = false
    @State private var dragOffset: CGSize = .zero
    @State private var feedbackGiven = false
    @Environment(\.dismiss) private var dismiss
    
    // Dynamic training - continuously scan and add new photos
    @State private var trainingPhotos: [PhotoScanResult] = []
    @State private var isLoadingMore = false
    
    // UI state management to prevent race conditions
    @State private var isProcessingFeedback = false
    @State private var isNavigating = false
    
    // Computed property to determine when UI should be disabled
    private var isUIBusy: Bool {
        return isProcessingFeedback || isNavigating || isLoadingMore || quickScanService.isScanning
    }
    
    private var currentPhoto: PhotoScanResult? {
        guard currentIndex < trainingPhotos.count else { return nil }
        let trainingPhoto = trainingPhotos[currentIndex]
        
        // Always get the most up-to-date version from the main results array
        if let updatedPhoto = quickScanService.results.first(where: { $0.id == trainingPhoto.id }) {
            return updatedPhoto
        }
        
        // Fallback to the training photo if not found in results (shouldn't happen)
        return trainingPhoto
    }
    
    var body: some View {
        let _ = DebugLogger.log("TrainingView body computed - currentIndex: \(currentIndex), trainingPhotos.count: \(trainingPhotos.count), feedbackGiven: \(feedbackGiven)", category: "TRAINING_VIEW")
        let _ = currentPhoto.map { photo in
            DebugLogger.logImageState("Current photo in body", imageId: photo.id)
        }
        
        NavigationStack {
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [Color.blue.opacity(0.05), Color.purple.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                if let photo = currentPhoto {
                    VStack(spacing: 0) {
                        // Progress indicator - show continuous progress
                        ContinuousTrainingProgressBar(
                            current: currentIndex + 1,
                            totalScanned: trainingPhotos.count,
                            isLoadingMore: isLoadingMore
                        )
                        .padding()
                        
                        // Photo card with swipe - check if it's a duplicate AND has actual duplicates
                        if photo.tags.contains(.duplicate) {
                            DuplicateComparisonCard(
                                photo: photo,
                                quickScanService: quickScanService,
                                dragOffset: dragOffset
                            )
                            .id(photo.id) // Force recreation when photo changes
                            .offset(x: dragOffset.width)
                            .rotationEffect(.degrees(Double(dragOffset.width / 20)))
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        if !feedbackGiven {
                                            dragOffset = value.translation
                                            DebugLogger.log("Duplicate card drag changed - translation: \(value.translation)", category: "DRAG_GESTURE")
                                        } else {
                                            DebugLogger.log("Duplicate card drag ignored - feedback already given", category: "DRAG_GESTURE")
                                        }
                                    }
                                    .onEnded { value in
                                        DebugLogger.logUserAction("Duplicate card drag ended", details: "translation: \(value.translation), feedbackGiven: \(feedbackGiven)")
                                        if !feedbackGiven {
                                            if value.translation.width > 100 {
                                                DebugLogger.logUserAction("Duplicate card swipe right", details: "navigating to next")
                                                navigateToNext()
                                            } else if value.translation.width < -100 {
                                                DebugLogger.logUserAction("Duplicate card swipe left", details: "navigating to previous")
                                                navigateToPrevious()
                                            } else {
                                                DebugLogger.log("Duplicate card swipe too short", category: "DRAG_GESTURE")
                                            }
                                            withAnimation(.spring()) {
                                                dragOffset = .zero
                                            }
                                        }
                                    }
                            )
                            .padding(.horizontal)
                        } else {
                            PhotoReviewCard(
                                photo: photo,
                                dragOffset: dragOffset
                            )
                            .id(photo.id) // Force recreation when photo changes
                            .offset(x: dragOffset.width)
                            .rotationEffect(.degrees(Double(dragOffset.width / 20)))
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        if !feedbackGiven {
                                            dragOffset = value.translation
                                            DebugLogger.log("Regular card drag changed - translation: \(value.translation)", category: "DRAG_GESTURE")
                                        } else {
                                            DebugLogger.log("Regular card drag ignored - feedback already given", category: "DRAG_GESTURE")
                                        }
                                    }
                                    .onEnded { value in
                                        DebugLogger.logUserAction("Regular card drag ended", details: "translation: \(value.translation), feedbackGiven: \(feedbackGiven)")
                                        if !feedbackGiven {
                                            if value.translation.width > 100 {
                                                DebugLogger.logUserAction("Regular card swipe right", details: "navigating to next")
                                                navigateToNext()
                                            } else if value.translation.width < -100 {
                                                DebugLogger.logUserAction("Regular card swipe left", details: "navigating to previous")
                                                navigateToPrevious()
                                            } else {
                                                DebugLogger.log("Regular card swipe too short", category: "DRAG_GESTURE")
                                            }
                                            withAnimation(.spring()) {
                                                dragOffset = .zero
                                            }
                                        }
                                    }
                            )
                            .padding(.horizontal)
                        }
                        
                        // AI Prediction
                        AIPredictionCard(photo: photo)
                            .padding()
                        
                        // Feedback buttons - auto-advance after feedback
                        if !isUIBusy {
                            FeedbackButtons(
                                onCorrect: handleCorrectFeedback,
                                onWrong: handleWrongFeedback
                            )
                            .padding()
                            .opacity(feedbackGiven ? 0.5 : 1.0) // Dim buttons during transition
                            .disabled(feedbackGiven || isUIBusy)
                        } else {
                            // Show loading state when UI is busy
                            VStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(1.2)
                                Text("Processing...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .frame(height: 80) // Match approximate height of feedback buttons
                        }
                        
                        // Interaction hint
                        if !feedbackGiven {
                            Text("Rate the AI's prediction to continue")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.bottom)
                        } else {
                            Text("Loading next photo...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.bottom)
                        }
                    }
                } else {
                    // Training complete
                    TrainingCompleteView(quickScanService: quickScanService)
                }
            }
        }
        .navigationTitle("Training Mode")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Start dynamic training - load initial batch
            loadInitialTrainingPhotos()
        }
        .sheet(isPresented: $showingCorrection) {
            if let photo = currentPhoto {
                CorrectionView(
                    photo: photo,
                    quickScanService: quickScanService,
                    onComplete: {
                        feedbackGiven = true
                        showingCorrection = false
                        
                        // Automatically advance to next photo after correction
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.navigateToNext()
                        }
                    }
                )
            }
        }
    }
    
    private func loadInitialTrainingPhotos() {
        DebugLogger.log("Loading initial training photos", category: "TRAINING_SESSION")
        
        // Start with existing unrated photos if any
        let existingUnrated = quickScanService.results.filter { $0.tags.contains(.unrated) }
        trainingPhotos = Array(existingUnrated.prefix(8)) // Start with more photos for better buffer
        
        DebugLogger.log("Initial batch loaded: \(trainingPhotos.count) photos", category: "TRAINING_SESSION")
        
        // Always preload more photos to maintain buffer - start scanning if we have less than 6 photos
        if trainingPhotos.count < 6 {
            DebugLogger.log("Initial batch too small (\(trainingPhotos.count)), starting background scan", category: "TRAINING_SESSION")
            loadMoreTrainingPhotos()
        }
    }
    
    private func loadMoreTrainingPhotos() {
        guard !isLoadingMore else { return }
        
        isLoadingMore = true
        DebugLogger.log("Loading more training photos in background", category: "TRAINING_SESSION")
        
        // Trigger background scanning for more photos
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Get newly scanned photos that aren't already in our training set
            let currentIds = Set(self.trainingPhotos.map { $0.id })
            let allUnratedPhotos = self.quickScanService.results.filter { result in
                // Must have unrated tag AND not be already rated (double check)
                result.tags.contains(.unrated) && !self.quickScanService.isPhotoRated(result.asset.localIdentifier)
            }
            let newUnratedPhotos = allUnratedPhotos.filter { !currentIds.contains($0.id) }
            
            DebugLogger.log("Found \(allUnratedPhotos.count) total unrated photos, \(newUnratedPhotos.count) are new", category: "TRAINING_SESSION")
            
            // Add more photos to maintain buffer - load up to 8 new photos at once
            let photosToAdd = Array(newUnratedPhotos.prefix(8))
            let oldCount = self.trainingPhotos.count
            self.trainingPhotos.append(contentsOf: photosToAdd)
            self.isLoadingMore = false
            
            DebugLogger.log("Added \(photosToAdd.count) photos to training array, total: \(self.trainingPhotos.count)", category: "TRAINING_SESSION")
            
            // Log the new photos being added
            for (index, photo) in photosToAdd.enumerated() {
                DebugLogger.logImageState("Added to training array [\(index)]", imageId: photo.id)
            }
            
            // Check if we can now navigate after loading new photos
            let wasAtEnd = self.currentIndex >= oldCount - 1
            let canNavigateNow = self.currentIndex < self.trainingPhotos.count - 1
            
            if wasAtEnd && canNavigateNow {
                DebugLogger.log("Navigation now possible after loading, continuing...", category: "TRAINING_SESSION")
                // Small delay to ensure UI is updated
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.navigateToNext()
                }
            }
            
            // If we still need more photos and no new ones were found, trigger another scan
            if photosToAdd.isEmpty && !self.quickScanService.isScanning {
                DebugLogger.log("No new unrated photos found, triggering another scan", category: "TRAINING_SESSION")
                self.quickScanService.scanAllAssets()
            }
        }
    }
    
    private func handleCorrectFeedback() {
        // Prevent multiple rapid taps
        guard !isProcessingFeedback else { 
            DebugLogger.log("Ignoring correct feedback - already processing", category: "FEEDBACK_THROTTLE")
            return 
        }
        
        DebugLogger.logUserAction("CORRECT button tapped", details: "currentIndex: \(currentIndex)")
        guard let photo = currentPhoto else { 
            DebugLogger.log("ERROR: No current photo when handling correct feedback", category: "FEEDBACK_ERROR")
            return 
        }
        
        // Set processing state
        isProcessingFeedback = true
        
        DebugLogger.logImageState("Marking as correct", imageId: photo.id)
        DebugLogger.log("Photo tags before feedback: \(photo.tags)", category: "FEEDBACK")
        
        withAnimation(.easeInOut(duration: 0.3)) {
            feedbackGiven = true
            DebugLogger.log("feedbackGiven set to true", category: "FEEDBACK")
        }
        
        // Record correct feedback
        quickScanService.markPhotoAsRated(photo.asset.localIdentifier)
        LearningService.shared.recordFeedback(
            for: photo.asset.localIdentifier,
            actualTags: photo.tags.subtracting([.unrated]),
            predictedTags: photo.tags.subtracting([.unrated]),
            isCorrect: true,
            metadata: photo.metadata
        )
        quickScanService.calculateTrainingConfidence()
        
        DebugLogger.log("Correct feedback recorded for photo \(photo.id.prefix(8))", category: "FEEDBACK")
        
        // Haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        // Automatically advance to next photo after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Clear processing state before navigation
            self.isProcessingFeedback = false
            self.navigateToNext()
        }
    }
    
    private func handleWrongFeedback() {
        // Prevent multiple rapid taps
        guard !isProcessingFeedback else { 
            DebugLogger.log("Ignoring wrong feedback - already processing", category: "FEEDBACK_THROTTLE")
            return 
        }
        
        DebugLogger.logUserAction("WRONG button tapped", details: "currentIndex: \(currentIndex)")
        guard let photo = currentPhoto else {
            DebugLogger.log("ERROR: No current photo when handling wrong feedback", category: "FEEDBACK_ERROR")
            return
        }
        
        // Set processing state
        isProcessingFeedback = true
        
        DebugLogger.logImageState("Opening correction view", imageId: photo.id)
        showingCorrection = true
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    
    private func navigateToNext() {
        // Prevent multiple rapid navigation calls
        guard !isNavigating else {
            DebugLogger.log("Ignoring navigation - already navigating", category: "NAVIGATION_THROTTLE")
            return
        }
        
        DebugLogger.logUserAction("Navigate to NEXT", details: "currentIndex: \(currentIndex), trainingPhotos.count: \(trainingPhotos.count)")
        
        // Always keep at least 3 photos ahead - start loading when only 3 photos remain
        let remainingPhotos = trainingPhotos.count - currentIndex - 1
        DebugLogger.log("Remaining photos: \(remainingPhotos), should preload: \(remainingPhotos <= 3)", category: "PRELOAD_CHECK")
        
        // If we need to load more photos and can navigate to next, do it first
        if remainingPhotos <= 3 && !isLoadingMore {
            DebugLogger.log("Preloading more photos - only \(remainingPhotos) photos remaining", category: "PRELOAD")
            loadMoreTrainingPhotos()
        }
        
        let canNavigateNext = currentIndex < trainingPhotos.count - 1
        DebugLogger.log("Can navigate next: \(canNavigateNext), currentIndex: \(currentIndex), trainingPhotos.count: \(trainingPhotos.count)", category: "NAVIGATION")
        
        if canNavigateNext {
            // Set navigation state
            isNavigating = true
            
            let oldIndex = currentIndex
            withAnimation(.easeInOut(duration: 0.3)) {
                currentIndex += 1
                feedbackGiven = false
                dragOffset = .zero
            }
            DebugLogger.log("Navigated from index \(oldIndex) to \(currentIndex)", category: "NAVIGATION")
            
            if let newPhoto = currentPhoto {
                DebugLogger.logImageState("New current photo after navigation", imageId: newPhoto.id)
                DebugLogger.log("📸 Photo details - Tags: \(newPhoto.tags), Creation: \(newPhoto.metadata.creationDate?.description.suffix(8) ?? "nil"), Size: \(Int(newPhoto.metadata.dimensions.width))x\(Int(newPhoto.metadata.dimensions.height))", category: "PHOTO_DETAILS")
            } else {
                DebugLogger.log("ERROR: No photo at new index \(currentIndex)", category: "NAVIGATION_ERROR")
            }
            
            // Clear navigation state after successful navigation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.isNavigating = false
            }
        } else if !isLoadingMore && remainingPhotos <= 0 {
            // No more photos available and not currently loading
            DebugLogger.log("No more photos available - showing completion", category: "TRAINING_SESSION")
            // Clear navigation state since we're not navigating
            isNavigating = false
            // Don't dismiss automatically, let user choose to continue or finish
        }
    }
    
    private func navigateToPrevious() {
        DebugLogger.logUserAction("Navigate to PREVIOUS", details: "currentIndex: \(currentIndex)")
        
        if currentIndex > 0 {
            let oldIndex = currentIndex
            withAnimation(.easeInOut(duration: 0.3)) {
                currentIndex -= 1
                feedbackGiven = false
                dragOffset = .zero
            }
            DebugLogger.log("Navigated from index \(oldIndex) to \(currentIndex)", category: "NAVIGATION")
            
            if let newPhoto = currentPhoto {
                DebugLogger.logImageState("New current photo after previous navigation", imageId: newPhoto.id)
            } else {
                DebugLogger.log("ERROR: No photo at new index \(currentIndex)", category: "NAVIGATION_ERROR")
            }
        } else {
            DebugLogger.log("Cannot navigate previous - already at index 0", category: "NAVIGATION")
        }
    }
}

struct TrainingProgressBar: View {
    let current: Int
    let total: Int
    
    var progress: Double {
        Double(current) / Double(total)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Photo \(current) of \(total)")
                    .font(.headline)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 8)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * progress, height: 8)
                        .animation(.spring(), value: progress)
                }
            }
            .frame(height: 8)
        }
    }
}

struct ContinuousTrainingProgressBar: View {
    let current: Int
    let totalScanned: Int
    let isLoadingMore: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Photo \(current)")
                    .font(.headline)
                Spacer()
                if isLoadingMore {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Scanning...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("of \(totalScanned) scanned")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            // Continuous progress bar (no percentage since it's unlimited)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 8)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * (Double(current) / max(Double(totalScanned), 1.0)), height: 8)
                        .animation(.spring(), value: current)
                }
            }
            .frame(height: 8)
        }
    }
}

struct PhotoReviewCard: View {
    let photo: PhotoScanResult
    let dragOffset: CGSize
    @State private var imageLoaded = false
    @State private var fullSizeImage: Image? = nil
    @State private var isLoading = true
    @State private var currentPhotoId: String = ""
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 25)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.1), radius: 20, y: 10)
            
            VStack {
                ZStack {
                    if let fullSizeImage = fullSizeImage {
                        fullSizeImage
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 400)
                            .cornerRadius(20)
                            .padding()
                            .scaleEffect(imageLoaded ? 1 : 0.9)
                            .opacity(imageLoaded ? 1 : 0)
                    } else {
                        // Show thumbnail while loading
                        photo.thumbnail
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 400)
                            .cornerRadius(20)
                            .padding()
                            .blur(radius: isLoading ? 1 : 0)
                    }
                    
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(1.5)
                            .background(Color.white.opacity(0.8))
                            .cornerRadius(10)
                    }
                }
                .onAppear {
                    loadFullSizeImage()
                }
            }
            
            // Swipe indicators
            if dragOffset.width > 50 {
                HStack {
                    Image(systemName: "arrow.left.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.green)
                        .padding(.leading, 30)
                    Spacer()
                }
                .transition(.opacity)
            } else if dragOffset.width < -50 {
                HStack {
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.blue)
                        .padding(.trailing, 30)
                }
                .transition(.opacity)
            }
        }
        .frame(height: 450)
    }
    
    private func loadFullSizeImage() {
        guard fullSizeImage == nil else { return }
        
        let imageManager = PHCachingImageManager()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        
        imageManager.requestImage(
            for: photo.asset,
            targetSize: CGSize(width: 800, height: 800),
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            DispatchQueue.main.async {
                guard self.fullSizeImage == nil else { return }
                
                if let image = image {
                    self.fullSizeImage = Image(uiImage: image)
                    self.isLoading = false
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.imageLoaded = true
                    }
                }
            }
        }
    }
}

struct AIPredictionCard: View {
    let photo: PhotoScanResult
    
    var predictionText: String {
        let tags = photo.tags.subtracting([.unrated])
        if tags.isEmpty {
            return "Good Quality Photo"
        } else {
            return tags.map { tag in
                switch tag {
                case .blurry: return "Blurry"
                case .lowQuality: return "Low Quality"
                case .screenshot: return "Screenshot"
                case .duplicate: return "Duplicate"
                case .unrated: return ""
                }
            }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }
    
    var predictionIcon: String {
        let tags = photo.tags.subtracting([.unrated])
        if tags.isEmpty {
            return "✨"
        } else if tags.contains(.screenshot) {
            return "📱"
        } else if tags.contains(.blurry) {
            return "🌫️"
        } else if tags.contains(.duplicate) {
            return "🔄"
        } else if tags.contains(.lowQuality) {
            return "🌑"
        } else {
            return "📸"
        }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            Text("AI thinks this is:")
                .font(.headline)
                .foregroundColor(.secondary)
            
            HStack(spacing: 8) {
                Text(predictionIcon)
                    .font(.title2)
                Text(predictionText)
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(tagColor.opacity(0.2))
            )
            .foregroundColor(tagColor)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.white)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.05), radius: 10, y: 5)
    }
    
    var tagColor: Color {
        let tags = photo.tags.subtracting([.unrated])
        if tags.isEmpty {
            return .green
        } else if tags.contains(.screenshot) {
            return .blue
        } else if tags.contains(.blurry) {
            return .purple
        } else if tags.contains(.duplicate) {
            return .orange
        } else if tags.contains(.lowQuality) {
            return .red
        } else {
            return .gray
        }
    }
}

struct FeedbackButtons: View {
    let onCorrect: () -> Void
    let onWrong: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Is this correct?")
                .font(.title2)
                .fontWeight(.semibold)
            
            HStack(spacing: 20) {
                Button(action: {
                    DebugLogger.logUserAction("CORRECT button pressed from FeedbackButtons")
                    onCorrect()
                }) {
                    Label("Correct", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .cornerRadius(15)
                }
                
                Button(action: {
                    DebugLogger.logUserAction("WRONG button pressed from FeedbackButtons")
                    onWrong()
                }) {
                    Label("Wrong", systemImage: "xmark.circle.fill")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red)
                        .cornerRadius(15)
                }
            }
        }
    }
}

struct CorrectionView: View {
    let photo: PhotoScanResult
    @ObservedObject var quickScanService: QuickScanService
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTags: Set<PhotoTag> = []
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("What should this photo be tagged as?")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .padding()
                
                VStack(spacing: 12) {
                    CorrectionOption(
                        title: "Good Quality",
                        icon: "✨",
                        isSelected: selectedTags.isEmpty,
                        color: .green
                    ) {
                        selectedTags = []
                    }
                    
                    CorrectionOption(
                        title: "Blurry",
                        icon: "🌫️",
                        isSelected: selectedTags.contains(.blurry),
                        color: .purple
                    ) {
                        toggleTag(.blurry)
                    }
                    
                    CorrectionOption(
                        title: "Low Quality",
                        icon: "🌑",
                        isSelected: selectedTags.contains(.lowQuality),
                        color: .red
                    ) {
                        toggleTag(.lowQuality)
                    }
                    
                    CorrectionOption(
                        title: "Screenshot",
                        icon: "📱",
                        isSelected: selectedTags.contains(.screenshot),
                        color: .blue
                    ) {
                        toggleTag(.screenshot)
                    }
                    
                    CorrectionOption(
                        title: "Duplicate",
                        icon: "🔄",
                        isSelected: selectedTags.contains(.duplicate),
                        color: .orange
                    ) {
                        toggleTag(.duplicate)
                    }
                }
                .padding()
                
                Spacer()
                
                Button(action: saveCorrection) {
                    Text("Update Classification")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(15)
                }
                .padding()
            }
            .navigationTitle("Correct Classification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func toggleTag(_ tag: PhotoTag) {
        if tag == .blurry || tag == .lowQuality || tag == .screenshot || tag == .duplicate {
            if selectedTags.contains(tag) {
                selectedTags.remove(tag)
            } else {
                selectedTags.insert(tag)
            }
        }
    }
    
    private func saveCorrection() {
        DebugLogger.logUserAction("SAVE CORRECTION", details: "assetId: \(photo.asset.localIdentifier.prefix(8))")
        DebugLogger.log("Original tags: \(photo.tags)", category: "CORRECTION")
        DebugLogger.log("New tags: \(selectedTags)", category: "CORRECTION")
        
        // If this was a duplicate and now it's not, we need to handle smart duplicate removal
        if photo.tags.contains(.duplicate) && !selectedTags.contains(.duplicate) {
            DebugLogger.log("User says this photo is NOT a duplicate - handling smart removal", category: "DUPLICATE_REMOVAL")
            let currentDuplicates = quickScanService.findDuplicatesFor(assetId: photo.asset.localIdentifier)
            DebugLogger.log("Found \(currentDuplicates.count) current duplicates for this photo", category: "DUPLICATE_REMOVAL")
            
            // For each duplicate of this photo, check if they have OTHER duplicates
            for duplicate in currentDuplicates {
                DebugLogger.logImageState("Checking if duplicate has other relationships", imageId: duplicate.id)
                
                // Find all duplicates of this duplicate photo
                let allDuplicatesOfDuplicate = quickScanService.findDuplicatesFor(assetId: duplicate.asset.localIdentifier)
                
                // Remove the current photo from that list to see remaining duplicates
                let otherDuplicates = allDuplicatesOfDuplicate.filter { $0.asset.localIdentifier != photo.asset.localIdentifier }
                
                DebugLogger.log("Duplicate \(duplicate.id.prefix(8)) has \(otherDuplicates.count) other duplicate relationships", category: "DUPLICATE_REMOVAL")
                
                // Only remove duplicate tag if this photo has NO other duplicates
                if otherDuplicates.isEmpty {
                    DebugLogger.log("Removing duplicate tag from \(duplicate.id.prefix(8)) - no other duplicates found", category: "DUPLICATE_REMOVAL")
                    var duplicateTags = duplicate.tags
                    duplicateTags.remove(.duplicate)
                    quickScanService.updatePhotoTags(assetId: duplicate.asset.localIdentifier, newTags: duplicateTags)
                } else {
                    DebugLogger.log("Keeping duplicate tag on \(duplicate.id.prefix(8)) - has \(otherDuplicates.count) other duplicates", category: "DUPLICATE_REMOVAL")
                    // Keep the duplicate tag since it has other duplicate relationships
                }
            }
            
            // The current photo will have its duplicate tag removed below in the main update
        }
        
        // Update tags
        quickScanService.updatePhotoTags(
            assetId: photo.asset.localIdentifier,
            newTags: selectedTags
        )
        
        // Mark as rated
        quickScanService.markPhotoAsRated(photo.asset.localIdentifier)
        
        // Record feedback
        LearningService.shared.recordFeedback(
            for: photo.asset.localIdentifier,
            actualTags: selectedTags,
            predictedTags: photo.tags.subtracting([.unrated]),
            isCorrect: false,
            metadata: photo.metadata
        )
        
        quickScanService.calculateTrainingConfidence()
        quickScanService.updateMLThresholds()
        
        DebugLogger.log("Correction saved successfully", category: "CORRECTION")
        
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onComplete()
        dismiss()
    }
}

struct CorrectionOption: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(icon)
                    .font(.title2)
                Text(title)
                    .font(.headline)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(color)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 15)
                    .fill(isSelected ? color.opacity(0.2) : Color.gray.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15)
                    .stroke(isSelected ? color : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct TrainingCompleteView: View {
    @ObservedObject var quickScanService: QuickScanService
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)
            
            Text("Training Session Complete!")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            VStack(spacing: 16) {
                HStack {
                    Text("Accuracy:")
                    Spacer()
                    Text("\(Int(quickScanService.trainingConfidence * 100))%")
                        .fontWeight(.semibold)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
                
                HStack {
                    Text("Photos Trained:")
                    Spacer()
                    Text("\(quickScanService.results.filter { !$0.tags.contains(.unrated) }.count)")
                        .fontWeight(.semibold)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
            }
            .padding()
            
            if quickScanService.isTrainingComplete {
                Text("🎉 Your AI is ready for a full scan!")
                    .font(.headline)
                    .foregroundColor(.green)
                
                Button(action: {
                    dismiss()
                    quickScanService.startFullScan()
                }) {
                    Text("Start Full Scan")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(15)
                }
            } else {
                Button(action: {
                    dismiss()
                }) {
                    Text("Back to Dashboard")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(15)
                }
            }
        }
        .padding()
    }
}

struct DuplicateComparisonCard: View {
    let photo: PhotoScanResult
    @ObservedObject var quickScanService: QuickScanService
    let dragOffset: CGSize
    @State private var duplicatePhoto: PhotoScanResult?
    @State private var isLoading = true
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 25)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.1), radius: 20, y: 10)
            
            VStack(spacing: 16) {
                Text("Duplicate Comparison")
                    .font(.headline)
                    .foregroundColor(.orange)
                
                if isLoading {
                    ProgressView("Finding duplicate...")
                        .progressViewStyle(CircularProgressViewStyle())
                        .frame(height: 200)
                } else if let duplicate = duplicatePhoto {
                    HStack(spacing: 12) {
                        // Original photo
                        VStack(spacing: 8) {
                            Text("Original")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.blue)
                            
                            HighQualityImageView(asset: photo.asset)
                                .frame(width: 140, height: 140)
                                .cornerRadius(12)
                        }
                        
                        VStack {
                            Image(systemName: "arrow.left.arrow.right")
                                .foregroundColor(.orange)
                                .font(.title2)
                        }
                        
                        // Duplicate photo
                        VStack(spacing: 8) {
                            Text("Duplicate?")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.red)
                            
                            HighQualityImageView(asset: duplicate.asset)
                                .frame(width: 140, height: 140)
                                .cornerRadius(12)
                        }
                    }
                } else {
                    VStack {
                        Text("No duplicates found")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HighQualityImageView(asset: photo.asset)
                            .frame(maxHeight: 300)
                            .cornerRadius(12)
                    }
                }
            }
            .padding()
            
            // Swipe indicators
            if dragOffset.width > 50 {
                HStack {
                    Image(systemName: "arrow.left.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.green)
                        .padding(.leading, 30)
                    Spacer()
                }
                .transition(.opacity)
            } else if dragOffset.width < -50 {
                HStack {
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.blue)
                        .padding(.trailing, 30)
                }
                .transition(.opacity)
            }
        }
        .frame(height: 450)
        .onAppear {
            findDuplicate()
        }
    }
    
    private func findDuplicate() {
        let duplicates = quickScanService.findDuplicatesFor(assetId: photo.id)
        duplicatePhoto = duplicates.first
        isLoading = false
    }
}

struct HighQualityImageView: View {
    let asset: PHAsset
    @State private var image: Image? = nil
    @State private var isLoading = true
    
    var body: some View {
        ZStack {
            if let image = image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else {
                Color.gray.opacity(0.3)
                
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                }
            }
        }
        .onAppear {
            loadHighQualityImage()
        }
    }
    
    private func loadHighQualityImage() {
        guard image == nil else { return }
        
        let imageManager = PHCachingImageManager()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        
        imageManager.requestImage(
            for: asset,
            targetSize: CGSize(width: 600, height: 600),
            contentMode: .aspectFill,
            options: options
        ) { uiImage, info in
            DispatchQueue.main.async {
                guard self.image == nil else { return }
                
                if let uiImage = uiImage {
                    self.image = Image(uiImage: uiImage)
                }
                self.isLoading = false
            }
        }
    }
}

// MARK: - Modern Cleanup View Components

struct ModernCleanupView: View {
    @ObservedObject var quickScanService: QuickScanService
    @State private var selectedCategory: CleanupCategory = .all
    @State private var selectedPhotos: Set<String> = []
    @State private var showingDeleteConfirmation = false
    @State private var showingDuplicateGroups = false
    
    enum CleanupCategory: String, CaseIterable {
        case all = "All Issues"
        case duplicates = "Duplicates"
        case blurry = "Blurry"
        case lowQuality = "Low Quality"
        case screenshots = "Screenshots"
        
        var icon: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .duplicates: return "doc.on.doc"
            case .blurry: return "camera.filters"
            case .lowQuality: return "exclamationmark.triangle"
            case .screenshots: return "rectangle.on.rectangle"
            }
        }
        
        var color: Color {
            switch self {
            case .all: return .blue
            case .duplicates: return .orange
            case .blurry: return .purple
            case .lowQuality: return .red
            case .screenshots: return .indigo
            }
        }
    }
    
    var filteredResults: [PhotoScanResult] {
        switch selectedCategory {
        case .all:
            return quickScanService.results.filter { !$0.tags.isEmpty && $0.tags != [.unrated] }
        case .duplicates:
            return quickScanService.results.filter { $0.tags.contains(.duplicate) }
        case .blurry:
            return quickScanService.results.filter { $0.tags.contains(.blurry) }
        case .lowQuality:
            return quickScanService.results.filter { $0.tags.contains(.lowQuality) }
        case .screenshots:
            return quickScanService.results.filter { $0.tags.contains(.screenshot) }
        }
    }
    
    var spaceToSave: String {
        let photoCount = selectedPhotos.isEmpty ? filteredResults.count : selectedPhotos.count
        let mbToSave = photoCount * 3
        if mbToSave > 1000 {
            return String(format: "%.1f GB", Double(mbToSave) / 1000.0)
        } else {
            return "\(mbToSave) MB"
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if quickScanService.results.isEmpty {
                    EmptyCleanupView()
                } else {
                    // Category selector
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(CleanupCategory.allCases, id: \.self) { category in
                                CategoryChip(
                                    category: category,
                                    isSelected: selectedCategory == category,
                                    count: getCategoryCount(category)
                                ) {
                                    withAnimation(.spring()) {
                                        selectedCategory = category
                                        selectedPhotos.removeAll()
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                    .background(Color(UIColor.systemBackground))
                    
                    if filteredResults.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.green)
                            
                            Text("No \(selectedCategory.rawValue) Found")
                                .font(.title2)
                                .fontWeight(.semibold)
                            
                            Text("Your photos look great in this category!")
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(UIColor.systemGroupedBackground))
                    } else {
                        // Quick actions for duplicates
                        if selectedCategory == .duplicates {
                            DuplicateActionBar(
                                quickScanService: quickScanService,
                                showingDuplicateGroups: $showingDuplicateGroups
                            )
                        }
                        
                        // Photo grid
                        ScrollView {
                            LazyVGrid(columns: [
                                GridItem(.adaptive(minimum: 110), spacing: 2)
                            ], spacing: 2) {
                                ForEach(filteredResults) { photo in
                                    CleanupPhotoCell(
                                        photo: photo,
                                        isSelected: selectedPhotos.contains(photo.id),
                                        onTap: {
                                            if selectedPhotos.contains(photo.id) {
                                                selectedPhotos.remove(photo.id)
                                            } else {
                                                selectedPhotos.insert(photo.id)
                                            }
                                        }
                                    )
                                }
                            }
                            .padding(.bottom, 100)
                        }
                        .background(Color(UIColor.systemGroupedBackground))
                    }
                }
            }
            .navigationTitle("Cleanup")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !filteredResults.isEmpty {
                        Button(selectedPhotos.isEmpty ? "Select All" : "Deselect All") {
                            if selectedPhotos.isEmpty {
                                selectedPhotos = Set(filteredResults.map { $0.id })
                            } else {
                                selectedPhotos.removeAll()
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !selectedPhotos.isEmpty {
                    CleanupActionBar(
                        selectedCount: selectedPhotos.count,
                        spaceToSave: spaceToSave,
                        onDelete: {
                            showingDeleteConfirmation = true
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $showingDuplicateGroups) {
            DuplicateGroupsView(quickScanService: quickScanService)
        }
        .alert("Delete Photos", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteSelectedPhotos()
            }
        } message: {
            Text("Are you sure you want to delete \(selectedPhotos.count) photos? This will free up approximately \(spaceToSave) of storage.")
        }
    }
    
    private func getCategoryCount(_ category: CleanupCategory) -> Int {
        switch category {
        case .all:
            return quickScanService.results.filter { !$0.tags.isEmpty && $0.tags != [.unrated] }.count
        case .duplicates:
            return quickScanService.results.filter { $0.tags.contains(.duplicate) }.count
        case .blurry:
            return quickScanService.results.filter { $0.tags.contains(.blurry) }.count
        case .lowQuality:
            return quickScanService.results.filter { $0.tags.contains(.lowQuality) }.count
        case .screenshots:
            return quickScanService.results.filter { $0.tags.contains(.screenshot) }.count
        }
    }
    
    private func deleteSelectedPhotos() {
        Task {
            await quickScanService.deletePhotos(withIds: Array(selectedPhotos))
            await MainActor.run {
                selectedPhotos.removeAll()
            }
        }
    }
}

struct CategoryChip: View {
    let category: ModernCleanupView.CleanupCategory
    let isSelected: Bool
    let count: Int
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.system(size: 14, weight: .semibold))
                
                Text(category.rawValue)
                    .font(.system(size: 14, weight: .semibold))
                
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.white.opacity(0.3) : category.color.opacity(0.2))
                        .cornerRadius(10)
                }
            }
            .foregroundColor(isSelected ? .white : category.color)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(isSelected ? category.color : category.color.opacity(0.1))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct CleanupPhotoCell: View {
    let photo: PhotoScanResult
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                HighQualityImageView(asset: photo.asset)
                    .frame(width: 110, height: 110)
                
                if isSelected {
                    Color.blue.opacity(0.3)
                }
            }
            .onTapGesture {
                onTap()
            }
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .background(Color.blue)
                    .clipShape(Circle())
                    .padding(8)
            } else {
                if let firstTag = photo.tags.first(where: { $0 != .unrated }) {
                    Image(systemName: tagIcon(for: firstTag))
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(4)
                        .background(tagColor(for: firstTag))
                        .clipShape(Circle())
                        .padding(4)
                }
            }
        }
    }
    
    private func tagIcon(for tag: PhotoTag) -> String {
        switch tag {
        case .duplicate: return "doc.on.doc.fill"
        case .blurry: return "camera.filters"
        case .lowQuality: return "exclamationmark.triangle.fill"
        case .screenshot: return "rectangle.on.rectangle"
        case .unrated: return "questionmark"
        }
    }
    
    private func tagColor(for tag: PhotoTag) -> Color {
        switch tag {
        case .duplicate: return .orange
        case .blurry: return .purple
        case .lowQuality: return .red
        case .screenshot: return .indigo
        case .unrated: return .gray
        }
    }
}

struct CleanupActionBar: View {
    let selectedCount: Int
    let spaceToSave: String
    let onDelete: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(selectedCount) photos selected")
                        .font(.headline)
                    Text("~\(spaceToSave) to free up")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: onDelete) {
                    Label("Delete", systemImage: "trash.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.red)
                        .cornerRadius(25)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
        .background(.ultraThinMaterial)
    }
}

struct DuplicateActionBar: View {
    @ObservedObject var quickScanService: QuickScanService
    @Binding var showingDuplicateGroups: Bool
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ActionButton(
                    title: "Smart Cleanup",
                    subtitle: "Keep best of each group",
                    icon: "wand.and.stars",
                    color: .blue
                ) {
                    showingDuplicateGroups = true
                }
                
                ActionButton(
                    title: "Review Groups",
                    subtitle: "See duplicate sets",
                    icon: "rectangle.stack",
                    color: .orange
                ) {
                    showingDuplicateGroups = true
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground))
    }
}

struct ActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                    .frame(width: 40, height: 40)
                    .background(color.opacity(0.1))
                    .cornerRadius(12)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding()
            .frame(width: 200)
            .background(Color(UIColor.tertiarySystemBackground))
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct EmptyCleanupView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Photos to Clean")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Run a scan to find photos that need cleanup")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemGroupedBackground))
    }
}

struct DuplicateGroupsView: View {
    @ObservedObject var quickScanService: QuickScanService
    @Environment(\.dismiss) private var dismiss
    @State private var duplicateGroups: [[PhotoScanResult]] = []
    @State private var selectedKeepers: Set<String> = []
    
    var body: some View {
        NavigationView {
            VStack {
                if duplicateGroups.isEmpty {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Finding duplicate groups...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            ForEach(Array(duplicateGroups.enumerated()), id: \.offset) { index, group in
                                DuplicateGroupCard(
                                    group: group,
                                    groupIndex: index,
                                    selectedKeeper: selectedKeepers.first(where: { id in
                                        group.contains { $0.id == id }
                                    }),
                                    onSelectKeeper: { photoId in
                                        for photo in group {
                                            selectedKeepers.remove(photo.id)
                                        }
                                        selectedKeepers.insert(photoId)
                                    }
                                )
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Duplicate Groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !duplicateGroups.isEmpty {
                        Button("Clean Up") {
                            performSmartCleanup()
                        }
                        .fontWeight(.semibold)
                        .disabled(selectedKeepers.count != duplicateGroups.count)
                    }
                }
            }
        }
        .onAppear {
            findDuplicateGroups()
        }
    }
    
    private func findDuplicateGroups() {
        var groups: [[PhotoScanResult]] = []
        var processedPhotos: Set<String> = []
        
        let duplicatePhotos = quickScanService.results.filter { $0.tags.contains(.duplicate) }
        
        for photo in duplicatePhotos {
            if processedPhotos.contains(photo.id) { continue }
            
            var group = [photo]
            processedPhotos.insert(photo.id)
            
            let relatedDuplicates = quickScanService.findDuplicatesFor(assetId: photo.id)
            for duplicate in relatedDuplicates {
                if !processedPhotos.contains(duplicate.id) {
                    group.append(duplicate)
                    processedPhotos.insert(duplicate.id)
                }
            }
            
            if group.count > 1 {
                groups.append(group)
            }
        }
        
        duplicateGroups = groups
        
        for group in groups {
            if let best = selectBestPhoto(from: group) {
                selectedKeepers.insert(best.id)
            }
        }
    }
    
    private func selectBestPhoto(from group: [PhotoScanResult]) -> PhotoScanResult? {
        return group.first { photo in
            !photo.tags.contains(.blurry) && !photo.tags.contains(.lowQuality)
        } ?? group.first
    }
    
    private func performSmartCleanup() {
        var photosToDelete: [String] = []
        
        for group in duplicateGroups {
            for photo in group {
                if !selectedKeepers.contains(photo.id) {
                    photosToDelete.append(photo.id)
                }
            }
        }
        
        Task {
            await quickScanService.deletePhotos(withIds: photosToDelete)
            await MainActor.run {
                dismiss()
            }
        }
    }
}

struct DuplicateGroupCard: View {
    let group: [PhotoScanResult]
    let groupIndex: Int
    let selectedKeeper: String?
    let onSelectKeeper: (String) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Group \(groupIndex + 1)", systemImage: "rectangle.stack")
                    .font(.headline)
                
                Spacer()
                
                Text("\(group.count) photos")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(group) { photo in
                        DuplicatePhotoOption(
                            photo: photo,
                            isSelected: photo.id == selectedKeeper,
                            onTap: {
                                onSelectKeeper(photo.id)
                            }
                        )
                    }
                }
            }
            
            if let _ = selectedKeeper {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Keeping 1 photo, deleting \(group.count - 1)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
}

struct DuplicatePhotoOption: View {
    let photo: PhotoScanResult
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    HighQualityImageView(asset: photo.asset)
                        .frame(width: 120, height: 120)
                        .cornerRadius(12)
                    
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color.green : Color.clear, lineWidth: 3)
                }
                
                if isSelected {
                    Text("KEEP")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green)
                        .cornerRadius(8)
                        .padding(4)
                }
            }
            
            HStack(spacing: 4) {
                if !photo.tags.contains(.blurry) {
                    Image(systemName: "camera.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
                if !photo.tags.contains(.lowQuality) {
                    Image(systemName: "sun.max.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .onTapGesture {
            onTap()
        }
    }
}

#Preview {
    ContentView()
}