//
//  Scanner.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/10.
//

import Foundation

enum ScannedOptions {
    case onchain(address: String, amount: Double?, label: String?, message: String?)
    case bolt11(invoice: String)
    // TODO: lightning address, treasure hunt, auth, etc
}

enum ScannedError: Error {
    case invalidData
    case noOptions
}

extension ScannedError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Invalid data"
        case .noOptions:
            return "No options found in scanned data"
        }
    }
}

struct BIP21Data {
    let address: String
    let amount: Double?
    let label: String?
    let message: String?
    let lightningInvoice: String?
    let other: [String: String]
}

struct ScannedData {
    let options: [ScannedOptions]

    init(_ uri: String) throws {
        Logger.debug("Scanned data: \(uri)")
        
        guard !uri.isEmpty else {
            throw ScannedError.invalidData
        }

        var options: [ScannedOptions] = []

        if ["lightning:", "lntb", "lnbc"].contains(where: { uri.hasPrefix($0) }) {
            // MARK: just simple bolt11 invoice
            let invoice = uri.replacingOccurrences(of: "lightning:", with: "")
            options.append(.bolt11(invoice: invoice))
        } else if let bip21Data = Self.decodeBIP21(uri: uri) {
            // MARK: has BIP21 params
            if bip21Data.lightningInvoice != nil {
                options.append(.bolt11(invoice: bip21Data.lightningInvoice!))
            } else {
                options.append(.onchain(address: bip21Data.address, amount: bip21Data.amount, label: bip21Data.label, message: bip21Data.message))
            }
        }

        guard !options.isEmpty else {
            throw ScannedError.noOptions
        }

        self.options = options
    }

    private static func decodeBIP21(uri: String) -> BIP21Data? {
        guard let components = URLComponents(string: uri), components.scheme?.lowercased() == "bitcoin" else {
            return nil
        }

        let address = components.path

        var amount: Double?
        var label: String?
        var message: String?
        var lightningInvoice: String?
        var other: [String: String] = [:]

        for item in components.queryItems ?? [] {
            guard let value = item.value else { continue }

            switch item.name.lowercased() {
            case "amount":
                amount = Double(value)
            case "label":
                label = value
            case "message":
                message = value
            case "lightning":
                lightningInvoice = value
            default:
                other[item.name] = value
            }
        }

        return BIP21Data(address: address, amount: amount, label: label, message: message, lightningInvoice: lightningInvoice, other: other)
    }
}
