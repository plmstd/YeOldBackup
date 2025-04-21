import SwiftUI
import AppKit // Required for NSOpenPanel
import SystemConfiguration // For System Preferences URL

struct ContentView: View {
    // Use AppStorage to store bookmark data
    @AppStorage("sourceBookmarkData") private var sourceBookmarkData: Data?
    @AppStorage("targetBookmarkData") private var targetBookmarkData: Data?

    // State variables to hold the resolved paths for display and use
    @State private var sourcePath: String = ""
    @State private var targetPath: String = ""
    
    // State variables to hold the URLs we are currently accessing
    @State private var accessedSourceURL: URL?
    @State private var accessedTargetURL: URL?

    // Instantiate the BackupManager
    @StateObject private var backupManager = BackupManager()
    @State private var hasFullDiskAccess: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("YeOldBackup")
                .font(.largeTitle)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom)

            // Full Disk Access Warning
            if !hasFullDiskAccess {
                FullDiskAccessWarningView()
                    .padding(.bottom)
            }

            // Source Selection
            HStack {
                Text("Source:")
                    .frame(width: 60, alignment: .trailing)
                TextField("No source selected", text: $sourcePath)
                    .disabled(true)
                Button("Select...") {
                    selectDirectory(for: .source)
                }
                .disabled(backupManager.isRunning || !hasFullDiskAccess)
            }
            .disabled(!hasFullDiskAccess) // Disable row if no access

            // Target Selection
            HStack {
                Text("Target:")
                    .frame(width: 60, alignment: .trailing)
                TextField("No target selected", text: $targetPath)
                    .disabled(true)
                Button("Select...") {
                    selectDirectory(for: .target)
                }
                 .disabled(backupManager.isRunning || !hasFullDiskAccess)
            }
             .disabled(!hasFullDiskAccess) // Disable row if no access

            Spacer() // Pushes controls to top and bottom

            // Backup Controls and Status
            HStack {
                if backupManager.isRunning {
                    Button("Stop Backup") {
                        backupManager.stopBackup()
                    }
                    .buttonStyle(.borderedProminent) // Make stop button prominent
                    .tint(.red)
                } else {
                    Button("Backup Now") {
                        startBackup()
                    }
                    .disabled(sourcePath.isEmpty || targetPath.isEmpty || backupManager.isRunning || !hasFullDiskAccess)
                    .keyboardShortcut(.defaultAction) // Allow hitting Enter to backup
                }

                ProgressView()
                    .opacity(backupManager.isRunning ? 1 : 0)
                    .padding(.leading, 5)

                Spacer() // Push status text to the right

                Text(statusText)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(statusColor)
            }
            .padding(.top)

        }
        .padding()
        .frame(minWidth: 550, minHeight: 300) // Adjusted size for warning
        .onAppear {
            checkPermissions()
            // Attempt to resolve bookmarks on appear
            resolveBookmarks()
            // Initialize status message on appear if not already running
            if !backupManager.isRunning {
                backupManager.progressMessage = "Ready"
            }
        }
        // Re-check permissions when the app becomes active again
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
             checkPermissions()
             // Re-resolve bookmarks in case permissions changed while inactive
             resolveBookmarks()
        }
    }

    // Computed properties for status display
    private var statusText: String {
        if !hasFullDiskAccess {
            return "Requires Full Disk Access"
        }
        if backupManager.progressMessage.isEmpty && !backupManager.isRunning {
            return "Ready"
        }
        return backupManager.progressMessage
    }

    private var statusColor: Color {
        if !hasFullDiskAccess || backupManager.errorOccurred {
            return .red
        }
        return .secondary
    }

    // MARK: - Permission Check

    private func checkPermissions() {
        self.hasFullDiskAccess = BackupPermissions.checkFullDiskAccess()
        print("Full Disk Access Check: \(self.hasFullDiskAccess)")
    }

    // Enum to differentiate selection type
    private enum PathType {
        case source, target
    }

    // Function to open the directory selection panel and store bookmark
    private func selectDirectory(for type: PathType) {
        let openPanel = NSOpenPanel()
        openPanel.title = (type == .source) ? "Select Source Drive/Folder" : "Select Target Drive/Folder"
        openPanel.message = "Choose a directory"
        openPanel.prompt = "Select"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true // Allow creating the target backup folder
        openPanel.allowsMultipleSelection = false

        // Request access to the selected URL to ensure sandbox access
        // This is crucial for accessing arbitrary locations selected by the user.
        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                // Stop accessing any previously accessed URL of this type
                 stopAccessingURL(for: type)

                // Generate bookmark data
                do {
                    // Start access before creating bookmark
                    guard url.startAccessingSecurityScopedResource() else {
                         print("Error: Could not start accessing selected resource for bookmark generation.")
                         // Optionally show an alert to the user
                         return
                    }
                    let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    // Stop access immediately after creating bookmark
                    url.stopAccessingSecurityScopedResource()

                    // Store the bookmark data and update the path state variable
                    DispatchQueue.main.async {
                        if type == .source {
                            self.sourceBookmarkData = bookmarkData
                            self.sourcePath = url.path // Update display path
                            // Resolve immediately to start accessing the *new* selection
                            self.accessedSourceURL = resolveBookmark(data: bookmarkData, type: .source)
                        } else {
                            self.targetBookmarkData = bookmarkData
                            self.targetPath = url.path // Update display path
                             // Resolve immediately to start accessing the *new* selection
                            self.accessedTargetURL = resolveBookmark(data: bookmarkData, type: .target)
                        }
                        // Reset status only if not currently running
                        if !backupManager.isRunning {
                             backupManager.progressMessage = "Ready"
                             backupManager.errorOccurred = false
                        }
                    }
                } catch {
                    print("Error creating bookmark data for \(url.path): \(error)")
                     url.stopAccessingSecurityScopedResource() // Ensure access is stopped on error
                    // Optionally show an error alert to the user
                    DispatchQueue.main.async {
                        // Clear potentially broken state
                        if type == .source {
                            self.sourceBookmarkData = nil
                            self.sourcePath = ""
                        } else {
                            self.targetBookmarkData = nil
                            self.targetPath = ""
                        }
                        backupManager.progressMessage = "Error: Could not save selection."
                        backupManager.errorOccurred = true
                    }
                }
            }
        }
    }

    // MARK: - Bookmark Handling

    // Resolve saved bookmarks on launch or when needed
    private func resolveBookmarks() {
         print("Attempting to resolve bookmarks...")
         stopAccessingURL(for: .source) // Stop previous access before resolving
         stopAccessingURL(for: .target)

         if let sourceData = sourceBookmarkData {
             self.accessedSourceURL = resolveBookmark(data: sourceData, type: .source)
         } else {
             self.sourcePath = "" // Clear path if no bookmark data
         }

         if let targetData = targetBookmarkData {
             self.accessedTargetURL = resolveBookmark(data: targetData, type: .target)
         } else {
             self.targetPath = "" // Clear path if no bookmark data
         }
         
         // Update status if paths are missing after trying to resolve
         if (sourceBookmarkData != nil && sourcePath.isEmpty) || (targetBookmarkData != nil && targetPath.isEmpty) {
             if !backupManager.isRunning {
                backupManager.progressMessage = "Could not access previous locations."
                backupManager.errorOccurred = true
             }
         } else if sourcePath.isEmpty || targetPath.isEmpty {
             if !backupManager.isRunning {
                 backupManager.progressMessage = "Select source and target."
             }
         } else {
             if !backupManager.isRunning && !backupManager.errorOccurred {
                  backupManager.progressMessage = "Ready"
             }
         }
    }

    // Resolve a single bookmark
    private func resolveBookmark(data: Data, type: PathType) -> URL? {
        var isStale = false
        do {
            let resolvedUrl = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)

            if isStale {
                print("Warning: Bookmark data is stale for \(type). Re-creating.")
                // If stale, try to recreate the bookmark immediately
                // Need to start access first to get a new bookmark
                guard resolvedUrl.startAccessingSecurityScopedResource() else {
                    print("Error: Could not start accessing stale resource to refresh bookmark for \(type).")
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: nil) // Simulate a permission error
                }
                let newBookmarkData = try resolvedUrl.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                 // No need to stop/start access again here, we already started.
                 // Update stored data and path
                 DispatchQueue.main.async {
                     if type == .source {
                         self.sourceBookmarkData = newBookmarkData
                         self.sourcePath = resolvedUrl.path
                     } else {
                         self.targetBookmarkData = newBookmarkData
                         self.targetPath = resolvedUrl.path
                     }
                 }
                 print("Successfully refreshed stale bookmark for \(type).")
                 return resolvedUrl // Return the URL we already started accessing

            } else {
                 // Bookmark is not stale, just start accessing
                 guard resolvedUrl.startAccessingSecurityScopedResource() else {
                     print("Error: Could not start accessing resource for \(type).")
                     throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: nil) // Simulate a permission error
                 }
                 // Update the path state variable
                  DispatchQueue.main.async {
                      if type == .source {
                          self.sourcePath = resolvedUrl.path
                      } else {
                          self.targetPath = resolvedUrl.path
                      }
                  }
                  print("Successfully resolved and started accessing bookmark for \(type): \(resolvedUrl.path)")
                  return resolvedUrl
            }

        } catch {
            print("Error resolving bookmark for \(type): \(error). Clearing stored data.")
            // Clear the invalid bookmark data and path
            DispatchQueue.main.async {
                if type == .source {
                    self.sourceBookmarkData = nil
                    self.sourcePath = ""
                    self.accessedSourceURL = nil // Clear the state URL too
                } else {
                    self.targetBookmarkData = nil
                    self.targetPath = ""
                    self.accessedTargetURL = nil // Clear the state URL too
                }
            }
            return nil
        }
    }
    
    // Stop accessing a specific URL
    private func stopAccessingURL(for type: PathType) {
        if type == .source, let url = accessedSourceURL {
            url.stopAccessingSecurityScopedResource()
            accessedSourceURL = nil
            print("Stopped accessing source URL: \(url.path)")
        } else if type == .target, let url = accessedTargetURL {
            url.stopAccessingSecurityScopedResource()
            accessedTargetURL = nil
            print("Stopped accessing target URL: \(url.path)")
        }
    }
    
    // Stop accessing all tracked URLs
    func stopAccessingAllURLs() {
         stopAccessingURL(for: .source)
         stopAccessingURL(for: .target)
    }

    // Placeholder for the backup logic
    private func startBackup() {
        guard hasFullDiskAccess else {
             backupManager.progressMessage = "Error: Full Disk Access required."
             backupManager.errorOccurred = true
             // Optionally show an alert here too
             return
        }
        
        // Basic validation
        guard !sourcePath.isEmpty, !targetPath.isEmpty else {
            backupManager.progressMessage = "Error: Source or Target not set."
            backupManager.errorOccurred = true
            return
        }
        guard sourcePath != targetPath else {
            backupManager.progressMessage = "Error: Source and Target cannot be the same."
            backupManager.errorOccurred = true
            return
        }
        
        // Check if source and target are actually accessible before starting
        guard FileManager.default.isReadableFile(atPath: sourcePath) else {
             backupManager.progressMessage = "Error: Cannot read Source path."
             backupManager.errorOccurred = true
             return
        }
        guard FileManager.default.isWritableFile(atPath: targetPath) else {
             backupManager.progressMessage = "Error: Cannot write to Target path."
             backupManager.errorOccurred = true
             return
        }

        // Call the BackupManager to perform the backup
        backupManager.runBackup(source: sourcePath, target: targetPath)

        // Removed simulation code
        // print("Starting backup from \(sourcePath) to \(targetPath)")
        // DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        //     isBackupRunning = false
        //     backupStatus = "Backup Complete (Simulated)"
        // }
    }
}

