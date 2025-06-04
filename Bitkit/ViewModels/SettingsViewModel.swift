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
    @AppStorage("swipeBalanceToHide") private var _swipeBalanceToHide: Bool = true

    var swipeBalanceToHide: Bool {
        get { _swipeBalanceToHide }
        set {
            _swipeBalanceToHide = newValue
            if !newValue {
                // If they disable the swipe to hide, we should keep the balance visible else they'll never see it
                hideBalance = false
            }
        }
    }

    @AppStorage("hideBalance") var hideBalance: Bool = false
    @AppStorage("hideBalanceOnOpen") var hideBalanceOnOpen: Bool = false
    @AppStorage("readClipboard") var readClipboard: Bool = false
    @AppStorage("warnWhenSendingOver100") var warnWhenSendingOver100: Bool = false //TODO: Feature needed
    @AppStorage("showRecentlyPaidContacts") var showRecentlyPaidContacts: Bool = true //TODO: probably not going to be in anytime soon
    @AppStorage("requirePinOnLaunch") var requirePinOnLaunch: Bool = false //TODO: Feature needed
    @AppStorage("requirePinWhenIdle") var requirePinWhenIdle: Bool = true //TODO: Feature needed
    @AppStorage("requirePinForPayments") var requirePinForPayments: Bool = false //TODO: Feature needed
    @AppStorage("useFaceIDInstead") var useFaceIDInstead: Bool = false //TODO: Feature needed

    // PIN Management
    @AppStorage("hasPinEnabled") var hasPinEnabled: Bool = false //TODO: Feature needed

    // Widget Settings
    @AppStorage("showWidgets") var showWidgets: Bool = true
    @AppStorage("showWidgetTitles") var showWidgetTitles: Bool = false

    init() {
        if hideBalanceOnOpen {
            hideBalance = true
        }
    }
}
