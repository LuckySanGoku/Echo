import SwiftUI
import Photos
import PhotosUI

extension DateFormatter {
    static let dashboardTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

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
                        let timestamp = DateFormatter.dashboardTimestampFormatter.string(from: Date())
                        print("\(timestamp) 🔴 BUTTON PRESSED - Starting training/scan")
                        
                        // Clear old corrupted feedback data first
                        LearningService.shared.clearAllFeedback()
                        
                        if quickScanService.isTrainingComplete {
                            print("\(timestamp) 🔴 Training complete, starting full scan")
                            quickScanService.startFullScan()
                            return
                        }
                        
                        if !quickScanService.results.isEmpty {
                            print("\(timestamp) 🔴 Results exist, continuing training")
                            // Continue training
                            showingTraining = true
                            return
                        }
                        
                        // Check both read and readWrite permissions before starting
                        let readStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                        print("\(timestamp) 🔴 Permission status: \(readStatus.rawValue)")
                        
                        // Try with permissions
                        if readStatus == .authorized || readStatus == .limited {
                            print("\(timestamp) 🔴 Have permissions, starting REAL scan")
                            quickScanService.scanAllAssets()
                        } else {
                            print("\(timestamp) 🔴 Need permissions, requesting access...")
                            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                                let callbackTimestamp = DateFormatter.dashboardTimestampFormatter.string(from: Date())
                                print("\(callbackTimestamp) 🔴 New permission status: \(newStatus.rawValue)")
                                if newStatus == .authorized || newStatus == .limited {
                                    Task { @MainActor in
                                        print("\(callbackTimestamp) 🔴 Got permissions, starting REAL scan")
                                        quickScanService.scanAllAssets()
                                    }
                                } else {
                                    print("\(callbackTimestamp) ❌ Permission denied - scan cancelled")
                                }
                            }
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
                    .disabled(quickScanService.isScanning)
                    
                    if !quickScanService.results.isEmpty {
                        Button(action: {
                            // Check permissions before scanning more
                            let readStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                            
                            if readStatus == .authorized || readStatus == .limited {
                                quickScanService.scanAllAssets()
                            } else {
                                PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                                    if newStatus == .authorized || newStatus == .limited {
                                        Task { @MainActor in
                                            quickScanService.scanAllAssets()
                                        }
                                    }
                                }
                            }
                        }) {
                            Label("Scan More", systemImage: "plus.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.3))
                                .cornerRadius(12)
                        }
                        .disabled(quickScanService.isScanning)
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
            }
            
            Spacer()
        }
        .padding()
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
                    ModernCleanupView(quickScanService: quickScanService)
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
                photo.thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 100)
                    .clipped()
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
                photo.thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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

// MARK: - FeedbackInterface Component

struct FeedbackInterface: View {
    let result: PhotoScanResult
    @ObservedObject var quickScanService: QuickScanService
    @State private var showingFeedbackOptions = false
    @State private var selectedFeedback: FeedbackState? = nil
    
    enum FeedbackState {
        case correct, incorrect
    }
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Is this classification correct?")
                .font(.headline)
                .foregroundColor(.primary)
            
            HStack(spacing: 20) {
                // Correct classification
                Button(action: {
                    selectedFeedback = .correct
                    handleCorrectFeedback()
                }) {
                    Label("Correct", systemImage: "hand.thumbsup.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(selectedFeedback == .correct ? Color.green : Color.green.opacity(0.8))
                        .cornerRadius(25)
                        .scaleEffect(selectedFeedback == .correct ? 1.05 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: selectedFeedback)
                }
                
                // Incorrect classification
                Button(action: {
                    selectedFeedback = .incorrect
                    showingFeedbackOptions = true
                }) {
                    Label("Incorrect", systemImage: "hand.thumbsdown.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(selectedFeedback == .incorrect ? Color.red : Color.red.opacity(0.8))
                        .cornerRadius(25)
                        .scaleEffect(selectedFeedback == .incorrect ? 1.05 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: selectedFeedback)
                }
            }
            
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
            }
        }
        .sheet(isPresented: $showingFeedbackOptions) {
            CorrectionView(
                photo: result,
                quickScanService: quickScanService,
                onComplete: {
                    showingFeedbackOptions = false
                }
            )
        }
    }
    
    private func handleCorrectFeedback() {
        quickScanService.markPhotoAsRated(result.asset.localIdentifier)
        
        // Record positive feedback
        LearningService.shared.recordFeedback(
            for: result.asset.localIdentifier,
            actualTags: result.tags.subtracting([.unrated]),
            predictedTags: result.tags.subtracting([.unrated]),
            isCorrect: true,
            metadata: result.metadata
        )
        
        quickScanService.calculateTrainingConfidence()
        quickScanService.updateMLThresholds()
        
        // Haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        print("✅ Marked classification as CORRECT for photo: \(result.asset.localIdentifier)")
    }
}
