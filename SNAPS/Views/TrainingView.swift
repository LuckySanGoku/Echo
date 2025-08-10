import SwiftUI
import Photos

struct TrainingView: View {
    @ObservedObject var quickScanService: QuickScanService
    @State private var currentIndex = 0
    @State private var showingCorrection = false
    @State private var dragOffset: CGSize = .zero
    @State private var feedbackGiven = false
    @Environment(\.dismiss) private var dismiss
    
    // Memory management
    @State private var didReceiveMemoryWarning = false
    
    // Get unrated photos for training - keep array stable during training
    private var unratedPhotos: [PhotoScanResult] {
        return quickScanService.results.filter { $0.tags.contains(.unrated) }
    }
    
    // Check if photo has been rated during this training session
    private func isPhotoRated(_ photoId: String) -> Bool {
        return quickScanService.isPhotoRated(photoId)
    }
    
    private var currentPhoto: PhotoScanResult? {
        guard currentIndex < unratedPhotos.count else { return nil }
        let photo = unratedPhotos[currentIndex]
        return photo
    }
    
    var body: some View {
        NavigationView {
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
                        // Progress indicator
                        TrainingProgressBar(
                            current: currentIndex + 1,
                            total: unratedPhotos.count
                        )
                        .padding()
                        .onAppear {
                            // Generate predictions if not already done
                            if photo.predictedTags.isEmpty && !isPhotoRated(photo.asset.localIdentifier) {
                                Task {
                                    await quickScanService.generatePredictionForPhoto(photo.asset.localIdentifier)
                                }
                            }
                        }
                        
                        // Show if this photo was already rated
                        if isPhotoRated(photo.asset.localIdentifier) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Already rated - advancing...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(8)
                            .padding(.horizontal)
                            .onAppear {
                                // Auto-advance if photo is already rated
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    navigateToNext()
                                }
                            }
                        }
                        
