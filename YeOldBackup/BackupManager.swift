import Foundation
import Combine

// <<< ADDED: Custom Error Type
enum BackupError: Error, LocalizedError {
    case dryRunLaunchFailed(String)
    case dryRunFailed(String)
    case dryRunParseFailed
    case actualRunLaunchFailed(String)
    case processTerminationFailed(String)

    var errorDescription: String? {
        switch self {
        case .dryRunLaunchFailed(let msg): return "Failed to launch dry run: \(msg)"
        case .dryRunFailed(let msg): return "Dry run calculation failed: \(msg)"
        case .dryRunParseFailed: return "Could not parse dry run statistics."
        case .actualRunLaunchFailed(let msg): return "Failed to launch backup: \(msg)"
        case .processTerminationFailed(let msg): return "Backup process did not respond to stop signals: \(msg)"
        }
    }
}

class BackupManager: ObservableObject {
    @Published var progressMessage: String = ""
    @Published var isRunning: Bool = false
    @Published var errorOccurred: Bool = false
    @Published var lastErrorMessage: String = ""
    @Published var progressValue: Double = 0.0

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var cancellables = Set<AnyCancellable>()

    // State for simulated progress
    private var totalFilesToTransfer: Int = 0
    private var filesProcessedCount: Int = 0

    func runBackup(source: String, target: String) {
        guard !isRunning else {
            print("Backup already in progress.")
            return
        }

        // Reset state
        DispatchQueue.main.async {
            self.isRunning = true
            self.progressMessage = "Preparing backup..." // Initial message
            self.errorOccurred = false
            self.lastErrorMessage = ""
            self.progressValue = 0.0
            self.filesProcessedCount = 0
            self.totalFilesToTransfer = 0
        }

        // Perform the potentially long-running dry run and actual backup off the main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let rsyncSource = source.hasSuffix("/") ? source : source + "/"
            let rsyncTarget = target

            // --- Phase 1: Dry Run to Count Files ---
            DispatchQueue.main.async {
                self.progressMessage = "Calculating changes..."
            }

            let dryRunResult = self.performDryRun(source: rsyncSource, target: rsyncTarget)

            // Check dry run result
            switch dryRunResult {
            case .success(let count):
                if count == 0 {
                    DispatchQueue.main.async {
                        self.progressMessage = "Already up to date."
                        self.isRunning = false
                        self.progressValue = 1.0 // Show 100% for up-to-date
                    }
                    self.cleanupRunningProcess() // Clean up just in case
                    return // Nothing to do
                }
                // Store count and proceed to actual backup
                self.totalFilesToTransfer = count
                DispatchQueue.main.async {
                    self.progressMessage = "Found \\(count) changes..."
                }

            case .failure(let error):
                DispatchQueue.main.async {
                    self.errorOccurred = true
                    self.lastErrorMessage = error.localizedDescription
                    self.progressMessage = "Error during calculation"
                    self.isRunning = false
                }
                self.cleanupRunningProcess()
                return
            }

            // --- Phase 2: Actual Backup ---
            DispatchQueue.main.async {
                 self.progressMessage = "Starting sync (0 / \\(self.totalFilesToTransfer))..."
                 self.filesProcessedCount = 0 // Ensure reset before run
                 self.progressValue = 0.0
            }

             // Setup the actual rsync process
             self.process = Process()
             self.process?.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
             // Use -i (--itemize-changes) instead of --progress
             self.process?.arguments = [
                 "-a",
                 "--delete",
                 "-i", // Itemize changes for parsing file counts
                 // Add excludes back
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

            // Capture stdout for itemized changes
            self.outputPipe?.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
                guard let self = self else { return }
                let data = fileHandle.availableData
                if data.isEmpty {
                    // EOF
                    self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                } else if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    let lines = output.split(whereSeparator: { $0.isNewline }) // Split strictly by newline for itemized output
                    var processedInChunk = 0
                    for line in lines {
                        // Check if the line starts with ">f" indicating a file transfer
                        // See `man rsync` under --itemize-changes for codes
                        if line.hasPrefix(">f") {
                            processedInChunk += 1
                        }
                        // Potentially count other changes like deletions "*deleting" if desired
                    }

                    if processedInChunk > 0 {
                        self.filesProcessedCount += processedInChunk
                        // Ensure count doesn't exceed total (can happen with symlinks/dirs sometimes depending on exact rsync version/flags)
                        let displayCount = min(self.filesProcessedCount, self.totalFilesToTransfer)
                        // Prevent division by zero
                        let newProgress = self.totalFilesToTransfer > 0 ? Double(displayCount) / Double(self.totalFilesToTransfer) : 0.0
                        // Update progress on the main thread
                        DispatchQueue.main.async {
                             self.progressValue = max(0.0, min(1.0, newProgress)) // Clamp between 0 and 1
                             self.progressMessage = "Syncing (\(displayCount) / \(self.totalFilesToTransfer))..."
                             // print("Processed: \(self.filesProcessedCount), Total: \(self.totalFilesToTransfer), Progress: \(self.progressValue)")
                        }
                    }
                }
            }

