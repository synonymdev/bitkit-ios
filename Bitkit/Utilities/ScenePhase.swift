//
//  ScenePhase.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/15.
//

import SwiftUI

fileprivate struct HandleLightningStateOnScenePhaseChange: ViewModifier {
    @StateObject var viewModel = ViewModel.shared
    @ObservedObject var lnViewModel = LightningViewModel.shared
    @Environment(\.scenePhase) var scenePhase

    let sleepTime: UInt64 = 5_00_000_000 // 0.5 seconds
    
    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { newPhase in
                guard viewModel.walletExists == true else {
                    return
                }
                
                Task { @MainActor in
                    Logger.debug("Scene phase changed: \(newPhase)")
                    
                    if newPhase == .background {
                        do {
                            try await stopNodeIfNeeded()
                        } catch {
                            Logger.error(error, context: "Failed to stop LN")
                        }
                        return
                    }
                    
                    if newPhase == .active {
                        do {
                            try await startNodeIfNeeded()
                        } catch {
                            Logger.error(error, context: "Failed to start LN")
                        }
                    }
                }
            }
    }
    
    func stopNodeIfNeeded() async throws {
        if lnViewModel.state == .stopped || lnViewModel.state == .stopping {
            return
        }
        
        while lnViewModel.state == .starting {
            Logger.debug("Waiting for LN to start first before stopping...")
            try await Task.sleep(nanoseconds: sleepTime)
        }
        
        guard scenePhase != .active else {
            Logger.debug("Scene phase is active, abandoning node stop...")
            return
        }
        
        guard lnViewModel.state != .stopped && lnViewModel.state != .stopping else {
            Logger.debug("LN is already stopped or stopping")
            return
        }
        
        Logger.debug("App backgrounded Stopping node...")
        
        try await lnViewModel.stop()
    }
    
    func startNodeIfNeeded() async throws {
        while lnViewModel.state == .stopping {
            Logger.debug("Node is still stopping, waiting...")
            try await Task.sleep(nanoseconds: sleepTime)
        }
        
        guard lnViewModel.state == .stopped else {
            Logger.debug("LN is already running or starting, abandoning restart...")
            return
        }
        
        guard scenePhase != .background else {
            Logger.debug("Scene phase is background, abandoning node restart...")
            return
        }
        
        Logger.debug("App active, starting LN service...")

        try await lnViewModel.start()
    }
}

extension View {
    /// Stops and restarts lightning node when the app enters the background and foreground
    /// - Returns: View
    func handleLightningStateOnScenePhaseChange() -> some View {
        self.modifier(HandleLightningStateOnScenePhaseChange())
    }
}
