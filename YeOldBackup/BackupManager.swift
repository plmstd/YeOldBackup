import Foundation
import Combine

// <<< ADDED: Custom Error Type
enum BackupError: Error, LocalizedError {
    case dryRunLaunchFailed(String)
    case dryRunFailed(String)
    case dryRunParseFailed
    case actualRunLaunchFailed(String)
    case processTerminationFailed(String)
    // <<< ADDED: Error for when user cancels confirmation
    case backupCancelledByUser

    var errorDescription: String? {
        switch self {
        case .dryRunLaunchFailed(let msg): return "Failed to launch dry run: \(msg)"
        case .dryRunFailed(let msg): return "Dry run calculation failed: \(msg)"
        case .dryRunParseFailed: return "Could not parse dry run statistics."
        case .actualRunLaunchFailed(let msg): return "Failed to launch backup: \(msg)"
        case .processTerminationFailed(let msg): return "Backup process did not respond to stop signals: \(msg)"
        // <<< ADDED: User-facing message for cancellation
        case .backupCancelledByUser: return "Backup cancelled by user."
        }
    }
}

// <<< MODIFIED: Struct to hold more detailed dry run results
struct DryRunInfo {
    let needsSync: Bool
    let transferCount: Int
    let deletionCount: Int
    let totalSourceFilesCount: Int // Total files rsync considered in the source
}

class BackupManager: ObservableObject {
    @Published var progressMessage: String = ""
    @Published var isRunning: Bool = false // Tracks if any operation (dry run, actual sync) is active
    @Published var errorOccurred: Bool = false
    @Published var lastErrorMessage: String = ""
    @Published var progressValue: Double = 0.0
    @Published var currentFileName: String = ""
    @Published var showReport: Bool = false
    @Published var reportContent: String = ""

    // <<< ADDED: State for deletion confirmation
    @Published var requiresDeletionConfirmation: Bool = false
    // Stores (deletionCount, totalSourceFilesCount)
    @Published var deletionStats: (count: Int, totalSource: Int)? = nil
    // <<< ADDED: Threshold for confirmation (e.g., 10%)
    private let deletionThresholdPercentage: Double = 0.10
    // <<< ADDED: Minimum absolute deletions to trigger confirmation (prevent annoyance for 1 deletion in 1 file)
    private let deletionThresholdAbsoluteCount: Int = 5


    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var cancellables = Set<AnyCancellable>()

    // State for simulated progress
    var totalFilesToTransfer: Int = 0
    var filesProcessedCount: Int = 0

