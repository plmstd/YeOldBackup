//
//  YeOldBackup
//
//  Created by palmstudio GmbH
//

import SwiftUI

// AppDelegate to handle application lifecycle events like termination
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Find the ContentView instance and call stopAccessingAllURLs
        // This assumes the main window's content view is our ContentView.
        // A more robust solution might involve passing the ContentView's state or a dedicated object.
        if let window = NSApplication.shared.windows.first,
           let contentView = window.contentView as? NSHostingView<ContentView> {
            contentView.rootView.stopAccessingAllURLs()
            print("AppDelegate: Called stopAccessingAllURLs on termination.")
        } else {
            print("AppDelegate: Could not find ContentView to stop URL access on termination.")
        }
    }
}

@main
struct YeOldBackupApp: App {
    // Connect the AppDelegate
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
} 
