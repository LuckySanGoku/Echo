import Foundation
import SwiftUI

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
    
    init(id: String, photoId: String, timestamp: Date, predictedTags: Set<PhotoTag>, actualTags: Set<PhotoTag>, isCorrect: Bool, metadata: PhotoMetadata) {
        self.id = id
        self.photoId = photoId
        self.timestamp = timestamp
        self.predictedTags = predictedTags
        self.actualTags = actualTags
        self.isCorrect = isCorrect
        self.metadata = metadata
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

struct TrainingDataExport: Codable {
    let version: String
    let exportDate: Date
    let feedback: [FeedbackEntry]
    let classificationRules: ClassificationRules
    let trainingMetrics: TrainingMetrics
    
    init(feedback: [FeedbackEntry], rules: ClassificationRules, metrics: TrainingMetrics) {
        self.version = "1.0"
        self.exportDate = Date()
        self.feedback = feedback
        self.classificationRules = rules
        self.trainingMetrics = metrics
    }
}

struct ClassificationRules: Codable {
    var screenshotThreshold: Double = 0.5
    var blurThreshold: Double = 0.2    // Set to 0.2 as recommended
    var lowQualityThreshold: Double = 0.5  // Raised from 0.3 to 0.5
    var duplicateThreshold: Double = 0.95
    var textDensityThreshold: Double = 0.3
    
    mutating func adaptThresholds(based feedback: [FeedbackEntry]) {
        let recentFeedback = Array(feedback.suffix(100)) // Increased sample size
        guard !recentFeedback.isEmpty else { return }
        
        // Advanced blur threshold adaptation
        adaptBlurThreshold(feedback: recentFeedback)
        
        // Advanced screenshot threshold adaptation
        adaptScreenshotThreshold(feedback: recentFeedback)
        
        // Advanced low quality threshold adaptation
        adaptLowQualityThreshold(feedback: recentFeedback)
        
        // Advanced duplicate threshold adaptation
        adaptDuplicateThreshold(feedback: recentFeedback)
        
        // Advanced text density threshold adaptation
        adaptTextDensityThreshold(feedback: recentFeedback)
        
        // Adapt thresholds for new categories
        adaptDocumentThreshold(feedback: recentFeedback)
        adaptTextHeavyThreshold(feedback: recentFeedback)
        
        print("📚 Learning: Updated all thresholds based on \(recentFeedback.count) recent feedback entries")
    }
    
    private mutating func adaptDocumentThreshold(feedback: [FeedbackEntry]) {
        let documentFeedback = feedback.filter { entry in
            entry.predictedTags.contains(.document) || entry.actualTags.contains(.document)
        }
        
        guard documentFeedback.count >= 3 else { return }
        
        let accuracy = Double(documentFeedback.filter { $0.isCorrect }.count) / Double(documentFeedback.count)
        
        if accuracy < 0.75 {
            let falsePositives = documentFeedback.filter { entry in
                entry.predictedTags.contains(.document) && !entry.actualTags.contains(.document)
            }
            
            let falseNegatives = documentFeedback.filter { entry in
                !entry.predictedTags.contains(.document) && entry.actualTags.contains(.document)
            }
            
            print("📚 Learning: Document detection accuracy: \(String(format: "%.2f", accuracy)) (FP: \(falsePositives.count), FN: \(falseNegatives.count))")
        }
    }
    
    private mutating func adaptTextHeavyThreshold(feedback: [FeedbackEntry]) {
        let textHeavyFeedback = feedback.filter { entry in
            entry.predictedTags.contains(.textHeavy) || entry.actualTags.contains(.textHeavy)
        }
        
        guard textHeavyFeedback.count >= 3 else { return }
        
        let accuracy = Double(textHeavyFeedback.filter { $0.isCorrect }.count) / Double(textHeavyFeedback.count)
        
        if accuracy < 0.75 {
            let falsePositives = textHeavyFeedback.filter { entry in
                entry.predictedTags.contains(.textHeavy) && !entry.actualTags.contains(.textHeavy)
            }
            
            let falseNegatives = textHeavyFeedback.filter { entry in
                !entry.predictedTags.contains(.textHeavy) && entry.actualTags.contains(.textHeavy)
            }
            
            print("📚 Learning: Text-heavy detection accuracy: \(String(format: "%.2f", accuracy)) (FP: \(falsePositives.count), FN: \(falseNegatives.count))")
        }
    }
    
    private mutating func adaptBlurThreshold(feedback: [FeedbackEntry]) {
        let blurFeedback = feedback.filter { entry in
            entry.predictedTags.contains(.blurry) || entry.actualTags.contains(.blurry)
        }
        
        guard blurFeedback.count >= 5 else { return }
        
        let falsePositives = blurFeedback.filter { entry in
            entry.predictedTags.contains(.blurry) && !entry.actualTags.contains(.blurry)
        }
        
        let falseNegatives = blurFeedback.filter { entry in
            !entry.predictedTags.contains(.blurry) && entry.actualTags.contains(.blurry)
        }
        
        let accuracy = Double(blurFeedback.filter { $0.isCorrect }.count) / Double(blurFeedback.count)
        
        if accuracy < 0.8 {
            if falseNegatives.count > falsePositives.count {
                // Missing too many blurry photos - RAISE threshold to catch more
                blurThreshold = min(0.5, blurThreshold * 1.15)
                print("📚 Learning: RAISED blur threshold to \(String(format: "%.4f", blurThreshold)) (missed \(falseNegatives.count) blurry photos)")
            } else if falsePositives.count > falseNegatives.count {
                // Marking too many sharp photos as blurry - lower threshold
                blurThreshold = max(0.01, blurThreshold * 0.85)
                print("📚 Learning: Lowered blur threshold to \(String(format: "%.4f", blurThreshold)) (marked \(falsePositives.count) sharp photos as blurry)")
            }
        }
    }
    
    private mutating func adaptScreenshotThreshold(feedback: [FeedbackEntry]) {
        let screenshotFeedback = feedback.filter { entry in
            entry.predictedTags.contains(.screenshot) || entry.actualTags.contains(.screenshot)
        }
        
        guard screenshotFeedback.count >= 3 else { return }
        
        let falsePositives = screenshotFeedback.filter { entry in
            entry.predictedTags.contains(.screenshot) && !entry.actualTags.contains(.screenshot)
        }
        
        let falseNegatives = screenshotFeedback.filter { entry in
            !entry.predictedTags.contains(.screenshot) && entry.actualTags.contains(.screenshot)
        }
        
        let accuracy = Double(screenshotFeedback.filter { $0.isCorrect }.count) / Double(screenshotFeedback.count)
        
        if accuracy < 0.85 {
            if falseNegatives.count > falsePositives.count {
                screenshotThreshold = max(0.4, screenshotThreshold - 0.05)
                print("📚 Learning: Lowered screenshot threshold to \(String(format: "%.2f", screenshotThreshold))")
            } else if falsePositives.count > falseNegatives.count {
                screenshotThreshold = min(0.9, screenshotThreshold + 0.05)
                print("📚 Learning: Raised screenshot threshold to \(String(format: "%.2f", screenshotThreshold))")
            }
        }
    }
    
    private mutating func adaptLowQualityThreshold(feedback: [FeedbackEntry]) {
        let qualityFeedback = feedback.filter { entry in
            entry.predictedTags.contains(.lowQuality) || entry.actualTags.contains(.lowQuality)
        }
        
        guard qualityFeedback.count >= 4 else { return }
        
        let falsePositives = qualityFeedback.filter { entry in
            entry.predictedTags.contains(.lowQuality) && !entry.actualTags.contains(.lowQuality)
        }
        
        let falseNegatives = qualityFeedback.filter { entry in
            !entry.predictedTags.contains(.lowQuality) && entry.actualTags.contains(.lowQuality)
        }
        
        let accuracy = Double(qualityFeedback.filter { $0.isCorrect }.count) / Double(qualityFeedback.count)
        
        if accuracy < 0.75 {
            if falseNegatives.count > falsePositives.count {
                lowQualityThreshold = min(0.6, lowQualityThreshold + 0.05)
                print("📚 Learning: Raised low quality threshold to \(String(format: "%.2f", lowQualityThreshold))")
            } else if falsePositives.count > falseNegatives.count {
                lowQualityThreshold = max(0.1, lowQualityThreshold - 0.05)
                print("📚 Learning: Lowered low quality threshold to \(String(format: "%.2f", lowQualityThreshold))")
            }
        }
    }
    
    private mutating func adaptDuplicateThreshold(feedback: [FeedbackEntry]) {
        let duplicateFeedback = feedback.filter { entry in
            entry.predictedTags.contains(.duplicate) || entry.actualTags.contains(.duplicate)
        }
        
        guard duplicateFeedback.count >= 3 else { return }
        
        let accuracy = Double(duplicateFeedback.filter { $0.isCorrect }.count) / Double(duplicateFeedback.count)
        
        if accuracy < 0.9 { // High accuracy requirement for duplicates
            let falsePositives = duplicateFeedback.filter { entry in
                entry.predictedTags.contains(.duplicate) && !entry.actualTags.contains(.duplicate)
            }
            
            let falseNegatives = duplicateFeedback.filter { entry in
                !entry.predictedTags.contains(.duplicate) && entry.actualTags.contains(.duplicate)
            }
            
            if falsePositives.count > falseNegatives.count {
                duplicateThreshold = min(0.99, duplicateThreshold + 0.01)
                print("📚 Learning: Raised duplicate threshold to \(String(format: "%.3f", duplicateThreshold))")
            } else if falseNegatives.count > 0 {
                duplicateThreshold = max(0.85, duplicateThreshold - 0.02)
                print("📚 Learning: Lowered duplicate threshold to \(String(format: "%.3f", duplicateThreshold))")
            }
        }
    }
    
    private mutating func adaptTextDensityThreshold(feedback: [FeedbackEntry]) {
        // Analyze text density patterns in screenshot feedback
        let screenshotFeedback = feedback.filter { entry in
            entry.actualTags.contains(.screenshot) || entry.predictedTags.contains(.screenshot)
        }
        
        guard !screenshotFeedback.isEmpty else { return }
        
        let actualScreenshots = screenshotFeedback.filter { $0.actualTags.contains(.screenshot) }
        let avgTextDensity = actualScreenshots.reduce(0.0) { $0 + $1.metadata.textDensity } / Double(actualScreenshots.count)
        
        if avgTextDensity > 0 {
            let newThreshold = (textDensityThreshold + avgTextDensity) / 2.0
            if abs(newThreshold - textDensityThreshold) > 0.05 {
                textDensityThreshold = max(0.1, min(0.8, newThreshold))
                print("📚 Learning: Adjusted text density threshold to \(String(format: "%.2f", textDensityThreshold))")
            }
        }
    }
}

struct TrainingMetrics: Codable {
    let totalFeedback: Int
    let correctPredictions: Int
    let accuracy: Double
    let lastUpdated: Date
    
    init(feedback: [FeedbackEntry]) {
        self.totalFeedback = feedback.count
        self.correctPredictions = feedback.filter { $0.isCorrect }.count
        self.accuracy = feedback.isEmpty ? 0.0 : Double(correctPredictions) / Double(totalFeedback)
        self.lastUpdated = Date()
    }
}

// MARK: - Learning Service

@MainActor
class LearningService: ObservableObject {
    static let shared = LearningService()
    
    private let userDefaults = UserDefaults.standard
    private let feedbackKey = "ml_training_feedback_v2"
    private let rulesKey = "classification_rules_v2"
    
    @Published var currentAccuracy: Double = 0.0
    
    var totalFeedbackCount: Int {
        return getAllFeedback().count
    }
    
    private init() {
        updateAccuracy()
    }
    
    // MARK: - Feedback Management
    
    func recordFeedback(
        for photoId: String,
        actualTags: Set<PhotoTag>,
        predictedTags: Set<PhotoTag>,
        isCorrect: Bool,
        metadata: PhotoMetadata
    ) {
        let feedback = FeedbackEntry(
            id: UUID().uuidString,
            photoId: photoId,
            timestamp: Date(),
            predictedTags: predictedTags,
            actualTags: actualTags,
            isCorrect: isCorrect,
            metadata: metadata
        )
        
        var allFeedback = getAllFeedback()
        allFeedback.append(feedback)
        
        // Keep only the most recent 1000 entries
        if allFeedback.count > 1000 {
            allFeedback = Array(allFeedback.suffix(1000))
        }
        
        saveFeedback(allFeedback)
        updateClassificationRules()
        updateAccuracy()
        
        print("📝 Recorded feedback: \(isCorrect ? "✅ Correct" : "❌ Incorrect") prediction for \(actualTags)")
    }
    
    func getAllFeedback() -> [FeedbackEntry] {
        guard let data = userDefaults.data(forKey: feedbackKey) else { return [] }
        
        do {
            return try JSONDecoder().decode([FeedbackEntry].self, from: data)
        } catch {
            print("❌ Failed to decode feedback: \(error)")
            return []
        }
    }
    
    private func saveFeedback(_ feedback: [FeedbackEntry]) {
        do {
            let data = try JSONEncoder().encode(feedback)
            userDefaults.set(data, forKey: feedbackKey)
        } catch {
            print("❌ Failed to save feedback: \(error)")
        }
    }
    
    // MARK: - Classification Rules
    
    func getClassificationRules() -> ClassificationRules {
        guard let data = userDefaults.data(forKey: rulesKey) else {
            return ClassificationRules()
        }
        
        do {
            return try JSONDecoder().decode(ClassificationRules.self, from: data)
        } catch {
            print("❌ Failed to decode rules: \(error)")
            return ClassificationRules()
        }
    }
    
    func updateClassificationRules() {
        let feedback = getAllFeedback()
        var rules = getClassificationRules()
        
        rules.adaptThresholds(based: feedback)
        
        do {
            let data = try JSONEncoder().encode(rules)
            userDefaults.set(data, forKey: rulesKey)
            print("📚 Updated classification rules based on \(feedback.count) feedback entries")
        } catch {
            print("❌ Failed to save rules: \(error)")
        }
    }
    
    // MARK: - Import/Export
    
    func importFeedback(_ feedback: [FeedbackEntry]) {
        saveFeedback(feedback)
        updateClassificationRules()
        updateAccuracy()
        print("📥 Imported \(feedback.count) feedback entries")
    }
    
    func importRules(_ rules: ClassificationRules) {
        do {
            let data = try JSONEncoder().encode(rules)
            userDefaults.set(data, forKey: rulesKey)
            print("📥 Imported classification rules")
        } catch {
            print("❌ Failed to import rules: \(error)")
        }
    }
    
    func exportTrainingData() -> TrainingDataExport {
        let feedback = getAllFeedback()
        let rules = getClassificationRules()
        let metrics = TrainingMetrics(feedback: feedback)
        
        return TrainingDataExport(feedback: feedback, rules: rules, metrics: metrics)
    }
    
    // MARK: - Utility
    
    func clearAllFeedback() {
        userDefaults.removeObject(forKey: feedbackKey)
        userDefaults.removeObject(forKey: rulesKey)
        currentAccuracy = 0.0
        print("🧹 Cleared all corrupted learning data and reset thresholds")
        
        // Force reset to default thresholds
        let defaultRules = ClassificationRules()
        do {
            let data = try JSONEncoder().encode(defaultRules)
            userDefaults.set(data, forKey: rulesKey)
            print("🔄 Reset thresholds to defaults: blur=\(defaultRules.blurThreshold), screenshot=\(defaultRules.screenshotThreshold), quality=\(defaultRules.lowQualityThreshold)")
        } catch {
            print("❌ Failed to reset rules: \(error)")
        }
    }
    
    private func updateAccuracy() {
        let feedback = getAllFeedback()
        if feedback.isEmpty {
            currentAccuracy = 0.0
        } else {
            let correct = feedback.filter { $0.isCorrect }.count
            currentAccuracy = Double(correct) / Double(feedback.count)
        }
    }
    
    func getTrainingMetrics() -> TrainingMetrics {
        let feedback = getAllFeedback()
        return TrainingMetrics(feedback: feedback)
    }
    
    // MARK: - Analytics and Progress Tracking
    
    func getLearningAnalytics() -> LearningAnalytics {
        let feedback = getAllFeedback()
        return LearningAnalytics(feedback: feedback)
    }
    
    func getAccuracyTrend(days: Int = 7) -> [AccuracyDataPoint] {
        let feedback = getAllFeedback()
        let calendar = Calendar.current
        let endDate = Date()
        let startDate = calendar.date(byAdding: .day, value: -days, to: endDate) ?? endDate
        
        var dataPoints: [AccuracyDataPoint] = []
        
        for i in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: i, to: startDate) else { continue }
            let dayStart = calendar.startOfDay(for: date)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
            
            let dayFeedback = feedback.filter { 
                $0.timestamp >= dayStart && $0.timestamp < dayEnd 
            }
            
            let accuracy = dayFeedback.isEmpty ? 0.0 : 
                Double(dayFeedback.filter { $0.isCorrect }.count) / Double(dayFeedback.count)
            
            dataPoints.append(AccuracyDataPoint(date: date, accuracy: accuracy, count: dayFeedback.count))
        }
        
        return dataPoints
    }
    
    func getTagAccuracyBreakdown() -> [TagAccuracy] {
        let feedback = getAllFeedback()
        var tagAccuracies: [TagAccuracy] = []
        
        for tag in PhotoTag.allCases {
            guard tag != .unrated else { continue }
            
            let tagFeedback = feedback.filter { entry in
                entry.predictedTags.contains(tag) || entry.actualTags.contains(tag)
            }
            
            guard !tagFeedback.isEmpty else { continue }
            
            let correct = tagFeedback.filter { $0.isCorrect }.count
            let accuracy = Double(correct) / Double(tagFeedback.count)
            
            let falsePositives = tagFeedback.filter { entry in
                entry.predictedTags.contains(tag) && !entry.actualTags.contains(tag)
            }.count
            
            let falseNegatives = tagFeedback.filter { entry in
                !entry.predictedTags.contains(tag) && entry.actualTags.contains(tag)
            }.count
            
            tagAccuracies.append(TagAccuracy(
                tag: tag,
                accuracy: accuracy,
                totalPredictions: tagFeedback.count,
                falsePositives: falsePositives,
                falseNegatives: falseNegatives
            ))
        }
        
        return tagAccuracies
    }
    
    func getCurrentThresholds() -> ClassificationRules {
        return getClassificationRules()
    }
    
    func getThresholdHistory() -> [ThresholdSnapshot] {
        // For now, return current snapshot - in production, you'd store history
        let rules = getClassificationRules()
        return [ThresholdSnapshot(
            timestamp: Date(),
            blurThreshold: rules.blurThreshold,
            screenshotThreshold: rules.screenshotThreshold,
            lowQualityThreshold: rules.lowQualityThreshold,
            duplicateThreshold: rules.duplicateThreshold,
            textDensityThreshold: rules.textDensityThreshold
        )]
    }
    
    // MARK: - UI Helper Methods
    
    func getLearningProgress() -> (accuracy: Double, recentAccuracy: Double, totalFeedback: Int) {
        let analytics = getLearningAnalytics()
        return (
            accuracy: analytics.overallAccuracy,
            recentAccuracy: analytics.recentAccuracy,
            totalFeedback: analytics.totalFeedback
        )
    }
    
    func getAccuracyByTag() -> [PhotoTag: Double] {
        let tagAccuracies = getTagAccuracyBreakdown()
        var result: [PhotoTag: Double] = [:]
        
        for tagAccuracy in tagAccuracies {
            result[tagAccuracy.tag] = tagAccuracy.accuracy
        }
        
        return result
    }
}

