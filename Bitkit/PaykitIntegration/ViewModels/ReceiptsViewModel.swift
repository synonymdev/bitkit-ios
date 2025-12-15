//
//  ReceiptsViewModel.swift
//  Bitkit
//
//  ViewModel for Receipts view
//

import Foundation
import SwiftUI

@MainActor
class ReceiptsViewModel: ObservableObject {
    @Published var receipts: [PaymentReceipt] = []
    @Published var searchQuery: String = ""
    @Published var selectedStatus: PaymentReceiptStatus?
    @Published var selectedDirection: PaymentDirection?
    @Published var isLoading = false
    
    private let receiptStorage: ReceiptStorage
    private let identityName: String
    
    init(identityName: String = "default") {
        self.identityName = identityName
        self.receiptStorage = ReceiptStorage(identityName: identityName)
    }
    
    func loadReceipts() {
        isLoading = true
        receipts = receiptStorage.listReceipts()
        isLoading = false
    }
    
    func filterReceipts() {
        var filtered = receiptStorage.listReceipts()
        
        if let status = selectedStatus {
            filtered = filtered.filter { $0.status == status }
        }
        
        if let direction = selectedDirection {
            filtered = filtered.filter { $0.direction == direction }
        }
        
        if !searchQuery.isEmpty {
            filtered = receiptStorage.searchReceipts(query: searchQuery)
        }
        
        receipts = filtered
    }
    
    func clearFilters() {
        selectedStatus = nil
        selectedDirection = nil
        searchQuery = ""
        loadReceipts()
    }
    
    var totalSent: UInt64 {
        receiptStorage.totalSent()
    }
    
    var totalReceived: UInt64 {
        receiptStorage.totalReceived()
    }
    
    var completedCount: Int {
        receiptStorage.completedCount()
    }
    
    var pendingCount: Int {
        receiptStorage.pendingCount()
    }
}

