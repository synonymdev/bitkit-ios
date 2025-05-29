//
//  SettingsViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/12/19.
//

import SwiftUI

@MainActor
class SettingsViewModel: ObservableObject {
    // Security & Privacy Settings
    @AppStorage("swipeBalanceToHide") var swipeBalanceToHide: Bool = true
    @AppStorage("hideBalanceOnOpen") var hideBalanceOnOpen: Bool = false
    @AppStorage("readClipboard") var readClipboard: Bool = false
    @AppStorage("warnWhenSendingOver100") var warnWhenSendingOver100: Bool = false
    @AppStorage("showRecentlyPaidContacts") var showRecentlyPaidContacts: Bool = true
    @AppStorage("requirePinOnLaunch") var requirePinOnLaunch: Bool = false
    @AppStorage("requirePinWhenIdle") var requirePinWhenIdle: Bool = true
    @AppStorage("requirePinForPayments") var requirePinForPayments: Bool = false
    @AppStorage("useFaceIDInstead") var useFaceIDInstead: Bool = false

    // PIN Management
    @AppStorage("hasPinEnabled") var hasPinEnabled: Bool = false

    // Widget Settings
    @AppStorage("showWidgets") var showWidgets: Bool = true
    @AppStorage("showWidgetTitles") var showWidgetTitles: Bool = false

    init() {}
}
