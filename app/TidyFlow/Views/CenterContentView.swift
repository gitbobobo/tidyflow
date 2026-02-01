import SwiftUI

struct CenterContentView: View {
    @EnvironmentObject var appState: AppState
    let webBridge: WebBridge
    
    var body: some View {
        ZStack {
            WebViewContainer(bridge: webBridge)
            
            VStack {
                Spacer()
                if let selected = appState.selectedWorkspaceKey {
                    Text("Selected workspace: \(selected)")
                        .padding()
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .padding(.bottom, 20)
                }
            }
        }
    }
}