// MARK: - Analytics Data Structures

struct LearningAnalytics: Codable {
    let totalFeedback: Int
    let correctPredictions: Int
    let overallAccuracy: Double
    let recentAccuracy: Double // Last 20 entries
    let improvementTrend: Double // Positive = improving, negative = declining
    let lastUpdated: Date
    
    init(feedback: [FeedbackEntry]) {
        self.totalFeedback = feedback.count
        self.correctPredictions = feedback.filter { $0.isCorrect }.count
        self.overallAccuracy = feedback.isEmpty ? 0.0 : Double(correctPredictions) / Double(totalFeedback)
        
        let recent = Array(feedback.suffix(20))
        let recentCorrect = recent.filter { $0.isCorrect }.count
        self.recentAccuracy = recent.isEmpty ? 0.0 : Double(recentCorrect) / Double(recent.count)
        
        // Calculate improvement trend by comparing first half vs second half of recent feedback
        if recent.count >= 10 {
            let firstHalf = Array(recent.prefix(10))
            let secondHalf = Array(recent.suffix(10))
            
            let firstAccuracy = Double(firstHalf.filter { $0.isCorrect }.count) / Double(firstHalf.count)
            let secondAccuracy = Double(secondHalf.filter { $0.isCorrect }.count) / Double(secondHalf.count)
            
            self.improvementTrend = secondAccuracy - firstAccuracy
        } else {
            self.improvementTrend = 0.0
        }
        
        self.lastUpdated = Date()
    }
}

struct AccuracyDataPoint: Codable {
    let date: Date
    let accuracy: Double
    let count: Int
}

struct TagAccuracy: Codable {
    let tag: PhotoTag
    let accuracy: Double
    let totalPredictions: Int
    let falsePositives: Int
    let falseNegatives: Int
    
    var precision: Double {
        let truePositives = totalPredictions - falsePositives - falseNegatives
        return truePositives + falsePositives > 0 ? Double(truePositives) / Double(truePositives + falsePositives) : 0.0
    }
    
    var recall: Double {
        let truePositives = totalPredictions - falsePositives - falseNegatives
        return truePositives + falseNegatives > 0 ? Double(truePositives) / Double(truePositives + falseNegatives) : 0.0
    }
}

struct ThresholdSnapshot: Codable {
    let timestamp: Date
    let blurThreshold: Double
    let screenshotThreshold: Double
    let lowQualityThreshold: Double
    let duplicateThreshold: Double
    let textDensityThreshold: Double
}