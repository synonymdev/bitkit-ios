//
//  PrivateEndpointsView.swift
//  Bitkit
//
//  Private endpoints management view
//

import SwiftUI

struct PrivateEndpointsView: View {
    @StateObject private var viewModel = PrivateEndpointsViewModel()
    @EnvironmentObject private var app: AppViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Private Endpoints")
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    // Info Section
                    infoSection
                    
                    // Peers List
                    if viewModel.peers.isEmpty {
                        emptyStateView
                    } else {
                        peersList
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadEndpoints()
        }
    }
    
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            BodyLText("Private Endpoints")
                .foregroundColor(.textPrimary)
            
            BodyMText("Private endpoints allow you to receive payments from specific peers without publishing your payment methods publicly.")
                .foregroundColor(.textSecondary)
        }
        .padding(16)
        .background(Color.gray900)
        .cornerRadius(8)
    }
    
    private var peersList: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.peers, id: \.self) { peerPubkey in
                PeerEndpointsRow(peerPubkey: peerPubkey, viewModel: viewModel)
                
                if peerPubkey != viewModel.peers.last {
                    Divider()
                        .background(Color.white16)
                }
            }
        }
        .background(Color.gray900)
        .cornerRadius(8)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 80))
                .foregroundColor(.textSecondary)
            
            BodyLText("No Private Endpoints")
                .foregroundColor(.textPrimary)
            
            BodyMText("Private endpoints will appear here when you share them with specific peers")
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

struct PeerEndpointsRow: View {
    let peerPubkey: String
    @ObservedObject var viewModel: PrivateEndpointsViewModel
    @EnvironmentObject private var app: AppViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText(abbreviatedPubkey)
                .foregroundColor(.white)
            
            if let endpoints = viewModel.endpointsForPeer(peerPubkey), !endpoints.isEmpty {
                ForEach(endpoints, id: \.methodId) { endpoint in
                    HStack {
                        BodyMText(endpoint.methodId)
                            .foregroundColor(.textSecondary)
                        
                        Spacer()
                        
                        BodySText(endpoint.endpoint.prefix(20) + "...")
                            .foregroundColor(.textSecondary)
                            .lineLimit(1)
                    }
                }
            } else {
                BodyMText("No endpoints")
                    .foregroundColor(.textSecondary)
            }
        }
        .padding(16)
    }
    
    private var abbreviatedPubkey: String {
        guard peerPubkey.count > 16 else { return peerPubkey }
        let prefix = peerPubkey.prefix(8)
        let suffix = peerPubkey.suffix(8)
        return "\(prefix)...\(suffix)"
    }
}

@MainActor
class PrivateEndpointsViewModel: ObservableObject {
    @Published var peers: [String] = []
    
    private let storage: PrivateEndpointStorage
    private let identityName: String
    
    init(identityName: String = "default") {
        self.identityName = identityName
        self.storage = PrivateEndpointStorage(identityName: identityName)
    }
    
    func loadEndpoints() {
        peers = storage.listPeers()
    }
    
    func endpointsForPeer(_ peerPubkey: String) -> [PrivateEndpointOffer]? {
        let endpoints = storage.listForPeer(peerPubkey)
        return endpoints.isEmpty ? nil : endpoints
    }
}

