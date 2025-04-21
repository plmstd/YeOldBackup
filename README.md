# YeOldBackup 💾

## ⚠️ Use At Your Own Risk! ⚠️

**This application is provided "as is" without warranty of any kind, express or implied. It was developed *vibe coded* and may contain bugs or unexpected behavior. Data loss is possible if not used carefully. Always double-check your source and target selections before syncing, especially when deletions are involved. It is strongly recommended to have other backups of your important data.**

---

## Introduction

YeOldBackup is a simple macOS utility designed to provide a graphical user interface (GUI) for synchronizing directories using the powerful `rsync` command-line tool. It aims to make `rsync`-based backups more accessible by offering features like progress tracking, history management, persistent permissions, and a safety check for large deletions.

## Features

- **Graphical `rsync` Interface**: Select source and target directories easily.
- **Directory Synchronization**: Keeps the target directory an exact mirror of the source (including deleting files in the target that are not in the source).
- **Security-Scoped Bookmarks**: Remembers selected directories and permissions securely across app launches.
- **Dry Run Calculation**: Calculates changes _before_ performing the actual sync.
- **Deletion Confirmation**: Prompts the user for confirmation if a significant number of files are detected for deletion (based on count and percentage thresholds).
- **Real-time Progress**: Shows progress percentage, current file being transferred, and total file counts during the sync.
- **Backup History**: Keeps a list of previously used source/target pairs, allowing quick reloading. Includes status (Success, Error, Processing) and last successful sync time.
- **Detailed Reports**: Displays the output from `rsync` after completion or failure.
- **Full Disk Access Check**: Detects if necessary permissions are granted and guides the user to System Settings if needed.
- **Stop Functionality**: Allows cancelling an ongoing sync operation.

## How It Works

YeOldBackup acts as a wrapper around the system's `/usr/bin/rsync` command. Here's a breakdown of the process:

1.  **Permissions**: The app uses macOS security-scoped bookmarks. When you select a source or target directory, the app creates a bookmark, storing persistent permission to access that specific location. On subsequent launches, it resolves these bookmarks to regain access. It also requires Full Disk Access to function correctly, especially for accessing external drives or system-related folders.
2.  **Dry Run**: Before any files are actually copied or deleted, the app executes `rsync` with the `-n` (dry run), `--stats`, and `-i` (itemize changes) flags. It parses the output of this command to:
    - Determine if any synchronization is needed at all.
    - Count the number of files to be transferred (for progress calculation).
    - Count the number of files that would be deleted from the target.
    - Estimate the total number of files considered in the source.
3.  **Deletion Confirmation**: If the dry run indicates deletions exceeding a predefined threshold (e.g., more than 5 files _and_ more than 10% of the total source files), the app pauses and presents an alert asking the user to confirm the deletions. This is a safety measure against accidental data loss if the wrong target directory was selected.
4.  **Actual Sync**: If no confirmation is needed, or if the user confirms the deletions, the app executes `rsync` again, this time without the `-n` flag, but with `-a` (archive mode), `-v` (verbose), `-i` (itemize), `--delete` (to mirror the source), and some `--exclude` flags for common macOS metadata/temporary folders.
5.  **Progress Parsing**: During the actual sync, the app reads the `stdout` from `rsync` in real-time. It looks for lines indicating file transfers (like `>f+++++++++ filename`) to update the progress bar, file counts, and the name of the currently transferring file.
6.  **Output & Error Handling**: `stdout` and `stderr` from `rsync` are captured. `stderr` is monitored for errors, and the final exit code of the `rsync` process determines the overall success or failure. The captured output forms the basis of the sync report shown after the operation.
7.  **History**: Successful or failed backup attempts update a history list stored persistently using `@AppStorage`. Selecting an item from the history reloads the corresponding source/target bookmarks and paths.

## Getting Started & Usage

1.  **Download**: [Obtain the latest release of the `YeOldBackup.app` file.](https://github.com/plmstd/YeOldBackup/releases)
2.  **Installation**: Drag `YeOldBackup.app` to your Applications folder.
3.  **Full Disk Access**:
    - On the first launch (or if permissions are missing), the app will likely show a "Full Disk Access Required" warning.
    - Click the "Open Settings" button or manually go to `System Settings > Privacy & Security > Full Disk Access`.
    - Unlock the settings (usually requires administrator password).
    - Drag `YeOldBackup.app` from your Applications folder into the Full Disk Access list, or use the '+' button to add it.
    - Ensure the toggle next to YeOldBackup is **enabled**.
    - You may need to restart YeOldBackup for the changes to take effect.
4.  **Select Source**: Click the "Select..." button next to "Source" and choose the folder/drive you want to back up _from_.
5.  **Select Target**: Click the "Select..." button next to "Target" and choose the folder/drive you want to back up _to_. **Be careful!** Files in the target that are not in the source _will be deleted_ to make the target an exact mirror.
6.  **Start Sync**: Once both source and target are selected and Full Disk Access is granted, click the "Sync Now" button.
7.  **Monitor Progress**: Observe the progress bar, percentage, status message, and current file name.
8.  **Deletion Confirmation (If Prompted)**: If the app detects significant deletions, an alert will appear. **Read it carefully!** Double-check that the source and target paths shown in the alert are correct. Choose "Proceed with Deletions" only if you are certain. Choose "Cancel" to abort the backup.
9.  **Completion/Report**: Once the sync finishes (or is stopped/cancelled/errors out), a report section will appear showing details from the `rsync` operation. You can dismiss this report.
10. **Stopping**: If you need to stop a running sync, click the "Stop Sync" button. The app will send signals (`SIGTERM`, then `SIGINT` if needed) to the `rsync` process.
11. **Using History**: Previous backup pairs appear in the "Backups" table. Clicking a row loads that source/target pair. You can right-click (or control-click) an entry to remove it from the list.

**OR**

Just clone the repo, open it in Xcode, and use it however you want.

## Important Considerations

- **`rsync` Behavior**: This app relies entirely on the behavior of `rsync --delete`. Understand how `rsync` mirroring works before using this tool extensively.
- **Permissions**: Full Disk Access is crucial. Without it, `rsync` will fail when encountering files it cannot read or write.
- **External Drives**: Ensure external drives are mounted and accessible _before_ starting the app or selecting them. Bookmark resolution might fail if a drive is unavailable.
- **Network Drives**: Performance and reliability with network drives may vary and depend heavily on the network connection and `rsync`'s handling of the specific network filesystem. Use with caution.
- **Error Handling**: While the app tries to catch errors from `rsync`, complex scenarios might lead to unclear error messages. The sync report often contains the most detailed information from `rsync` itself.
- **Large Backups**: Very large backups might take a long time. The app should remain responsive, but the system resources used by `rsync` can be significant.

## Disclaimer

**Use this software entirely at your own risk.** The author provides no warranty and assumes no liability for any data loss or damage that may occur as a result of using this application. Always have multiple backups of critical data.
