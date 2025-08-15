import SwiftUI

struct ContentView: View {
    @StateObject private var session = SessionManager()

    var body: some View {
        AppScene()
            .id(session.id)
            .environmentObject(session)
    }
}