// MARK: - Helper View for Warning

struct FullDiskAccessWarningView: View {
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading) {
                Text("Full Disk Access Required")
                    .font(.headline)
                Text("YeOldBackup needs Full Disk Access to read and write files for backup. Please grant access in System Settings.")
                    .font(.caption)
            }
            Spacer()
            Button("Open Settings") {
                BackupPermissions.openPrivacySettings()
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.2))
        .cornerRadius(8)
    }
}

// MARK: - Permission Utilities

struct BackupPermissions {
    // Check Full Disk Access by attempting to read a restricted directory
    static func checkFullDiskAccess() -> Bool {
        // Use Dispatcher to ensure we try reading on a background thread
        // to avoid blocking the main thread if access is slow or hangs.
        // Although for this specific check, it's usually fast.
        let checkPath = "/Library/Application Support/com.apple.TCC/TCC.db" // A known restricted file
        // Alternative: Try listing contents of ~/Library/Safari or similar
        // let checkURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari")
        do {
             // Check if the file exists first, as trying to read attributes of a non-existent file also throws.
            if FileManager.default.fileExists(atPath: checkPath) {
                _ = try FileManager.default.attributesOfItem(atPath: checkPath)
                return true // If we can read attributes, we likely have access
            } else {
                 // If the TCC.db file doesn't exist (less common), fall back to another check.
                 // Let's try listing a directory that typically requires FDA.
                let fallbackDir = "~/Library/Safari".expandingTildeInPath
                _ = try FileManager.default.contentsOfDirectory(atPath: fallbackDir)
                return true
            }
        } catch {
            print("Full Disk Access check failed: \(error)")
            return false // Access denied or other error
        }
    }

