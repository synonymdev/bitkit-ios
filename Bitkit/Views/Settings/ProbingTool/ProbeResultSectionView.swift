import SwiftUI

struct ProbeResultSectionView: View {
    let result: ProbeResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CaptionMText("Probe Results")

            HStack {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.success ? Color.green : Color.red)
                Text("Status")
                Spacer()
                Text(result.success ? "Success" : "Failed")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            HStack {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                Text("Duration")
                Spacer()
                Text("\(result.durationMs) ms")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            if let fee = result.estimatedFeeSats {
                HStack {
                    Image(systemName: "bitcoinsign.circle")
                        .foregroundStyle(.secondary)
                    Text("Estimated Fee")
                    Spacer()
                    Text("\(fee) sats")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }

            if let error = result.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }
}
