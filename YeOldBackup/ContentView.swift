import SwiftUI
import AppKit // Required for NSOpenPanel
import SystemConfiguration // For System Preferences URL

struct ContentView: View {
    // Use AppStorage to automatically persist/load from UserDefaults
    @AppStorage("sourcePath") private var sourcePath: String = ""
    @AppStorage("targetPath") private var targetPath: String = ""

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
                TextField("No source selected", text: .constant(sourcePath))
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
                TextField("No target selected", text: .constant(targetPath))
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
            // Initialize status message on appear if not already running
            if !backupManager.isRunning {
                backupManager.progressMessage = "Ready"
            }
        }
        // Re-check permissions when the app becomes active again
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
             checkPermissions()
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

    // Function to open the directory selection panel
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
                // Persist access permissions using security-scoped bookmarks
                _ = url.startAccessingSecurityScopedResource()

                let path = url.path
                DispatchQueue.main.async {
                    if type == .source {
                        self.sourcePath = path
                    } else {
                        self.targetPath = path
                    }
                    // Reset status only if not currently running
                    if !backupManager.isRunning {
                         backupManager.progressMessage = "Ready"
                         backupManager.errorOccurred = false // Reset error state too
                    }
                }
                // Note: You might want to stop accessing the resource later
                // url.stopAccessingSecurityScopedResource()
                // Or better, store the bookmark data and resolve it when needed.
                // For this simple app, retaining access until app quit might be acceptable.
            }
        }
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