            // Capture stderr (same as before)
            self.errorPipe?.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
                 guard let self = self else { return }
                 let data = fileHandle.availableData
                 if data.isEmpty {
                     self.errorPipe?.fileHandleForReading.readabilityHandler = nil
                 } else if let errorOutput = String(data: data, encoding: .utf8), !errorOutput.isEmpty {
                     DispatchQueue.main.async {
                         print("rsync stderr: \(errorOutput)")
                         self.errorOccurred = true
                         self.lastErrorMessage += errorOutput
                         self.progressMessage = "Error: \(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))"
                     }
                 }
            }

            // Monitor termination (adjust completion message)
            self.process?.terminationHandler = { [weak self] process in
                 guard let self = self else { return }
                 // Cleanup pipes *before* updating state on main thread
                 self.cleanupRunningProcess()
                 DispatchQueue.main.async {
                     self.isRunning = false
                     if process.terminationStatus == 0 && !self.errorOccurred {
                         self.progressMessage = "Backup Complete."
                         self.progressValue = 1.0 // Ensure 100% on success
                         print("rsync finished successfully.")
                     } else {
                         self.errorOccurred = true
                         if self.lastErrorMessage.isEmpty {
                              self.lastErrorMessage = "rsync failed with exit code \(process.terminationStatus)."
                         }
                         self.progressMessage = "Backup Failed. Check logs."
                         // Leave progress where it failed
                         print("rsync failed. Status: \(process.terminationStatus), Error: \(self.lastErrorMessage)")
                     }
                 }
            }

            // Run the actual process
            do {
                try self.process?.run()
            } catch {
                print("Failed to run actual rsync process: \(error)")
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.errorOccurred = true
                    self.lastErrorMessage = "Failed to launch rsync: \(error.localizedDescription)"
                    self.progressMessage = "Error: Cannot start backup process."
                }
                self.cleanupRunningProcess()
            }
        }
    }

    // Helper function to perform the dry run and parse the count
    private func performDryRun(source: String, target: String) -> Result<Int, BackupError> {
        let dryRunProcess = Process()
        dryRunProcess.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        dryRunProcess.arguments = [
            "-n", // Dry run
            "-a", // Archive mode (needed for accurate comparison)
            "--stats", // Get statistics including transfer counts
            // Add excludes
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
            try dryRunProcess.run()
            dryRunProcess.waitUntilExit() // Wait for the dry run to complete

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let outputString = String(data: outputData, encoding: .utf8) ?? ""
            let errorString = String(data: errorData, encoding: .utf8) ?? ""

            if dryRunProcess.terminationStatus == 0 {
                // Parse the output for "Number of files transferred:"
                if let range = outputString.range(of: "Number of files transferred: ") {
                    let numberString = outputString[range.upperBound...].prefix { $0.isNumber }
                    if let count = Int(numberString) {
                        print("Dry run complete. Files to transfer: \(count)")
                        return .success(count)
                    } else {
                        print("Dry run stats found, but couldn't parse number: \(outputString)")
                        // If stats are present but count is weird, assume 0 changes? Or treat as error?
                        // Let's assume 0 if parsing fails after finding the line.
                         return .success(0)
                    }
                } else if outputString.contains("Number of files:") {
                     // If "Number of files transferred" is missing, but stats are present, means 0 files were transferred.
                     print("Dry run complete. No files need transferring.")
                     return .success(0)
                 } else {
                     print("Dry run stats format unexpected or missing 'transferred' line: \(outputString)")
                     // If stats format is totally weird, treat as an error.
                     return .failure(.dryRunParseFailed)
                 }
            } else {
                print("Dry run failed. Status: \(dryRunProcess.terminationStatus), Error: \(errorString)")
                let message = errorString.isEmpty ? "Unknown (Code: \(dryRunProcess.terminationStatus))" : errorString
                return .failure(.dryRunFailed(message))
            }
        } catch {
            print("Failed to run dry run process: \(error)")
            return .failure(.dryRunLaunchFailed(error.localizedDescription))
        }
    }


    // Function to stop the backup if running
    func stopBackup() {
        guard isRunning, let process = process else { return }
        print("Attempting to stop rsync process...")

        // Set a flag or message immediately on the main thread
        DispatchQueue.main.async { [weak self] in
             guard let self = self else { return }
             if self.isRunning { // Check if it was actually running before termination logic potentially finishes
                 self.progressMessage = "Stopping backup..."
                 // Don't reset progress yet, let termination handler or cleanup handle it if needed
             }
        }

        process.terminate() // Sends SIGTERM
        // Give it a moment, then interrupt if necessary
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning {
                print("rsync did not terminate, sending SIGINT/interrupt.")
                process.interrupt() // Sends SIGINT
            }
            // The terminationHandler *should* be called eventually, setting isRunning=false
            // We might need an explicit state reset here if termination handler doesn't fire reliably after SIGINT
             DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in // Further delay
                 guard let self = self else { return }
                 if self.isRunning { // If *still* running after SIGINT attempt
                      print("Backup still running after interrupt attempt, forcing state reset.")
                      self.isRunning = false
                      self.progressMessage = "Backup Stopped (Forced)."
                      self.errorOccurred = true // Mark as error since it didn't stop cleanly
                      let stopError = BackupError.processTerminationFailed("") // Create error instance
                      self.lastErrorMessage = stopError.localizedDescription // Use its description
                      self.progressValue = 0.0 // Reset progress
                      self.cleanupRunningProcess() // Ensure pipes are closed
                 }
             }
        }
    }

    // Renamed from cleanupPipes to reflect it cleans the running process state
    private func cleanupRunningProcess() {
        outputPipe?.fileHandleForReading.closeFile()
        errorPipe?.fileHandleForReading.closeFile()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
        process = nil // Release the process object

        // Reset progress counters here? No, let the start/stop logic handle resetting.
        // totalFilesToTransfer = 0
        // filesProcessedCount = 0

        // Don't remove cancellables here unless they are specific to *one* run
         cancellables.removeAll() // Assuming cancellables are only for the current run monitoring
    }

    deinit {
        // Ensure process is terminated if BackupManager is deallocated mid-run
        if let process = process, process.isRunning {
             print("BackupManager deinit: Terminating running process.")
             process.terminate()
         }
        cleanupRunningProcess()
        print("BackupManager deinitialized")
    }
} 
