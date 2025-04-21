import Foundation
import Combine

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

    func runBackup(source: String, target: String) {
        guard !isRunning else {
            print("Backup already in progress.")
            return
        }

        // Ensure source path ends with a slash for rsync correct behavior
        let rsyncSource = source.hasSuffix("/") ? source : source + "/"
        let rsyncTarget = target // Target should not end with slash usually

        print("Starting rsync: /usr/bin/rsync -a --delete --progress \(rsyncSource) \(rsyncTarget)")

        // Reset state
        DispatchQueue.main.async {
            self.isRunning = true
            self.progressMessage = "Starting backup..."
            self.errorOccurred = false
            self.lastErrorMessage = ""
            self.progressValue = 0.0
        }

        process = Process()
        process?.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        // Key arguments:
        // -a: Archive mode (recursive, preserves permissions, times, symlinks, etc.)
        // --delete: Deletes files on the target that don't exist on the source
        // --progress: Shows progress during transfer (we'll try to parse this)
        // --exclude: Skip specific system/temporary files/folders
        // NOTE: macOS default rsync (2.6.9) does NOT support --info=progress2.
        process?.arguments = [
            "-a",
            "--delete",
            "--progress",
            "--exclude", ".Spotlight-V100/", // Spotlight index
            "--exclude", ".fseventsd/",      // File system event logs
            "--exclude", ".Trashes",         // User trash folders (can be tricky)
            "--exclude", ".TemporaryItems/", // System temporary items
            "--exclude", ".DS_Store",        // Finder metadata files
            rsyncSource,
            rsyncTarget
        ]

        outputPipe = Pipe()
        errorPipe = Pipe()

        process?.standardOutput = outputPipe
        process?.standardError = errorPipe

        // Capture stdout
        outputPipe?.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                // EOF
                DispatchQueue.main.async {
                    if !(self?.errorOccurred ?? true) && (self?.isRunning ?? false) {
                        // self?.progressValue = 1.0 // Set to 100% - Let termination handler do this.
                    }
                }
                self?.outputPipe?.fileHandleForReading.readabilityHandler = nil
            } else if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                // Parse --progress output
                // Example line: "      1,234,567  85%   95.50MB/s    0:00:10 (xfr#5, to-chk=15/50)"
                // Or just filename on one line, progress on the next.
                // We look for lines containing "%"
                let lines = output.split(whereSeparator: { $0.isNewline || $0 == "\r" }) // Split by newline or carriage return
                var lastParsedPercentage: Double? = nil

                for line in lines {
                    let lineStr = String(line).trimmingCharacters(in: .whitespaces)
                    // Simple check for percentage sign
                    if lineStr.contains("%") {
                        // Extract the percentage value, typically after file size
                        let components = lineStr.split(separator: " ", omittingEmptySubsequences: true)
                        // Find the component that ends with %
                        if let percentageComponent = components.first(where: { $0.contains("%") }) {
                            let percentageString = String(percentageComponent).replacingOccurrences(of: "%", with: "")
                            if let percentage = Double(percentageString) {
                                // Store the last found percentage in this chunk
                                lastParsedPercentage = max(0.0, min(1.0, percentage / 100.0))
                            }
                        }
                    }
                }

                // Update the UI with the last percentage found in this data chunk
                if let finalPercentage = lastParsedPercentage {
                    DispatchQueue.main.async {
                        self?.progressValue = finalPercentage
                        // Update status message to reflect the percentage being processed
                        self?.progressMessage = "Syncing (\(Int(finalPercentage * 100))%)..."
                        // print("Parsed (--progress) Progress: \(self?.progressValue ?? -1)") // Debug print
                    }
                } else {
                    // If no percentage in this chunk, maybe it's just a filename?
                    // Update the status message with the last non-empty line
                    if let lastStatusLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        DispatchQueue.main.async {
                            if !(self?.progressMessage.contains("Syncing") ?? false) { // Avoid overwriting percentage status
                                self?.progressMessage = "Processing: \(String(lastStatusLine).trimmingCharacters(in: .whitespaces))"
                            }
                        }
                    }
                }
            }
        }

        // Capture stderr
        errorPipe?.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                // EOF
                self?.errorPipe?.fileHandleForReading.readabilityHandler = nil
            } else if let errorOutput = String(data: data, encoding: .utf8), !errorOutput.isEmpty {
                DispatchQueue.main.async {
                    print("rsync stderr: \(errorOutput)")
                    self?.errorOccurred = true
                    // Append to error message, handling potential multiple chunks
                    self?.lastErrorMessage += errorOutput
                    // Show the latest error chunk in the main progress message too
                    self?.progressMessage = "Error: \(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
            }
        }

        // Monitor termination
        process?.terminationHandler = { [weak self] process in
            self?.cleanupPipes()
            DispatchQueue.main.async {
                self?.isRunning = false
                if process.terminationStatus == 0 && !(self?.errorOccurred ?? false) {
                    self?.progressMessage = "Backup Complete."
                    self?.progressValue = 1.0
                    print("rsync finished successfully.")
                } else {
                    self?.errorOccurred = true
                    if self?.lastErrorMessage.isEmpty ?? true {
                         self?.lastErrorMessage = "rsync failed with exit code \(process.terminationStatus)."
                    }
                    self?.progressMessage = "Backup Failed. Check logs." // Update final status
                    print("rsync failed. Status: \(process.terminationStatus), Error: \(self?.lastErrorMessage ?? "Unknown")")
                }
                // Reset progress if stopped manually
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if self.isRunning {
                        self.progressMessage = "Backup Stopped."
                        self.progressValue = 0.0
                    }
                }
            }
        }

        // Run the process
        do {
            try process?.run()
        } catch {
            print("Failed to run rsync process: \(error)")
            DispatchQueue.main.async {
                self.isRunning = false
                self.errorOccurred = true
                self.lastErrorMessage = "Failed to launch rsync: \(error.localizedDescription)"
                self.progressMessage = "Error: Cannot start backup process."
                self.cleanupPipes()
            }
        }
    }

    // Function to stop the backup if running
    func stopBackup() {
        guard isRunning, let process = process else { return }
        print("Attempting to stop rsync process...")
        process.terminate() // Sends SIGTERM, rsync should handle this reasonably gracefully
        // Give it a moment, then force quit if necessary (though usually not needed for rsync)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    if process.isRunning {
                        print("rsync did not terminate, sending SIGINT/interrupt.")
                        process.interrupt() // Sends SIGINT first (safer)
                        // Consider sending SIGKILL if interrupt fails after another delay, though interrupt usually suffices.
                        // process.forceTerminate() // Sends SIGKILL - Use with caution
                    }
                }
        // Termination handler will eventually set isRunning = false
    }

    private func cleanupPipes() {
        outputPipe?.fileHandleForReading.closeFile()
        errorPipe?.fileHandleForReading.closeFile()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
        process = nil // Release the process object
        cancellables.removeAll()
    }

    deinit {
        stopBackup() // Ensure process is terminated if BackupManager is deallocated
        cleanupPipes()
        print("BackupManager deinitialized")
    }
} 
