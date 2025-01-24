import SwiftUI

struct StyleGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                textStylesSection
                Divider()
                colorSection
                Divider()
                buttonSection
                Divider()
                buttonPairsSection
            }
            .padding()
        }
    }
    
    private var textStylesSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Group {
                DisplayText("Display Style With An <accent>Accent</accent> Over Here")
                
                HeadlineText("Headline Style With An <accent>Accent</accent> Over Here", accentColor: .blueAccent)
                
                TitleText("Title Style With An <accent>Accent</accent> Over Here", accentColor: .greenAccent)
                
                SubtitleText("Subtitle style with an <accent>accent</accent> over here", accentColor: .purpleAccent)
            
                BodyMText("Body m style with an <accent>accent</accent> over here", accentColor: .brandAccent)
                
                BodyMBoldText("Body m bold style with an <accent>accent</accent> over here", accentColor: .yellowAccent)
                
                BodySText("Body s style with an <accent>accent</accent> over here", accentColor: .redAccent)
                
                CaptionText("Caption style with an <accent>accent</accent> over here", accentColor: .blueAccent)
              
                FootnoteText("Footnote style with an <accent>accent</accent> over here", accentColor: .brandAccent)
            }
            .foregroundStyle(Color.textPrimary)
        }
    }
    
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 24) {
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
            SubtitleText(title)
            
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
            
            BodyMText(name)
        }
    }
    
    private var buttonSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                // Primary Buttons
                SubtitleText("Primary")
                    .padding(.top, 8)
                
                CustomButton(title: "Default") {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                
                CustomButton(
                    title: "With Icon",
                    icon: Image(systemName: "lock.shield").foregroundColor(.textPrimary)
                ) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                
                CustomButton(title: "Large", size: .large) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                
                CustomButton(title: "Disabled", isDisabled: true) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                
                CustomButton(title: "Loading") {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                
                // Secondary Buttons
                SubtitleText("Secondary")
                    .padding(.top, 24)
                
                CustomButton(title: "Default", variant: .secondary) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                
                CustomButton(
                    title: "With Icon",
                    variant: .secondary,
                    icon: Image(systemName: "lock.shield").foregroundColor(.white64)
                ) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                
                CustomButton(title: "Large", variant: .secondary, size: .large) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                
                CustomButton(title: "Disabled", variant: .secondary, isDisabled: true) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                
                CustomButton(title: "Loading", variant: .secondary) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                
                // Tertiary Buttons
                SubtitleText("Tertiary")
                    .padding(.top, 24)
                
                CustomButton(title: "Default", variant: .tertiary) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                
                CustomButton(
                    title: "With Icon",
                    variant: .tertiary,
                    icon: Image(systemName: "lock.shield").foregroundColor(.white64)
                ) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                
                CustomButton(title: "Large", variant: .tertiary, size: .large) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                
                CustomButton(title: "Disabled", variant: .tertiary, isDisabled: true) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
                
                CustomButton(title: "Loading", variant: .tertiary) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }
    
    private var buttonPairsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 16) {
                HStack {
                    CustomButton(title: "Accept") {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                    }
                    
                    CustomButton(title: "Decline", variant: .secondary) {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                    }
                }
                
                HStack {
                    CustomButton(title: "Save") {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                    }
                    
                    CustomButton(title: "Cancel", variant: .tertiary) {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                    }
                }
                
                HStack {
                    CustomButton(
                        title: "Confirm",
                        icon: Image(systemName: "checkmark")
                            .foregroundColor(.textPrimary)
                    ) {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                    }
                    
                    CustomButton(
                        title: "Delete",
                        variant: .secondary,
                        icon: Image(systemName: "trash")
                            .foregroundColor(.white64)
                    ) {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                    }
                }
            }
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
