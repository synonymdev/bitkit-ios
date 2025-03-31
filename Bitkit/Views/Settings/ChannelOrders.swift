import SwiftUI

struct CopyableText: View {
    let text: String
    @State private var isPressed = false

    var body: some View {
        Text(text)
            .font(.system(size: text.count > 20 ? 10 : 12, design: .monospaced))
            .lineLimit(1)
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
            .onTapGesture {
                UIPasteboard.general.string = text
                Haptics.play(.copiedToClipboard)
                withAnimation {
                    isPressed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isPressed = false
                    }
                }
            }
    }
}

struct OrderRow: View {
    let order: IBtOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(order.id)
                    .font(.system(size: order.id.count > 20 ? 10 : 12, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text(String(describing: order.state2))
                    .font(.caption)
                    .padding(4)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            }

            HStack {
                VStack(alignment: .leading) {
                    Text("LSP Balance")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("\(order.lspBalanceSat) sats")
                        .font(.subheadline)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Client Balance")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("\(order.clientBalanceSat) sats")
                        .font(.subheadline)
                }
            }

            HStack {
                VStack(alignment: .leading) {
                    Text("Fees")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("\(order.feeSat) sats")
                        .font(.subheadline)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Expires")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text(order.channelExpiresAt.prefix(10))
                        .font(.subheadline)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct CJitRow: View {
    let entry: IcJitEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.id)
                    .font(.system(size: entry.id.count > 20 ? 10 : 12, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text(String(describing: entry.state))
                    .font(.caption)
                    .padding(4)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            }

            HStack {
                VStack(alignment: .leading) {
                    Text("Channel Size")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("\(entry.channelSizeSat) sats")
                        .font(.subheadline)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Fees")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("\(entry.feeSat) sats")
                        .font(.subheadline)
                }
            }

            if let error = entry.channelOpenError {
                Text(error)
                    .font(.system(size: error.count > 50 ? 10 : 12))
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            HStack {
                Text("Expires: \(entry.expiresAt.prefix(10))")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var isError: Bool = false
    @State private var isPressed = false

    private var fontSize: CGFloat {
        if value.count > 40 {
            return 11
        } else if value.count > 30 {
            return 12
        }
        return 14
    }

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(size: fontSize))
                .foregroundColor(isError ? .red : .primary)
                .multilineTextAlignment(.trailing)
                .scaleEffect(isPressed ? 0.95 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPressed)
                .onTapGesture {
                    UIPasteboard.general.string = value
                    Haptics.play(.copiedToClipboard)
                    withAnimation {
                        isPressed = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isPressed = false
                        }
                    }
                }
        }
    }
}

struct OrderDetailView: View {
    let order: IBtOrder

    var body: some View {
        List {
            Section("Order Details") {
                DetailRow(label: "ID", value: order.id)
                DetailRow(label: "Onchain txs", value: "\(order.payment.onchain.transactions.count)")
                DetailRow(label: "State", value: String(describing: order.state))
                DetailRow(label: "State 2", value: String(describing: order.state2))
                DetailRow(label: "LSP Balance", value: "\(order.lspBalanceSat) sats")
                DetailRow(label: "Client Balance", value: "\(order.clientBalanceSat) sats")
                DetailRow(label: "Total Fee", value: "\(order.feeSat) sats")
                DetailRow(label: "Network Fee", value: "\(order.networkFeeSat) sats")
                DetailRow(label: "Service Fee", value: "\(order.serviceFeeSat) sats")
            }

            Section("Channel Settings") {
                DetailRow(label: "Zero Conf", value: order.zeroConf ? "Yes" : "No")
                DetailRow(label: "Zero Reserve", value: order.zeroReserve ? "Yes" : "No")
                if let clientNodeId = order.clientNodeId {
                    DetailRow(label: "Client Node ID", value: clientNodeId)
                }
                DetailRow(label: "Expiry Weeks", value: "\(order.channelExpiryWeeks)")
                DetailRow(label: "Channel Expires", value: order.channelExpiresAt)
                DetailRow(label: "Order Expires", value: order.orderExpiresAt)
            }

            Section("LSP Information") {
                DetailRow(label: "Alias", value: order.lspNode.alias)
                DetailRow(label: "Node ID", value: order.lspNode.pubkey)
                if let lnurl = order.lnurl {
                    DetailRow(label: "LNURL", value: lnurl)
                }
            }

            if let couponCode = order.couponCode {
                Section("Discount") {
                    DetailRow(label: "Coupon Code", value: couponCode)
                    if let discount = order.discount {
                        DetailRow(label: "Discount Type", value: String(describing: discount.code))
                        DetailRow(label: "Value", value: "\(discount.absoluteSat)")
                    }
                }
            }

            Section("Timestamps") {
                DetailRow(label: "Created", value: order.createdAt)
                DetailRow(label: "Updated", value: order.updatedAt)
            }

            if order.state2 == .paid {
                Button("Open Channel") {
                    Task {
                        Logger.info("Opening channel for order \(order.id)")

                        do {
                            try await CoreService.shared.blocktank.open(orderId: order.id)
                            Logger.info("Channel opened for order \(order.id)")
                        } catch {
                            Logger.error("Error opening channel for order \(order.id): \(error)")
                            LightningService.shared.dumpLdkLogs()
                        }
                    }
                }
            }
        }
        .navigationTitle("Order Details")
    }
}

struct CJitDetailView: View {
    let entry: IcJitEntry

    var body: some View {
        List {
            Section("Entry Details") {
                DetailRow(label: "ID", value: entry.id)
                DetailRow(label: "State", value: String(describing: entry.state))
                DetailRow(label: "Channel Size", value: "\(entry.channelSizeSat) sats")
                if let error = entry.channelOpenError {
                    DetailRow(label: "Error", value: error, isError: true)
                }
            }

            Section("Fees") {
                DetailRow(label: "Total Fee", value: "\(entry.feeSat) sats")
                DetailRow(label: "Network Fee", value: "\(entry.networkFeeSat) sats")
                DetailRow(label: "Service Fee", value: "\(entry.serviceFeeSat) sats")
            }

            Section("Channel Settings") {
                DetailRow(label: "Node ID", value: entry.nodeId)
                DetailRow(label: "Expiry Weeks", value: "\(entry.channelExpiryWeeks)")
            }

            Section("LSP Information") {
                DetailRow(label: "Alias", value: entry.lspNode.alias)
                DetailRow(label: "Node ID", value: entry.lspNode.pubkey)
            }

            if !entry.couponCode.isEmpty {
                Section("Discount") {
                    DetailRow(label: "Coupon Code", value: entry.couponCode)
                    if let discount = entry.discount {
                        DetailRow(label: "Discount Type", value: String(describing: discount.code))
                        DetailRow(label: "Value", value: "\(discount.absoluteSat)")
                    }
                }
            }

            Section("Timestamps") {
                DetailRow(label: "Created", value: entry.createdAt)
                DetailRow(label: "Updated", value: entry.updatedAt)
                DetailRow(label: "Expires", value: entry.expiresAt)
            }
        }
        .navigationTitle("cJIT Entry Details")
    }
}

struct ChannelOrders: View {
    @EnvironmentObject var blocktank: BlocktankViewModel
    @State private var isRefreshing = false

    var body: some View {
        List {
            Section("Orders") {
                if let orders = blocktank.orders {
                    if orders.isEmpty {
                        Text("No orders found")
                            .foregroundColor(.gray)
                    } else {
                        ForEach(orders, id: \.id) { order in
                            NavigationLink(destination: OrderDetailView(order: order)) {
                                OrderRow(order: order)
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }

            Section("cJIT Entries") {
                if let entries = blocktank.cJitEntries {
                    if entries.isEmpty {
                        Text("No cJIT entries found")
                            .foregroundColor(.gray)
                    } else {
                        ForEach(entries, id: \.id) { entry in
                            NavigationLink(destination: CJitDetailView(entry: entry)) {
                                CJitRow(entry: entry)
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle("Channel Orders")
        .refreshable {
            do {
                try await blocktank.refreshOrders()
            } catch {
                print("Error refreshing orders: \(error)")
            }
        }
        .task {
            try? await blocktank.refreshOrders()
        }
    }
}

#Preview {
    ChannelOrders()
        .environmentObject(BlocktankViewModel())
        .preferredColorScheme(.dark)
}
