import SwiftUI

struct StyleGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                textStylesSection
                colorSection
            }
            .padding()
        }
    }
    
    private var textStylesSection: some View {
        VStack(alignment: .leading, spacing: 24) {  
            Group {
                (Text("Display Style With An ") + Text("Accent").foregroundColor(.brandAccent) + Text(" Over Here"))
                    .displayTextStyle()
                
                (Text("Headline Style With An ") + Text("Accent").foregroundColor(.blueAccent) + Text(" Over Here"))
                    .headlineTextStyle()
                
                (Text("Title Style With An ") + Text("Accent").foregroundColor(.greenAccent) + Text(" Over Here"))
                    .titleTextStyle()
                
                (Text("Subtitle style with an ") + Text("accent").foregroundColor(.purpleAccent) + Text(" over here"))
                    .subtitleTextStyle()
                
                (Text("Body m style with an ") + Text("accent").foregroundColor(.brandAccent) + Text(" over here"))
                    .bodyMTextStyle()
                
                (Text("Body m bold style with an ") + Text("accent").foregroundColor(.yellowAccent) + Text(" over here"))
                    .bodyMBoldTextStyle()
                
                (Text("Body s style with an ") + Text("accent").foregroundColor(.redAccent) + Text(" over here"))
                    .bodySTextStyle()
                
                (Text("Caption style with an ") + Text("accent").foregroundColor(.blueAccent) + Text(" over here"))
                    .captionTextStyle()
                
                (Text("Footnote style with an ") + Text("accent").foregroundColor(.brandAccent) + Text(" over here"))
                    .footnoteTextStyle()
            }
            .foregroundStyle(Color.textPrimary)
        }
    }
    
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Colors")
                .displayTextStyle()
            
            Group {
                colorGroup(title: "Accent Colors", colors: [
                    ("Brand Accent", Color.brandAccent),
                    ("Blue Accent", Color.blueAccent),
                    ("Green Accent", Color.greenAccent),
                    ("Purple Accent", Color.purpleAccent),
                    ("Red Accent", Color.redAccent),
                    ("Yellow Accent", Color.yellowAccent)
                ])
                
                colorGroup(title: "Text Colors", colors: [
                    ("Text Primary", Color.textPrimary),
                    ("Text Secondary", Color.textSecondary)
                ])
                
                colorGroup(title: "Gray Scale", colors: [
                    ("Gray 6", Color.gray6),
                    ("Gray 5", Color.gray5),
                    ("Gray 3", Color.gray3),
                    ("Gray 2", Color.gray2)
                ])
            }
        }
    }
    
    private func colorGroup(title: String, colors: [(String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .subtitleTextStyle()
            
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16)
            ], spacing: 16) {
                ForEach(colors, id: \.0) { name, color in
                    colorCard(name: name, color: color)
                }
            }
        }
    }
    
    private func colorCard(name: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12)
                .fill(color)
                .frame(height: 60)
            
            Text(name)
                .bodySTextStyle()
        }
    }
}

#Preview("Dark Mode") {
    StyleGuideView()
        .preferredColorScheme(.dark)
}

#Preview("Light Mode") {
    StyleGuideView()
        .preferredColorScheme(.light)
}