                        // Photo card with swipe
                        PhotoReviewCard(
                            photo: photo,
                            dragOffset: dragOffset,
                            quickScanService: quickScanService
                        )
                        .id("\(currentIndex)-\(photo.id)")  // Force re-render when index or photo changes
                        .offset(x: dragOffset.width)
                        .rotationEffect(.degrees(Double(dragOffset.width / 20)))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if !feedbackGiven {
                                        dragOffset = value.translation
                                    }
                                }
                                .onEnded { value in
                                    if !feedbackGiven {
                                        if value.translation.width > 100 {
                                            navigateToNext()
                                        } else if value.translation.width < -100 {
                                            navigateToPrevious()
                                        }
                                        withAnimation(.spring()) {
                                            dragOffset = .zero
                                        }
                                    }
                                }
                        )
                        .padding(.horizontal)
                        
                        // AI Prediction
                        AIPredictionCard(photo: photo)
                            .id("prediction-\(currentIndex)")  // Force re-render
                            .padding()
                        
                        // Feedback buttons (only show for unrated photos)
                        if !feedbackGiven && !isPhotoRated(photo.asset.localIdentifier) {
                            FeedbackButtons(
                                photo: photo,
                                onCorrect: handleCorrectFeedback,
                                onWrong: handleWrongFeedback
                            )
                            .id("feedback-\(currentIndex)")  // Force re-render
                            .padding()
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        } else if feedbackGiven {
                            // Show next button after feedback
                            Button(action: navigateToNext) {
                                Label("Next Photo", systemImage: "arrow.right.circle.fill")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue)
                                    .cornerRadius(15)
                            }
                            .padding()
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        
                        // Swipe hint
                        if !feedbackGiven {
                            Text("← Swipe to navigate →")
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
            .navigationTitle("Training Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        quickScanService.finalizeTrainingSession()
                        dismiss()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                // Clear image cache on memory warning
                PhotoReviewCard.clearImageCache()
                didReceiveMemoryWarning = true
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ClearImageCache"))) { _ in
                // Clear image cache periodically during scanning
                PhotoReviewCard.clearImageCache()
                print("🧹 PhotoReviewCard cache cleared via notification")
            }
        }
        .sheet(isPresented: $showingCorrection) {
            if let photo = currentPhoto {
                CorrectionView(
                    photo: photo,
                    quickScanService: quickScanService,
                    onComplete: {
                        feedbackGiven = true
                        showingCorrection = false
                        navigateToNext()
                    }
                )
            }
        }
    }
    
    private func handleCorrectFeedback() {
        let timestamp = DateFormatter.timestampFormatter.string(from: Date())
        guard let photo = currentPhoto else { 
            print("\(timestamp) ❌ handleCorrectFeedback: No current photo")
            return 
        }
        
        print("\(timestamp) 📝 CORRECT feedback for photo \(photo.id) at index \(currentIndex)")
        print("\(timestamp) 📝 Current tags: \(photo.tags)")
        
        withAnimation(.easeInOut(duration: 0.3)) {
            feedbackGiven = true
        }
        
        // DON'T remove unrated tag yet - just mark as rated
        // This keeps the array stable during training
        quickScanService.markPhotoAsRated(photo.asset.localIdentifier)
        
        // Record correct feedback: predictions were right
        LearningService.shared.recordFeedback(
            for: photo.asset.localIdentifier,
            actualTags: photo.predictedTags,  // User confirmed predictions are correct
            predictedTags: photo.predictedTags,
            isCorrect: true,
            metadata: photo.metadata
        )
        quickScanService.calculateTrainingConfidence()
        
        // Reset feedback state and check for preload
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.feedbackGiven = false
            self.checkAndTriggerPreload()
        }
        
        // Haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    
    private func handleWrongFeedback() {
        showingCorrection = true
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    
    private func navigateToNext() {
        let timestamp = DateFormatter.timestampFormatter.string(from: Date())
        print("\(timestamp) 🔄 navigateToNext called - current index: \(currentIndex)")
        print("\(timestamp) 🔄 Unrated photos count: \(unratedPhotos.count)")
        
        // Find next unrated photo
        var nextIndex = currentIndex + 1
        
        // Check if we need to preload more photos
        checkAndTriggerPreload()
        
        // Look for next unrated photo
        while nextIndex < unratedPhotos.count {
            if let photo = unratedPhotos[safe: nextIndex],
               !isPhotoRated(photo.asset.localIdentifier) {
                // Found next unrated photo
                withAnimation(.easeInOut(duration: 0.3)) {
                    currentIndex = nextIndex
                    feedbackGiven = false
                }
                print("\(timestamp) 🔄 Advanced to index: \(currentIndex)")
                print("\(timestamp) 🔄 New photo ID: \(currentPhoto?.id ?? "nil")")
                return
            }
            nextIndex += 1
        }
        
        // No more unrated photos found - training complete
        print("\(timestamp) 🔄 Training session complete - finalizing")
        quickScanService.finalizeTrainingSession()
        dismiss()
    }
    
    private func navigateToPrevious() {
        if currentIndex > 0 {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentIndex -= 1
                feedbackGiven = false
            }
        }
    }
    
    // MARK: - Preloading Logic
    
    private func checkAndTriggerPreload() {
        let timestamp = DateFormatter.timestampFormatter.string(from: Date())
        let unratedCount = unratedPhotos.filter { !isPhotoRated($0.asset.localIdentifier) }.count
        
        print("\(timestamp) 📦 Preload check: \(unratedCount) unrated photos remaining")
        
        // Trigger preload when we have 4 or fewer unrated photos remaining
        if unratedCount <= 4 && !quickScanService.isScanning {
            print("\(timestamp) 🚀 PRELOAD TRIGGERED: Only \(unratedCount) unrated photos left, loading next batch...")
            
            // Trigger background preload
            Task {
                await quickScanService.preloadNextBatch()
            }
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

struct PhotoReviewCard: View {
    let photo: PhotoScanResult
    let dragOffset: CGSize
    let quickScanService: QuickScanService
    @State private var fullResolutionImage: Image?
    @State private var isLoadingFullRes = false
    @State private var loadingFailed = false
    @State private var imageLoaded = false
    @State private var imageRequestID: PHImageRequestID?
    @State private var duplicates: [PhotoScanResult] = []
    @State private var isLoadingDuplicates = false
    
    // Image cache to prevent repeated loading
    @State private static var imageCache: [String: Image] = [:]
    
    var displayImage: Image {
        if let fullRes = fullResolutionImage {
            return fullRes
        } else if loadingFailed {
            return photo.thumbnail
        } else {
            return photo.thumbnail
        }
    }
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 25)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.1), radius: 20, y: 10)
            
            // Get fresh photo data for duplicate check
            let currentPhoto = quickScanService.results.first(where: { $0.id == photo.id }) ?? photo
            let hasDuplicateTag = currentPhoto.predictedTags.contains(.duplicate) || currentPhoto.tags.contains(.duplicate)
            let duplicatesCount = duplicates.count
            let _ = print("🔍 DUPLICATE VIEW CHECK:")
            let _ = print("  - Has duplicate tag: \(hasDuplicateTag)")
            let _ = print("  - Predicted tags: \(currentPhoto.predictedTags)")
            let _ = print("  - Regular tags: \(currentPhoto.tags)")
            let _ = print("  - Duplicates array count: \(duplicatesCount)")
            let _ = print("  - Duplicates: \(duplicates.map { $0.id })")
            
            // Show duplicate comparison if photo has duplicates (predicted or confirmed)
            if (currentPhoto.predictedTags.contains(.duplicate) || currentPhoto.tags.contains(.duplicate)) && !duplicates.isEmpty {
                DuplicateComparisonView(
                    originalPhoto: photo,
                    duplicates: duplicates,
                    dragOffset: dragOffset
                )
                .padding()
            } else {
                // Regular single photo view
                VStack {
                    ZStack {
                        displayImage
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 400)
                            .cornerRadius(20)
                            .scaleEffect(imageLoaded ? 1 : 0.9)
                            .opacity(imageLoaded ? 1 : 0)
                        
                        // Loading indicator for full-resolution image
                        if isLoadingFullRes && fullResolutionImage == nil {
                            VStack {
                                ProgressView()
                                    .scaleEffect(1.2)
                                    .tint(.blue)
                                Text("Loading full quality...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 4)
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.white.opacity(0.9))
                                    .shadow(radius: 5)
                            )
                        }
                        
                        // Loading duplicates indicator
                        if isLoadingDuplicates {
                            VStack {
                                HStack {
                                    Spacer()
                                    VStack {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                            .tint(.orange)
                                        Text("Finding duplicates...")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    }
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.orange.opacity(0.1))
                                    )
                                }
                                Spacer()
                            }
                            .padding()
                        }
                        
                        // Quality indicator
                        VStack {
                            HStack {
                                Spacer()
                                HStack(spacing: 4) {
                                    Image(systemName: fullResolutionImage != nil ? "checkmark.circle.fill" : "photo")
                                        .foregroundColor(fullResolutionImage != nil ? .green : .orange)
                                    Text(fullResolutionImage != nil ? "Full Quality" : "Preview")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                }
                                .padding(6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.black.opacity(0.7))
                                )
                                .foregroundColor(.white)
                            }
                            Spacer()
                        }
                        .padding()
                    }
                    .padding()
                }
                
                // Swipe indicators for single photo view
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
        }
        .frame(height: 450)
        .onAppear {
            loadFullResolutionImage()
            loadDuplicates()
            withAnimation(.easeInOut(duration: 0.3)) {
                imageLoaded = true
            }
        }
        .onChange(of: photo.predictedTags) { _ in
            // Reload duplicates when predictions change
            loadDuplicates()
        }
        .onDisappear {
            cancelImageRequest()
        }
    }
    
    private func loadFullResolutionImage() {
        // Check cache first
        let cacheKey = photo.id
        if let cachedImage = Self.imageCache[cacheKey] {
            self.fullResolutionImage = cachedImage
            return
        }
        
        // Don't load if already loading or loaded
        guard fullResolutionImage == nil && !isLoadingFullRes else { return }
        
        isLoadingFullRes = true
        loadingFailed = false
        
        let imageManager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        
        // Progressive loading - start with medium quality then full
        options.progressHandler = { progress, _, _, _ in
            DispatchQueue.main.async {
                // Optional: Update progress indicator
            }
        }
        
        // Calculate optimal target size based on device screen
        let screenScale = UIScreen.main.scale
        let maxDisplaySize = CGSize(width: 800 * screenScale, height: 800 * screenScale)
        
        // Use the smaller of actual image size or max display size for memory efficiency
        let targetSize = CGSize(
            width: min(CGFloat(photo.asset.pixelWidth), maxDisplaySize.width),
            height: min(CGFloat(photo.asset.pixelHeight), maxDisplaySize.height)
        )
        
        imageRequestID = imageManager.requestImage(
            for: photo.asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { [photo] image, info in
            DispatchQueue.main.async {
                self.isLoadingFullRes = false
                
                if let image = image {
                    let swiftUIImage = Image(uiImage: image)
                    self.fullResolutionImage = swiftUIImage
                    
                    // Cache the image for future use
                    Self.imageCache[cacheKey] = swiftUIImage
                    
                    // Limit cache size to prevent memory issues
                    if Self.imageCache.count > 10 {
                        // Remove oldest entries (simple FIFO)
                        let keysToRemove = Array(Self.imageCache.keys.prefix(5))
                        keysToRemove.forEach { Self.imageCache.removeValue(forKey: $0) }
                    }
                    
                    // Add smooth transition animation
                    withAnimation(.easeInOut(duration: 0.4)) {
                        self.loadingFailed = false
                    }
                } else {
                    // Fallback to thumbnail on failure
                    self.loadingFailed = true
                    print("Failed to load full resolution image for: \(photo.id)")
                }
                
                self.imageRequestID = nil
            }
        }
    }
    
    @MainActor
    private func loadDuplicates() {
        // Get the current photo data from the service (with predictions)
        guard let currentPhoto = quickScanService.results.first(where: { $0.id == photo.id }) else {
            print("🔍 Could not find photo in results")
            return
        }
        
        print("🔍 LOAD DUPLICATES called for \(currentPhoto.id)")
        print("  - Has duplicate in predicted: \(currentPhoto.predictedTags.contains(.duplicate))")
        print("  - Has duplicate in tags: \(currentPhoto.tags.contains(.duplicate))")
        
        // Check both predicted and regular tags on the CURRENT photo
        guard currentPhoto.predictedTags.contains(.duplicate) || currentPhoto.tags.contains(.duplicate) else { 
            duplicates = []
            return 
        }
        
        isLoadingDuplicates = true
        
        Task { @MainActor in
            let foundDuplicates = quickScanService.findDuplicatesFor(assetId: currentPhoto.asset.localIdentifier)
            self.duplicates = foundDuplicates
            self.isLoadingDuplicates = false
            print("🔍 Loaded \(foundDuplicates.count) duplicates for \(currentPhoto.id)")
        }
    }
    
    private func cancelImageRequest() {
        if let requestID = imageRequestID {
            PHImageManager.default().cancelImageRequest(requestID)
            imageRequestID = nil
            isLoadingFullRes = false
        }
    }
    
    // MARK: - Static Methods
    
    static func clearImageCache() {
        imageCache.removeAll()
        print("🧹 PhotoReviewCard image cache cleared")
    }
}

