import SwiftUI
import AppKit // Required for NSOpenPanel
import SystemConfiguration // For System Preferences URL

// MARK: - Data Model for History

struct BackupHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var sourceBookmark: Data
    var targetBookmark: Data
    var sourcePath: String // Store for display, update if bookmark resolves differently
    var targetPath: String // Store for display, update if bookmark resolves differently
    var lastSync: Date

    // Helper to get the last path component for display
    var sourceName: String {
        return (sourcePath as NSString).lastPathComponent
    }
    var targetName: String {
        return (targetPath as NSString).lastPathComponent
    }

    // Equatable conformance based on bookmarks - assumes bookmarks are the canonical identity
    static func == (lhs: BackupHistoryEntry, rhs: BackupHistoryEntry) -> Bool {
        return lhs.sourceBookmark == rhs.sourceBookmark && lhs.targetBookmark == rhs.targetBookmark
    }
}

struct ContentView: View {
    // Use AppStorage to store bookmark data for CURRENT selection
    @AppStorage("sourceBookmarkData") private var sourceBookmarkData: Data?
    @AppStorage("targetBookmarkData") private var targetBookmarkData: Data?
    // Use AppStorage to store the encoded history data
    @AppStorage("backupHistoryData") private var backupHistoryData: Data?

    // State variables to hold the resolved paths for display and use (Current Selection)
    @State private var sourcePath: String = ""
    @State private var targetPath: String = ""

    // State variables to hold the URLs we are currently accessing (Current Selection)
    @State private var accessedSourceURL: URL?
    @State private var accessedTargetURL: URL?

    // State variable to hold the loaded backup history
    @State private var history: [BackupHistoryEntry] = []
    // State variable to track the selected history item for highlighting
    @State private var selectedHistoryEntryID: UUID? = nil

    // Instantiate the BackupManager
    @StateObject private var backupManager = BackupManager()
    @State private var hasFullDiskAccess: Bool = false

    // Date Formatter for display
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

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

            Divider()

            // MARK: - Backup History List
            Text("Backup History")
                .font(.headline)
            