    // --- Main Entry Point for Backup ---
    func runBackup(source: String, target: String) {
        guard !isRunning else {
            print("Backup already in progress.")
            return
        }

        // Reset state for a new run
        DispatchQueue.main.async {
            self.isRunning = true // Mark as running for the entire operation (dry + actual)
            self.progressMessage = "Preparing backup..."
            self.errorOccurred = false
            self.lastErrorMessage = ""
            self.progressValue = 0.0
            self.filesProcessedCount = 0
            self.totalFilesToTransfer = 0
            self.currentFileName = ""
            self.showReport = false
            self.reportContent = ""
            self.requiresDeletionConfirmation = false // Reset confirmation flag
            self.deletionStats = nil
        }

        // Perform dry run asynchronously
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let rsyncSource = source.hasSuffix("/") ? source : source + "/"
            let rsyncTarget = target

            // --- Phase 1: Dry Run ---
            DispatchQueue.main.async {
                self.progressMessage = "Calculating changes..."
            }

            let dryRunResult = self.performDryRun(source: rsyncSource, target: rsyncTarget)

            // Check dry run result
            switch dryRunResult {
            case .success(let info):
                // Check if any sync operation is needed at all
                if !info.needsSync {
                    DispatchQueue.main.async {
                        self.progressMessage = "Already up to date."
                        self.isRunning = false // Finished
                        self.progressValue = 1.0
                    }
                    self.cleanupRunningProcess()
                    return // Nothing to do
                }

                // Store transfer count for progress bar (even if confirmation needed later)
                self.totalFilesToTransfer = info.transferCount

                // --- Deletion Confirmation Logic ---
                var deletionPercentage: Double = 0.0
                if info.totalSourceFilesCount > 0 {
                     deletionPercentage = Double(info.deletionCount) / Double(info.totalSourceFilesCount)
                } else if info.deletionCount > 0 {
                     // If source has 0 files but deletions exist, it's 100% deletion of target content
                     deletionPercentage = 1.0
                }
                
                print("Dry Run Deletion Check: Count=\(info.deletionCount), TotalSource=\(info.totalSourceFilesCount), Percentage=\(deletionPercentage)")


                // Check if deletion count is above absolute OR percentage threshold
                if info.deletionCount >= self.deletionThresholdAbsoluteCount && deletionPercentage >= self.deletionThresholdPercentage {
                    print("Deletion threshold met. Requesting confirmation.")
                    // Threshold met, require confirmation
                    DispatchQueue.main.async {
                        self.deletionStats = (count: info.deletionCount, totalSource: info.totalSourceFilesCount)
                        self.requiresDeletionConfirmation = true
                        // Update message, but keep isRunning = true as the overall operation isn't finished/cancelled yet
                        self.progressMessage = "Confirmation Required: \(info.deletionCount) deletions pending."
                        // Do NOT proceed to actual backup here
                    }
                    // Stop processing in this background thread, wait for UI confirmation
                    return
                } else {
                     // Deletion count is low or percentage is below threshold, proceed directly
                     print("Deletion threshold not met (\(info.deletionCount) deletions, \(String(format: "%.1f%%", deletionPercentage * 100))). Proceeding with sync.")
                     // Call the actual backup function (already on background thread)
                     self.performActualBackup(source: rsyncSource, target: rsyncTarget)
                }


            case .failure(let error):
                DispatchQueue.main.async {
                    self.errorOccurred = true
                    self.lastErrorMessage = error.localizedDescription
                    self.progressMessage = "Error during calculation"
                    self.isRunning = false // Finished with error
                }
                self.cleanupRunningProcess()
                return
            }
        }
    }

    // --- Function Called After User Confirms Deletion ---
    func confirmAndProceedWithBackup(source: String, target: String) {
         print("User confirmed deletion. Proceeding with actual backup.")
         // Ensure we're on a background thread to perform the sync
         DispatchQueue.global(qos: .userInitiated).async { [weak self] in
             guard let self = self else { return }

             // Reset confirmation flag on main thread
             DispatchQueue.main.async {
                 self.requiresDeletionConfirmation = false
                 self.deletionStats = nil
                 // Message will be updated by performActualBackup
             }

             let rsyncSource = source.hasSuffix("/") ? source : source + "/"
             let rsyncTarget = target

             // Execute the actual backup
             self.performActualBackup(source: rsyncSource, target: rsyncTarget)
         }
    }

    // --- Function Called if User Cancels Confirmation ---
    func cancelBackupConfirmation() {
        print("User cancelled deletion confirmation.")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isRunning = false // Stop the overall operation
            self.requiresDeletionConfirmation = false
            self.deletionStats = nil
            self.errorOccurred = true // Treat cancellation as a form of "error" or non-completion
            self.lastErrorMessage = BackupError.backupCancelledByUser.localizedDescription
            self.progressMessage = "Backup Cancelled."
            self.progressValue = 0.0
            self.showReport = true // Show a report indicating cancellation
            self.reportContent = "Backup was cancelled by the user before sync started."

            // Ensure any lingering process object from dry run is cleaned up
            self.cleanupRunningProcess()
        }
    }


    // --- Private Helper for Actual Backup Execution ---
    private func performActualBackup(source rsyncSource: String, target rsyncTarget: String) {
         // This function assumes it's already called on a background thread.
         // It also assumes totalFilesToTransfer has been set by the dry run.

         DispatchQueue.main.async {
             // Update status message for the actual sync phase
             if self.totalFilesToTransfer > 0 {
                 self.progressMessage = "Syncing \(self.totalFilesToTransfer) files..."
             } else {
                  // This case might happen if only deletions were needed and they were below threshold
                 self.progressMessage = "Performing sync operations..."
             }
             self.filesProcessedCount = 0 // Ensure reset before run
             self.progressValue = 0.0
             self.currentFileName = ""
             // isRunning should already be true
         }

          // Setup the actual rsync process
          self.process = Process()
          self.process?.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
          self.process?.arguments = [
              "-a",
              "--delete",
              "-i", // Itemize changes for parsing file counts
              "-v", // Verbose output for potential deletion details if needed later
              "--exclude", ".Spotlight-V100/",
              "--exclude", ".fseventsd/",
              "--exclude", ".Trashes",
              "--exclude", ".TemporaryItems/",
              "--exclude", ".DS_Store",
              rsyncSource,
              rsyncTarget
          ]

         self.outputPipe = Pipe()
         self.errorPipe = Pipe()
         self.process?.standardOutput = self.outputPipe
         self.process?.standardError = self.errorPipe

         // --- Output Parsing (Itemized Changes) ---
         self.outputPipe?.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
             guard let self = self else { return }
             let data = fileHandle.availableData
             if data.isEmpty { // EOF
                 self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                 return // <<< ADDED return to prevent processing empty data
             }
             // <<< MODIFIED: Process output immediately
             if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                 // print("stdout chunk: \(output)") // DEBUG
                 let lines = output.split(whereSeparator: \.isNewline)
                 var processedInChunk = 0
                 var latestFileNameInChunk: String? = nil
                 var reportChunk = "" // Accumulate for report

                 for line in lines {
                     let lineStr = String(line) // Convert Substring to String
                     // Simple check for itemized file transfer start: ">f"
                     if lineStr.hasPrefix(">f") {
                         processedInChunk += 1
                         // Extract filename (rudimentary, assumes space after 10-char code)
                         if lineStr.count > 11 {
                             let fileNamePart = String(lineStr.dropFirst(11)).trimmingCharacters(in: .whitespaces)
                             if !fileNamePart.isEmpty {
                                 latestFileNameInChunk = fileNamePart
                                 // print("Parsed filename: \(fileNamePart)") // DEBUG
                             }
                         }
                     }
                     // Append line to report chunk unless it's just a dot (often means directory processed)
                     if lineStr != "." {
                          reportChunk += lineStr + "\n"
                     }
                 }


                 // Update progress and report content on the main thread
                 DispatchQueue.main.async {
                    // Append to the main report
                    if !reportChunk.isEmpty {
                         self.reportContent += reportChunk
                    }

                    if processedInChunk > 0 {
                        self.filesProcessedCount += processedInChunk
                        let displayCount = min(self.filesProcessedCount, self.totalFilesToTransfer)
                        // Update progress only if totalFilesToTransfer is positive
                        let newProgress = self.totalFilesToTransfer > 0 ? Double(displayCount) / Double(self.totalFilesToTransfer) : 0.0 // Avoid division by zero
                        self.progressValue = max(0.0, min(1.0, newProgress))

                        if let newName = latestFileNameInChunk {
                            self.currentFileName = newName
                        }
                        // Update message only if progress changed significantly or filename changed
                        if self.totalFilesToTransfer > 0 {
                             self.progressMessage = "Syncing \(self.currentFileName)... (\(displayCount)/\(self.totalFilesToTransfer))"
                        } else {
                             self.progressMessage = "Syncing \(self.currentFileName)..." // Case with only deletions
                        }
                        // print("Processed: \(self.filesProcessedCount), Total: \(self.totalFilesToTransfer), Progress: \(self.progressValue)")
                    }
                 }
             }
         }


         // --- Error Parsing ---
         self.errorPipe?.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
              guard let self = self else { return }
              let data = fileHandle.availableData
              if data.isEmpty {
                  self.errorPipe?.fileHandleForReading.readabilityHandler = nil
                  return // <<< ADDED return
              }
              // <<< MODIFIED: Process error output immediately
              if let errorOutput = String(data: data, encoding: .utf8), !errorOutput.isEmpty {
                 DispatchQueue.main.async {
                      print("rsync stderr: \(errorOutput)")
                      self.errorOccurred = true
                      let trimmedError = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                      // Append to overall error message and report
                      if !self.lastErrorMessage.contains(trimmedError) { // Avoid duplicates
                         self.lastErrorMessage += trimmedError + "\n"
                         self.reportContent += "ERROR: " + trimmedError + "\n" // Add errors to report
                      }
                      self.progressMessage = "Error occurred..." // Keep it simple
                 }
              }
         }

         // --- Process Termination ---
         self.process?.terminationHandler = { [weak self] process in
              guard let self = self else { return }
              // Wait briefly for final stdout/stderr chunks to be processed
              DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                   // Cleanup pipes *before* updating final state on main thread
                   self.cleanupRunningProcess()
                   DispatchQueue.main.async {
                       self.isRunning = false // Mark as finished
                       self.showReport = true // Always show report after completion or error
                       let exitCode = process.terminationStatus
                       if exitCode == 0 && !self.errorOccurred {
                           self.progressMessage = "Backup Complete."
                           self.progressValue = 1.0
                           // Prepend summary to report content
                           self.reportContent = "Finished sync successfully.\n---\n" + self.reportContent
                           print("rsync finished successfully.")
                       } else {
                           self.errorOccurred = true // Ensure flag is set
                           let baseErrorMsg = "rsync failed with exit code \(exitCode)."
                           if self.lastErrorMessage.isEmpty {
                                self.lastErrorMessage = baseErrorMsg
                           } else if !self.lastErrorMessage.contains(baseErrorMsg) {
                                // Add exit code info if not already present from stderr
                                self.lastErrorMessage = baseErrorMsg + "\n" + self.lastErrorMessage
                           }
                           self.progressMessage = "Backup Failed."
                           // Prepend summary to report content
                           self.reportContent = "Backup finished with errors (Code: \(exitCode)).\nErrors:\n\(self.lastErrorMessage)\n---\nDetails:\n" + self.reportContent
                           print("rsync failed. Status: \(exitCode), Error Accum: \(self.lastErrorMessage)")
                       }
                       // Clear dynamic parts of status
                       self.currentFileName = ""
                   }
              }
         }

         // --- Run the Process ---
         do {
             // Clear report content before starting actual run
             DispatchQueue.main.async { self.reportContent = "" }
             try self.process?.run()
         } catch {
             print("Failed to run actual rsync process: \(error)")
             DispatchQueue.main.async {
                 self.isRunning = false
                 self.errorOccurred = true
                 self.lastErrorMessage = "Failed to launch rsync: \(error.localizedDescription)"
                 self.progressMessage = "Error: Cannot start backup."
                 self.showReport = true
                 self.reportContent = "Failed to launch rsync process: \(error.localizedDescription)"
             }
             self.cleanupRunningProcess()
         }
    }


    // Helper function to perform the dry run and parse the count
    private func performDryRun(source: String, target: String) -> Result<DryRunInfo, BackupError> {
        let dryRunProcess = Process()
        dryRunProcess.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")

        dryRunProcess.arguments = [
            "-n", // Dry run
            "-a", // Archive mode
            "--delete", // Include deletions in calculation
            "--stats", // Get statistics
            "-i", // Itemize changes (needed to detect *if* changes exist beyond stats summary)
            // "-v", // Verbose output - not strictly needed if parsing stats and itemized summary
            "--exclude", ".Spotlight-V100/",
            "--exclude", ".fseventsd/",
            "--exclude", ".Trashes",
            "--exclude", ".TemporaryItems/",
            "--exclude", ".DS_Store",
            source,
            target
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        dryRunProcess.standardOutput = outputPipe
        dryRunProcess.standardError = errorPipe

        do {
            print("Starting dry run...") // DEBUG
            try dryRunProcess.run()
            dryRunProcess.waitUntilExit() // Wait for the dry run to complete
            print("Dry run finished with status: \(dryRunProcess.terminationStatus)") // DEBUG

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let outputString = String(data: outputData, encoding: .utf8) ?? ""
            let errorString = String(data: errorData, encoding: .utf8) ?? ""

             // print("Dry run stdout:\n\(outputString)") // DEBUG
             // print("Dry run stderr:\n\(errorString)") // DEBUG


            if dryRunProcess.terminationStatus == 0 {
                // Parse stats
                var totalSourceFilesCount = 0
                var transferCount = 0
                var deletionCount = 0
                var statsFound = false
                var itemizedChangesFound = false

                // Check for the presence of the stats block summary
                 if let statsRange = outputString.range(of: "Number of files:") {
                     statsFound = true
                     // Parse Total Files
                     let totalFilesSubstring = outputString[statsRange.upperBound...]
                     if let totalFilesValue = totalFilesSubstring.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces).split(separator: " ").first {
                         totalSourceFilesCount = Int(totalFilesValue) ?? 0
                     }

                     // Parse Files Transferred
                     if let transferRange = outputString.range(of: "Number of files transferred:") {
                         let transferSubstring = outputString[transferRange.upperBound...]
                         if let transferValue = transferSubstring.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces) {
                             transferCount = Int(transferValue) ?? 0
                         }
                     }
                     
                     // Parse Deletions - Look for specific line first
                     if let deletionRange = outputString.range(of: "Number of deleted files:") { // Some rsync versions use this
                         let deletionSubstring = outputString[deletionRange.upperBound...]
                         if let deletionValue = deletionSubstring.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces) {
                             deletionCount = Int(deletionValue) ?? 0
                         }
                     } else if let deletionRange = outputString.range(of: "Number of deletions:") { // Others use this
                         let deletionSubstring = outputString[deletionRange.upperBound...]
                         if let deletionValue = deletionSubstring.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces) {
                              deletionCount = Int(deletionValue) ?? 0
                         }
                     }
                     // If stats show 0 deletions, still check itemized list for "*deleting" as a fallback
                     if deletionCount == 0 && outputString.contains("*deleting") {
                         deletionCount = outputString.components(separatedBy: "\n").filter { $0.hasPrefix("*deleting") }.count
                         print("Parsed deletion count from itemized list as fallback: \(deletionCount)")
                     }


                 } else {
                     print("Warning: Dry run stats block not found in output.")
                     // Attempt to infer counts from itemized list if stats are missing
                     let lines = outputString.split(whereSeparator: \.isNewline)
                     totalSourceFilesCount = lines.filter { $0.hasPrefix(".") || $0.hasPrefix(">f") || $0.hasPrefix("cd") }.count // Approximate
                     transferCount = lines.filter { $0.hasPrefix(">f") }.count
                     deletionCount = lines.filter { $0.hasPrefix("*deleting") }.count
                     print("Inferred counts from itemized: Total~\(totalSourceFilesCount), Transfers=\(transferCount), Deletions=\(deletionCount)")
                 }
                 
                 // Check if any itemized changes were listed (more reliable than just stats summary)
                 itemizedChangesFound = outputString.split(whereSeparator: \.isNewline).contains { line in
                     line.hasPrefix(">f") || line.hasPrefix(".f") || line.hasPrefix("*deleting") || line.hasPrefix("cd") || line.hasPrefix(".d")
                 }

                // Determine if a sync is needed based on *either* stats or itemized changes
                let needsSync = itemizedChangesFound || transferCount > 0 || deletionCount > 0

                print("Dry run parsed: NeedsSync=\(needsSync), Transfers=\(transferCount), Deletions=\(deletionCount), TotalSource=\(totalSourceFilesCount)")

                // Return success with the parsed info
                return .success(DryRunInfo(needsSync: needsSync,
                                           transferCount: transferCount,
                                           deletionCount: deletionCount,
                                           totalSourceFilesCount: totalSourceFilesCount))

            } else {
                // Dry run process failed
                print("Dry run failed. Status: \(dryRunProcess.terminationStatus), Error: \(errorString)")
                let message = errorString.isEmpty ? "Dry run exited with code \(dryRunProcess.terminationStatus)." : errorString.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(.dryRunFailed(message))
            }
        } catch {
            print("Failed to launch dry run process: \(error)")
            return .failure(.dryRunLaunchFailed(error.localizedDescription))
        }
    }


    // Function to stop the backup if running
    func stopBackup() {
        guard let currentProcess = process, isRunning else {
            print("StopBackup called but no process running or not in running state.")
            // Ensure state is consistent if called spuriously
            if !isRunning {
                 cleanupRunningProcess()
                 // Optionally reset UI state if needed here
            }
            return
        }
        print("Attempting to stop rsync process...")

        // Set a flag or message immediately on the main thread
        DispatchQueue.main.async { [weak self] in
             guard let self = self else { return }
             // Only update message if we haven't already finished/failed
             if self.isRunning {
                 self.progressMessage = "Stopping backup..."
                 self.showReport = false // Hide report during stop attempt
                 self.reportContent = ""
                 self.requiresDeletionConfirmation = false // Clear confirmation if stopping
                 self.deletionStats = nil
             }
        }

        // Terminate the process
        currentProcess.terminate() // Sends SIGTERM

        // Schedule checks to ensure termination
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
             guard let self = self, currentProcess.isRunning else { return } // Check if still running
             print("rsync did not terminate with SIGTERM, sending SIGINT.")
             currentProcess.interrupt() // Sends SIGINT

             // Final check to force state reset if it's still stuck
             DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                 guard let self = self else { return }
                 // Check isRunning state *on main thread* which terminationHandler should update
                 if self.isRunning {
                      print("Backup still marked as running after SIGINT attempt, forcing state reset.")
                      self.isRunning = false
                      self.progressMessage = "Backup Stopped (Forced)."
                      self.errorOccurred = true
                      let stopError = BackupError.processTerminationFailed("Process did not terminate.")
                      self.lastErrorMessage = stopError.localizedDescription
                      self.showReport = true
                      self.reportContent = "Backup was stopped manually (force)."
                      self.progressValue = 0.0
                      self.cleanupRunningProcess() // Final cleanup
                 }
             }
        }
         // Note: The terminationHandler is the primary mechanism for setting isRunning = false.
         // The forced reset above is a fallback.
    }

    // Renamed from cleanupPipes to reflect it cleans the running process state
    private func cleanupRunningProcess() {
        // Ensure handlers are detached before closing pipes/releasing process
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil

        // Close file handles
        // Use try? to ignore potential errors on closing already closed handles
        try? outputPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForReading.close()

        // Release objects
        outputPipe = nil
        errorPipe = nil
        process = nil // Release the process object

        // Don't clear cancellables here, they manage the @Published properties observation
        // cancellables.removeAll()
        print("Cleaned up running process resources.") // DEBUG
    }


    deinit {
        // Ensure process is terminated if BackupManager is deallocated mid-run
        if let process = process, process.isRunning {
             print("BackupManager deinit: Terminating running process.")
             process.terminate()
         }
        cleanupRunningProcess() // Ensure resources are released
        print("BackupManager deinitialized")
    }
} 
