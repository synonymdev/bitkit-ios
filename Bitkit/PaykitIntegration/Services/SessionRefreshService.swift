//
//  SessionRefreshService.swift
//  Bitkit
//
//  Background service for refreshing Pubky sessions before expiration
//

import Foundation
import BackgroundTasks

/// Service for managing background session refresh tasks
public class SessionRefreshService {
    
    public static let shared = SessionRefreshService()
    
    private let taskIdentifier = "to.bitkit.paykit.session-refresh"
    private let pubkySDK = PubkySDKService.shared
    
    private init() {}
    
    // MARK: - Registration
    
    /// Register the background task with the system
    public func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handleSessionRefresh(task: task as! BGAppRefreshTask)
        }
        
        Logger.info("Registered background session refresh task", context: "SessionRefreshService")
    }
    
    // MARK: - Scheduling
    
    /// Schedule the next session refresh check
    public func scheduleSessionRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        
        // Schedule for 1 hour from now
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            Logger.info("Scheduled session refresh task", context: "SessionRefreshService")
        } catch {
            Logger.error("Failed to schedule session refresh: \(error)", context: "SessionRefreshService")
        }
    }
    
    // MARK: - Task Handling
    
    private func handleSessionRefresh(task: BGAppRefreshTask) {
        Logger.info("Background session refresh task started", context: "SessionRefreshService")
        
        // Schedule the next refresh
        scheduleSessionRefresh()
        
        // Create expiration handler
        task.expirationHandler = {
                Logger.warn("Session refresh task expired", context: "SessionRefreshService")
        }
        
        // Perform refresh
        Task {
            await pubkySDK.refreshExpiringSessions()
            task.setTaskCompleted(success: true)
            Logger.info("Background session refresh completed", context: "SessionRefreshService")
        }
    }
    
    // MARK: - Manual Trigger
    
    /// Manually trigger session refresh (for testing or foreground use)
    public func refreshSessionsNow() async {
        Logger.info("Manual session refresh triggered", context: "SessionRefreshService")
        await pubkySDK.refreshExpiringSessions()
    }
}

