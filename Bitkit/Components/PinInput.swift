//
//  PinInputView.swift
//  Bitkit
//
//  Created by Assistant on 2024/12/19.
//

import SwiftUI

struct PinInput: View {
    @Binding var pinInput: String
    let onPinChange: (String) -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 32) {
            // PIN circles
            HStack(alignment: .top, spacing: 24) {
                ForEach(0 ..< 4, id: \.self) { index in
                    Circle()
                        .fill(index < pinInput.count ? Color.brandAccent : Color.brandAccent.opacity(0.08))
                        .overlay(
                            Circle()
                                .stroke(Color.brandAccent, lineWidth: 1)
                        )
                        .frame(width: 20, height: 20)
                }
            }
            .padding(0)
            .onTapGesture {
                isTextFieldFocused = true
            }

            // Hidden TextField to capture keyboard input
            TextField("", text: $pinInput)
                .keyboardType(.numberPad)
                .focused($isTextFieldFocused)
                .opacity(0)
                .frame(width: 0, height: 0)
                .onChange(of: pinInput) { newValue in
                    // Limit to 4 digits and only allow numbers
                    let filtered = String(newValue.prefix(4).filter { $0.isNumber })
                    if filtered != newValue {
                        pinInput = filtered
                    }

                    // Call the callback whenever PIN changes
                    onPinChange(pinInput)
                }
        }
        .onAppear {
            isTextFieldFocused = true
        }
        .onChange(of: isTextFieldFocused) { newValue in
            if !newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    isTextFieldFocused = true
                }
            }
        }
    }
}

#Preview {
    @State var pinInput = ""

    return VStack {
        PinInput(pinInput: $pinInput) { pin in
            print("PIN changed: \(pin)")
        }

        Text("Current PIN: \(pinInput)")
            .padding()
    }
    .preferredColorScheme(.dark)
}
