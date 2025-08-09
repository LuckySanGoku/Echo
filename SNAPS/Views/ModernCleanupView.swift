import SwiftUI
import Photos

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
        print("Deleting \(selectedPhotos.count) photos")
        selectedPhotos.removeAll()
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
            photo.thumbnail
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 110, height: 110)
                .clipped()
                .overlay(
                    isSelected ? Color.blue.opacity(0.3) : Color.clear
                )
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
        case .textHeavy: return "textformat"
        case .people: return "person.fill"
        case .lowLight: return "moon.fill"
        case .nearDuplicate: return "doc.on.doc"
        case .document: return "doc.text.fill"
        }
    }
    
    private func tagColor(for tag: PhotoTag) -> Color {
        switch tag {
        case .duplicate: return .orange
        case .blurry: return .purple
        case .lowQuality: return .red
        case .screenshot: return .indigo
        case .unrated: return .gray
        case .textHeavy: return .blue
        case .people: return .green
        case .lowLight: return .yellow
        case .nearDuplicate: return .orange.opacity(0.7)
        case .document: return .brown
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
        for group in duplicateGroups {
            for photo in group {
                if !selectedKeepers.contains(photo.id) {
                    print("Would delete photo: \(photo.id)")
                }
            }
        }
        dismiss()
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
                photo.thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .clipped()
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.green : Color.clear, lineWidth: 3)
                    )
                
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
