import SwiftUI

struct Social: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack {
            IconButton(icon: Image("globe")) {
                openURL(URL(string: "https://www.bitkit.to")!)
            }
            Spacer()
            IconButton(icon: Image("medium")) {
                openURL(URL(string: "https://www.medium.com/synonym-to")!)
            }
            Spacer()
            IconButton(icon: Image("twitter")) {
                openURL(URL(string: "https://www.twitter.com/bitkitwallet")!)
            }
            Spacer()
            IconButton(icon: Image("discord")) {
                openURL(URL(string: "https://discord.gg/DxTBJXvJxn")!)
            }
            Spacer()
            IconButton(icon: Image("telegram")) {
                openURL(URL(string: "https://t.me/bitkitchat")!)
            }
            Spacer()
            IconButton(icon: Image("github")) {
                openURL(URL(string: "https://www.github.com/synonymdev")!)
            }
        }
    }
}
