//
//  BlocktankNotificationType.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/16.
//

import Foundation

enum BlocktankNotificationType: String {
    case incomingHtlc
    case mutualClose
    case orderPaymentConfirmed
    case cjitPaymentArrived
    case wakeToTimeout

    var feature: String {
        return "blocktank.\(self.rawValue)"
    }
}