            // Implement using SwiftUI Table
            Table(history, selection: $selectedHistoryEntryID) {
                TableColumn("Source") { entry in
                    // Provide content to allow tooltips if needed
                    Text(entry.sourceName).help(entry.sourcePath)
                }
                .width(min: 100, ideal: 150)
                
                TableColumn("To") { _ in
                    Image(systemName: "arrow.right")
                }
                .width(25)
                
                TableColumn("Target") { entry in
                     // Provide content to allow tooltips if needed
                    Text(entry.targetName).help(entry.targetPath)
                }
                .width(min: 100, ideal: 150)
                
                TableColumn("Last Synced") { entry in
                    Text(entry.lastSync, formatter: dateFormatter)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .width(min: 120, ideal: 150)
            }
            //.tableStyle(.inset) // Use default style for now, feels more native
            .frame(minHeight: 100, maxHeight: 200) // Keep size constraints
            .disabled(backupManager.isRunning || !hasFullDiskAccess)
            .onChange(of: selectedHistoryEntryID) { oldID, newID in
                 // Handle selection change - load the selected entry
                 guard let id = newID, id != oldID else { // Ensure there's a change and a new selection
                      // Handle deselection if needed, e.g., clear main paths?
                      // For now, just prevent processing if no new valid ID.
                      // print("Selection cleared or unchanged.")
                      return
                 }
                 
                 if let selectedEntry = history.first(where: { $0.id == id }) {
                     print("Table selection changed to: \(selectedEntry.id)")
                     selectHistoryEntry(selectedEntry) // Call existing function to load it
                 } else {
                      print("Warning: Selected ID \(id) not found in history.")
                 }
             }
            // Add context menu for the selected row(s)
            .contextMenu(forSelectionType: BackupHistoryEntry.ID.self) { selectedIDs in
                // Ensure there's a selection to act upon
                if !selectedIDs.isEmpty {
                    Button("Remove from List", role: .destructive) {
                        for id in selectedIDs {
                            if let entryToDelete = history.first(where: { $0.id == id }) {
                                deleteHistoryEntry(entryToDelete: entryToDelete)
                            }
                        }
                    }
                }
                // Add other potential actions here if needed
            }

            Spacer() // Pushes controls to top and bottom

            // Backup Controls and Status (Now in a VStack)
            VStack(alignment: .leading) { // <<< WRAPPED in VStack
                HStack { // <<< Original HStack for button/progress/percentage
                    if backupManager.isRunning {
                        Button("Stop Sync") {
                            backupManager.stopBackup()
                        }
                        .buttonStyle(.borderedProminent) // Make stop button prominent
                        .tint(.red)
                    } else {
                        Button("Sync Now") {
                            startBackup()
                        }
                        .disabled(sourcePath.isEmpty || targetPath.isEmpty || backupManager.isRunning || !hasFullDiskAccess)
                        .keyboardShortcut(.defaultAction) // Allow hitting Enter to backup
                    }

                    // Determinate ProgressView bound to the BackupManager's progress
                    ProgressView(value: backupManager.progressValue)
                        .padding(.leading, 5)
                        // Show the progress bar only when running
                        .opacity(backupManager.isRunning ? 1 : 0)

                    // <<< ADDED: Percentage Text
                    if backupManager.isRunning && backupManager.totalFilesToTransfer > 0 {
                        Text(String(format: "%.0f%%", backupManager.progressValue * 100))
                            .font(.caption)
                            .padding(.leading, 5)
                    }
                } // End HStack for button/progress/percentage

                // <<< ADDED HStack for Status Text and Spinner
                HStack(spacing: 5) {
                    Text(detailedStatusText)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(statusColor)

                    // Show spinner only during active sync phase
                    if backupManager.isRunning && backupManager.totalFilesToTransfer > 0 {
                        ProgressView()
                            .controlSize(.small) // Make spinner smaller
                    }
                    Spacer() // Push text/spinner left
                }
                .frame(maxWidth: .infinity) // Ensure HStack takes full width

            } // End VStack for controls and status
            .padding(.top)
        }
        .padding()
        .frame(minWidth: 550, minHeight: 300) // Adjusted size for warning
        .onAppear {
            checkPermissions()
            resolveBookmarks()
            // Initialize status message on appear if not already running
            if !backupManager.isRunning {
                backupManager.progressMessage = "Ready"
            }
            loadHistory() // <<< CALL IT HERE INSIDE onAppear
            // <<< ADDED: Check for matching history on initial load
            findAndSelectMatchingHistoryEntry()
        }
        // Re-check permissions when the app becomes active again
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
             checkPermissions()
             // Re-resolve bookmarks in case permissions changed while inactive
             resolveBookmarks()
        }
        // Watch for backup completion to update history
        .onChange(of: backupManager.isRunning) { wasRunning, isRunning in
             if wasRunning && !isRunning && !backupManager.errorOccurred {
                 // Backup finished successfully
                 updateHistoryAfterSuccess()
             }
         }
        // <<< ADDED: Monitor bookmark changes to auto-select history
        .onChange(of: sourceBookmarkData) { _, _ in findAndSelectMatchingHistoryEntry() }
        .onChange(of: targetBookmarkData) { _, _ in findAndSelectMatchingHistoryEntry() }
    }

    // Computed properties for status display
    private var detailedStatusText: String {
        if !hasFullDiskAccess {
            return "Requires Full Disk Access"
        }
        if backupManager.isRunning && backupManager.totalFilesToTransfer > 0 {
            let filePart = backupManager.currentFileName.isEmpty ? "file..." : backupManager.currentFileName
            return "Syncing \(filePart) (\(backupManager.filesProcessedCount)/\(backupManager.totalFilesToTransfer))"
        }
        if backupManager.progressMessage.isEmpty && !backupManager.isRunning {
            return "Ready"
        } else {
            return backupManager.progressMessage // Display Calculating, Complete, Failed, etc.
        }
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
                            self.selectedHistoryEntryID = nil // Clear history selection
                        } else {
                            self.targetBookmarkData = bookmarkData
                            self.targetPath = url.path // Update display path
                             // Resolve immediately to start accessing the *new* selection
                            self.accessedTargetURL = resolveBookmark(data: bookmarkData, type: .target)
                            self.selectedHistoryEntryID = nil // Clear history selection
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
                        self.selectedHistoryEntryID = nil // Clear history selection
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
    private func resolveBookmark(data: Data, type: PathType, updateState: Bool = true) -> URL? {
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
                     if type == .source, updateState {
                         self.sourceBookmarkData = newBookmarkData
                         self.sourcePath = resolvedUrl.path
                     } else if type == .target, updateState {
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
                      if type == .source, updateState {
                          self.sourcePath = resolvedUrl.path
                      } else if type == .target, updateState {
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
                    if updateState { self.sourceBookmarkData = nil }
                    self.sourcePath = ""
                    self.accessedSourceURL = nil // Clear the state URL too
                } else {
                    if updateState { self.targetBookmarkData = nil }
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

    // MARK: - History Load/Save

    private func loadHistory() {
        guard let data = backupHistoryData else {
            print("No history data found in AppStorage.")
            self.history = []
            return
        }
        do {
            self.history = try JSONDecoder().decode([BackupHistoryEntry].self, from: data)
            print("Successfully loaded \(history.count) history entries.")
            // Sort history by date, most recent first
            self.history.sort { $0.lastSync > $1.lastSync }
        } catch {
            print("Error decoding backup history: \(error). Resetting history.")
            self.history = []
            self.backupHistoryData = nil // Clear corrupted data
        }
    }

    private func saveHistory() {
        do {
            // Sort before saving - <<< REMOVE SORTING HERE, it happens before assignment now
             // self.history.sort { $0.lastSync > $1.lastSync }
            let data = try JSONEncoder().encode(history) // Encode the current state
            backupHistoryData = data
            print("Successfully saved \(history.count) history entries.")
        } catch {
            print("Error encoding backup history: \(error)")
            // Consider notifying the user
        }
    }
    
    // MARK: - History Interaction
    
    private func selectHistoryEntry(_ entry: BackupHistoryEntry) {
        print("Attempting to select history entry: ID \(entry.id)")
        guard hasFullDiskAccess else {
            backupManager.progressMessage = "Requires Full Disk Access"
            backupManager.errorOccurred = true
            return
        }
        guard !backupManager.isRunning else { return } // Don't change while running
        
        // Attempt to resolve both source and target from the history entry's bookmarks
        // This implicitly checks for accessibility/connectivity.
        let resolvedSource = resolveBookmark(data: entry.sourceBookmark, type: .source, updateState: false) // Don't update main state yet
        let resolvedTarget = resolveBookmark(data: entry.targetBookmark, type: .target, updateState: false) // Don't update main state yet
        
        if let sourceURL = resolvedSource, let targetURL = resolvedTarget {
            print("Successfully resolved both source (\(sourceURL.path)) and target (\(targetURL.path)) for history entry.")
            // Resolution successful, now update the main state
            
            // 1. Stop accessing previously selected URLs (if any)
            stopAccessingAllURLs()
            
            // 2. Update AppStorage bookmarks
            self.sourceBookmarkData = entry.sourceBookmark
            self.targetBookmarkData = entry.targetBookmark
            
            // 3. Update path state variables
            self.sourcePath = sourceURL.path
            self.targetPath = targetURL.path
            
            // 4. Update accessed URL state variables (critical!)
            self.accessedSourceURL = sourceURL
            self.accessedTargetURL = targetURL
            
            // 5. Update selection state for highlighting
            self.selectedHistoryEntryID = entry.id
            
            // 5. Update status message
            backupManager.progressMessage = "Loaded: \(shortPath(sourceURL.path)) -> \(shortPath(targetURL.path))"
            backupManager.errorOccurred = false
            
            // Re-start access (resolveBookmark with updateState:false didn't start it)
             _ = sourceURL.startAccessingSecurityScopedResource()
             _ = targetURL.startAccessingSecurityScopedResource()
             print("Restarted access for newly selected source and target.")

            // <<< ADDED: Check if this newly loaded pair matches history
            // No need here, selection directly sets the ID.
            // findAndSelectMatchingHistoryEntry()

        } else {
            print("Failed to resolve source or target for history entry.")
            // Resolution failed for one or both
            backupManager.progressMessage = "Error: Cannot access source/target for selected history."
            backupManager.errorOccurred = true
            // Optionally, clear the main selection?
             // clearSelection()
            self.selectedHistoryEntryID = nil // Clear selection if load fails
        }
    }
    
    private func updateHistoryAfterSuccess() {
        print("Attempting to update history after successful backup.")
        guard let currentSourceBookmark = sourceBookmarkData, let currentTargetBookmark = targetBookmarkData else {
            print("History update skipped: Missing current source or target bookmark data.")
            return
        }
        
        let now = Date()
        let currentSourcePath = self.sourcePath // Use the path currently in state
        let currentTargetPath = self.targetPath // Use the path currently in state

        // Find index of existing entry based on bookmark data
        var historyUpdated = false
        var updatedHistory = self.history // Work on a mutable copy

        if let index = updatedHistory.firstIndex(where: { $0.sourceBookmark == currentSourceBookmark && $0.targetBookmark == currentTargetBookmark }) {
            // Existing entry found, update it
            let oldEntry = updatedHistory.remove(at: index) // Remove the old entry
            let updatedEntry = BackupHistoryEntry(id: oldEntry.id, // Keep the same ID
                                                 sourceBookmark: currentSourceBookmark,
                                                 targetBookmark: currentTargetBookmark,
                                                 sourcePath: currentSourcePath,
                                                 targetPath: currentTargetPath,
                                                 lastSync: now) // Use the new timestamp
            updatedHistory.append(updatedEntry) // Append the new version

            print("Replaced existing history entry for ID \(oldEntry.id).")
            print("New last sync date: \(updatedEntry.lastSync)")
            print("Now: \(now)")
            historyUpdated = true
        } else {
            // No existing entry, create a new one
            let newEntry = BackupHistoryEntry(id: UUID(),
                                              sourceBookmark: currentSourceBookmark,
                                              targetBookmark: currentTargetBookmark,
                                              sourcePath: currentSourcePath,
                                              targetPath: currentTargetPath,
                                              lastSync: now)
            updatedHistory.append(newEntry)
            print("Added new history entry with ID \(newEntry.id).")
            historyUpdated = true
        }

        if historyUpdated {
             // Sort the updated copy BEFORE assigning to state
             updatedHistory.sort { $0.lastSync > $1.lastSync }
             self.history = updatedHistory // Assign the sorted, updated array back
             saveHistory() // Save the now-sorted state
             // Explicitly set selection ID to the one just run/added
             self.selectedHistoryEntryID = history.first(where: { $0.sourceBookmark == currentSourceBookmark && $0.targetBookmark == currentTargetBookmark })?.id
         }
    }
    
    // MARK: - History Deletion

    private func deleteHistoryEntry(entryToDelete: BackupHistoryEntry) {
        print("Attempting to delete history entry ID: \(entryToDelete.id)")
        // Remove from the history state array
        history.removeAll { $0.id == entryToDelete.id }

        // If the deleted item was selected, clear the selection state
        if selectedHistoryEntryID == entryToDelete.id {
            selectedHistoryEntryID = nil
            // Optionally clear the main source/target fields as well?
            // sourcePath = ""
            // targetPath = ""
            // sourceBookmarkData = nil
            // targetBookmarkData = nil
            // stopAccessingAllURLs()
            // print("Cleared main selection because deleted history item was active.")
        }

        saveHistory() // Save the updated history
    }

    // MARK: - Automatic History Selection
    
    private func findAndSelectMatchingHistoryEntry() {
        guard let currentSourceBM = sourceBookmarkData, let currentTargetBM = targetBookmarkData else {
            // If either source or target isn't set, clear history selection
            // unless a history item was *just* explicitly clicked (handled by table's onChange)
            // print("Clearing history selection due to missing source/target bookmarks.")
            // self.selectedHistoryEntryID = nil // Avoid clearing if user just clicked history
            return
        }

        print("Checking if current source/target matches history...")
        if let matchingEntry = history.first(where: { $0.sourceBookmark == currentSourceBM && $0.targetBookmark == currentTargetBM }) {
            // Avoid redundant updates if already selected
            if self.selectedHistoryEntryID != matchingEntry.id {
                print("Found matching history entry: \(matchingEntry.id). Selecting.")
                self.selectedHistoryEntryID = matchingEntry.id
            } else {
                // print("Current selection already matches history entry \(matchingEntry.id).")
            }
        } else {
            // Current pair doesn't match any history, clear selection
            print("Current source/target pair does not match any history entry. Clearing selection.")
            self.selectedHistoryEntryID = nil
        }
    }

    // Helper to shorten paths for display
    private func shortPath(_ path: String) -> String {
        return (path as NSString).abbreviatingWithTildeInPath
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
