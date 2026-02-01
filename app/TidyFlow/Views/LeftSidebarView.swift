import SwiftUI

// DEPRECATED: This view is no longer used.
// The sidebar now uses ProjectsSidebarView for the project tree.
// This file can be safely deleted.

struct LeftSidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Text("Deprecated - use ProjectsSidebarView")
            .foregroundColor(.secondary)
    }
}
