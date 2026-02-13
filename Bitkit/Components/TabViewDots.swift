import SwiftUI

struct TabViewDots: View {
    let numberOfTabs: Int
    var currentTab: Int

    var body: some View {
        VStack {
            Spacer()

            HStack(spacing: 8) {
                ForEach(Array(0 ..< numberOfTabs), id: \.self) { index in
                    Circle()
                        .fill(currentTab == index ? Color.textPrimary : Color.white32)
                        .frame(width: 8, height: 8)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: currentTab)
        }
        .zIndex(.infinity)
    }
}