    // Opens System Settings/Preferences to the Full Disk Access pane
    static func openPrivacySettings() {
        // Modern way for macOS Ventura+ (requires adding URL Scheme to Info.plist)
        // let privacyUrl = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        // NSWorkspace.shared.open(privacyUrl)

        // More compatible way using AppleScript (works on Monterey, Ventura, Sonoma+)
        let scriptSource = "tell application \"System Settings\"\nactivate\nreveal anchor \"Privacy_AllFiles\" of pane id \"com.apple.settings.PrivacySecurity.extension\"\nend tell"
        // Fallback for older macOS versions (Monterey might need System Preferences)
        let scriptSourceLegacy = "tell application \"System Preferences\"\nactivate\nreveal anchor \"Privacy_AllFiles\" of pane id \"com.apple.preference.security\"\nend tell"

        // Check macOS version to decide which script to run
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)) {
             // macOS 13 (Ventura) and later
            runAppleScript(scriptSource)
        } else {
            // macOS 12 (Monterey) and earlier
            runAppleScript(scriptSourceLegacy)
        }
    }

    private static func runAppleScript(_ source: String) {
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&error)
            if let err = error {
                print("AppleScript Error: \(err)")
            }
        }
    }

    // Helper to expand tilde
    private static func expandTilde(inPath path: String) -> String {
        return (path as NSString).expandingTildeInPath
    }
}

extension String {
    var expandingTildeInPath: String {
        return (self as NSString).expandingTildeInPath
    }
}

#Preview {
    ContentView()
} 
