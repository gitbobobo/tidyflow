import SwiftUI

struct LeftSidebarView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        List(selection: $appState.selectedWorkspaceKey) {
            Section(header: Text("Workspaces")) {
                ForEach(appState.workspaces.sorted(by: { $0.key < $1.key }), id: \.key) { key, name in
                    Text(name)
                        .tag(key)
                }
            }
            
            Section(header: Text("Projects")) {
                Text("Project X (Mock)")
                Text("Project Y (Mock)")
            }
        }
        .listStyle(SidebarListStyle())
        .frame(minWidth: 200)
    }
}