struct AIPredictionCard: View {
    let photo: PhotoScanResult
    
    var predictionText: String {
        // Show predicted tags, not confirmed tags
        let tags = photo.predictedTags
        if tags.isEmpty {
            return "Good Quality Photo"
        } else {
            let tagTexts = tags.map { tag in
                switch tag {
                case .blurry: return "Blurry"
                case .lowQuality: return "Low Quality"
                case .screenshot: return "Screenshot"
                case .duplicate: return "Duplicate"
                case .nearDuplicate: return "Near Duplicate"
                case .textHeavy: return "Text Heavy"
                case .people: return "Contains People"
                case .lowLight: return "Low Light"
                case .document: return "Document"
                case .unrated: return ""
                }
            }.filter { !$0.isEmpty }
            
            if tags.contains(.duplicate) {
                return "Duplicate (comparison shown above)"
            } else {
                return tagTexts.joined(separator: ", ")
            }
        }
    }
    
    var predictionIcon: String {
        let tags = photo.predictedTags
        if tags.isEmpty {
            return "✨"
        } else if tags.contains(.screenshot) {
            return "📱"
        } else if tags.contains(.blurry) {
            return "🌫️"
        } else if tags.contains(.duplicate) {
            return "🔄"
        } else if tags.contains(.nearDuplicate) {
            return "〰️"
        } else if tags.contains(.lowQuality) {
            return "🌑"
        } else if tags.contains(.textHeavy) {
            return "📝"
        } else if tags.contains(.people) {
            return "👤"
        } else if tags.contains(.lowLight) {
            return "🌙"
        } else if tags.contains(.document) {
            return "📄"
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
        let tags = photo.predictedTags
        if tags.isEmpty {
            return .green
        } else if tags.contains(.screenshot) {
            return .blue
        } else if tags.contains(.blurry) {
            return .purple
        } else if tags.contains(.duplicate) {
            return .orange
        } else if tags.contains(.nearDuplicate) {
            return .yellow
        } else if tags.contains(.textHeavy) {
            return .indigo
        } else if tags.contains(.people) {
            return .pink
        } else if tags.contains(.lowLight) {
            return .gray
        } else if tags.contains(.document) {
            return .brown
        } else if tags.contains(.lowQuality) {
            return .red
        } else {
            return .gray
        }
    }
}

struct FeedbackButtons: View {
    let photo: PhotoScanResult
    let onCorrect: () -> Void
    let onWrong: () -> Void
    
