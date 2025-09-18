import Network
import SwiftUI

@MainActor
final class NetworkMonitor: ObservableObject {
    // This will be used to track the network connectivity
    @Published
    var isConnected = true

    // This will be used to track if the network is expensive (e.g. cellular data)
    @Published
    var isExpensive = false

    @Published
    var networkType: NWInterface.InterfaceType? = .other

    // This will be used to track the network path (e.g. Wi-Fi, cellular data, etc.)
    @Published
    var nwPath: NWPath?

    // Create an instance of NWPathMonitor
    let monitor = NWPathMonitor()

    init() {
        // Set the pathUpdateHandler
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                // Check if the device is connected to the internet
                self?.isConnected = path.status == .satisfied

                // Check if the network is expensive (e.g. cellular data)
                self?.isExpensive = path.isExpensive

                // Check which interface we are currently using
                self?.networkType = path.availableInterfaces.first?.type

                // Update the network path
                self?.nwPath = path
            }
        }

        // Create a queue for the monitor
        let queue = DispatchQueue(label: "Monitor")

        // Start monitoring
        monitor.start(queue: queue)
    }

    deinit {
        // Stop monitoring
        monitor.cancel()
    }
}
