import SwiftUI

struct Social: View {
    @Environment(\.openURL) private var openURL

    let backgroundColor: Color

    init(backgroundColor: Color = .white16) {
        self.backgroundColor = backgroundColor
    }

    var body: some View {
        HStack {
            IconButton(icon: Image("globe"), backgroundColor: backgroundColor) {
                openURL(URL(string: "https://www.bitkit.to")!)
            }
            Spacer()
            IconButton(icon: Image("medium"), backgroundColor: backgroundColor) {
                openURL(URL(string: "https://www.medium.com/synonym-to")!)
            }
            Spacer()
            IconButton(icon: Image("twitter"), backgroundColor: backgroundColor) {
                openURL(URL(string: "https://www.twitter.com/bitkitwallet")!)
            }
            Spacer()
            IconButton(icon: Image("discord"), backgroundColor: backgroundColor) {
                openURL(URL(string: "https://discord.gg/DxTBJXvJxn")!)
            }
            Spacer()
            IconButton(icon: Image("telegram"), backgroundColor: backgroundColor) {
                openURL(URL(string: "https://t.me/bitkitchat")!)
            }
            Spacer()
            IconButton(icon: Image("github"), backgroundColor: backgroundColor) {
                openURL(URL(string: "https://www.github.com/synonymdev")!)
            }
        }
    }
}