    private var feedbackPrompt: String {
        if photo.predictedTags.contains(.duplicate) {
            return "Are these photos duplicates?"
        } else if photo.predictedTags.contains(.nearDuplicate) {
            return "Are these photos near duplicates?"
        } else {
            return "Is this classification correct?"
        }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Text(feedbackPrompt)
                .font(.title2)
                .fontWeight(.semibold)
            
            HStack(spacing: 20) {
                Button(action: onCorrect) {
                    Label("Correct", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .cornerRadius(15)
                }
                
                Button(action: onWrong) {
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
        // Update tags
        quickScanService.updatePhotoTags(
            assetId: photo.asset.localIdentifier,
            newTags: selectedTags
        )
        
        // Mark as rated
        quickScanService.markPhotoAsRated(photo.asset.localIdentifier)
        
        // Record feedback: predictions were wrong, these are the correct tags
        LearningService.shared.recordFeedback(
            for: photo.asset.localIdentifier,
            actualTags: selectedTags,  // User's corrections
            predictedTags: photo.predictedTags,  // What AI predicted
            isCorrect: false,
            metadata: photo.metadata
        )
        
        quickScanService.calculateTrainingConfidence()
        quickScanService.updateMLThresholds()
        
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

struct DuplicateComparisonView: View {
    let originalPhoto: PhotoScanResult
    let duplicates: [PhotoScanResult]
    let dragOffset: CGSize
    @State private var selectedDuplicateIndex = 0
    @State private var originalImage: Image?
    @State private var duplicateImage: Image?
    @State private var isLoadingImages = false
    
    private var currentDuplicate: PhotoScanResult? {
        guard selectedDuplicateIndex < duplicates.count else { return nil }
        return duplicates[selectedDuplicateIndex]
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Text("Duplicate Comparison")
                    .font(.headline)
                    .foregroundColor(.orange)
                
                if duplicates.count > 1 {
                    Text("Showing \(selectedDuplicateIndex + 1) of \(duplicates.count) duplicates")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 12)
            
            // Split screen comparison
            HStack(spacing: 8) {
                // Original photo
                VStack(spacing: 8) {
                    Text("Original")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    ZStack {
                        RoundedRectangle(cornerRadius: 15)
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
                        
                        Group {
                            if let originalImage = originalImage {
                                originalImage
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                originalPhoto.thumbnail
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            }
                        }
                        .frame(maxHeight: 200)
                        .cornerRadius(12)
                        .clipped()
                        
                        if isLoadingImages {
                            VStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Loading...")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.white.opacity(0.9))
                            )
                        }
                    }
                }
                
                // VS divider
                VStack {
                    Text("VS")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.orange.opacity(0.1))
                        )
                }
                
                // Duplicate photo
                VStack(spacing: 8) {
                    Text("Duplicate")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.orange)
                    
                    ZStack {
                        RoundedRectangle(cornerRadius: 15)
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
                        
                        if let currentDuplicate = currentDuplicate {
                            Group {
                                if let duplicateImage = duplicateImage {
                                    duplicateImage
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                } else {
                                    currentDuplicate.thumbnail
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                }
                            }
                            .frame(maxHeight: 200)
                            .cornerRadius(12)
                            .clipped()
                        } else {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.3))
                                .frame(height: 200)
                        }
                    }
                }
            }
            .padding(.horizontal)
            
