import SwiftUI
import Photos
import Foundation
import UIKit
// CLAUDE SYSTEM RULES:
// You must never invoke a subagent without first presenting a Subagent Plan
// for user approval. See .claude.md for full instructions.

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

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var quickScanService = QuickScanService()
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            ModernDashboardView(quickScanService: quickScanService)
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("Dashboard")
                }
                .tag(0)
            
            ModernCleanupView(quickScanService: quickScanService)
                .tabItem {
                    Image(systemName: "trash.fill")
                    Text("Cleanup")
                }
                .tag(1)
        }
        .onAppear {
            requestPhotoLibraryPermission()
        }
    }
    
    private func requestPhotoLibraryPermission() {
        PHPhotoLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized, .limited:
                    print("✅ Photo library access granted")
                case .denied:
                    print("❌ Photo library access denied")
                case .restricted:
                    print("❌ Photo library access restricted")
                case .notDetermined:
                    print("⏳ Photo library access not determined")
                @unknown default:
                    print("❓ Unknown photo library authorization status")
                }
            }
        }
    }
}

// MARK: - Preview
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