            // Duplicate navigation (if multiple duplicates)
            if duplicates.count > 1 {
                HStack(spacing: 16) {
                    Button(action: {
                        if selectedDuplicateIndex > 0 {
                            selectedDuplicateIndex -= 1
                            loadDuplicateImage()
                        }
                    }) {
                        Image(systemName: "chevron.left.circle.fill")
                            .font(.title2)
                            .foregroundColor(selectedDuplicateIndex > 0 ? .orange : .gray)
                    }
                    .disabled(selectedDuplicateIndex == 0)
                    
                    Text("\(selectedDuplicateIndex + 1) / \(duplicates.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button(action: {
                        if selectedDuplicateIndex < duplicates.count - 1 {
                            selectedDuplicateIndex += 1
                            loadDuplicateImage()
                        }
                    }) {
                        Image(systemName: "chevron.right.circle.fill")
                            .font(.title2)
                            .foregroundColor(selectedDuplicateIndex < duplicates.count - 1 ? .orange : .gray)
                    }
                    .disabled(selectedDuplicateIndex >= duplicates.count - 1)
                }
                .padding(.top, 12)
            }
            
            // Photo details comparison
            if let currentDuplicate = currentDuplicate {
                VStack(spacing: 12) {
                    Divider()
                        .padding(.vertical, 8)
                    
                    HStack {
                        // Original details
                        VStack(alignment: .leading, spacing: 4) {
                            if let date = originalPhoto.metadata.creationDate {
                                Text(DateFormatter.shortDateTime.string(from: date))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text("\(Int(originalPhoto.metadata.dimensions.width))×\(Int(originalPhoto.metadata.dimensions.height))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // Duplicate details
                        VStack(alignment: .trailing, spacing: 4) {
                            if let date = currentDuplicate.metadata.creationDate {
                                Text(DateFormatter.shortDateTime.string(from: date))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text("\(Int(currentDuplicate.metadata.dimensions.width))×\(Int(currentDuplicate.metadata.dimensions.height))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            
            // Swipe indicators for comparison view
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
        .onAppear {
            loadImages()
        }
    }
    
    private func loadImages() {
        isLoadingImages = true
        
        // Load original image
        loadFullResolutionImage(for: originalPhoto.asset) { image in
            self.originalImage = image
        }
        
        // Load current duplicate image
        loadDuplicateImage()
    }
    
    private func loadDuplicateImage() {
        guard let currentDuplicate = currentDuplicate else { return }
        
        loadFullResolutionImage(for: currentDuplicate.asset) { image in
            self.duplicateImage = image
            self.isLoadingImages = false
        }
    }
    
    private func loadFullResolutionImage(for asset: PHAsset, completion: @escaping (Image?) -> Void) {
        let imageManager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        
        let screenScale = UIScreen.main.scale
        let targetSize = CGSize(width: 400 * screenScale, height: 400 * screenScale)
        
        imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            DispatchQueue.main.async {
                if let image = image {
                    completion(Image(uiImage: image))
                } else {
                    completion(nil)
                }
            }
        }
    }
}

// Extension for date formatting
extension DateFormatter {
    static let shortDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
    
    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

// Extension for safe array access
extension Array {
    subscript(safe index: Int) -> Element? {
        return index >= 0 && index < count ? self[index] : nil
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
