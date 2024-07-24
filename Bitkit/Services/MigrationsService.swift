//
//  MigrationsService.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/23.
//

import Foundation
import SQLite
import LightningDevKit //TODO remove this when we no longer need it to read funding_tx and index from monitors

class MigrationsService {
    static var shared = MigrationsService()
    
    private init() {}
}

//MARK: Migrations for RN Bitkit to Swift Bitkit
extension MigrationsService {
    func ldkToLdkNode(seed: Data, manager: Data, monitors: [Data]) throws {
        //MARK: get funding_tx and index using plain LDK
        //https://github.com/lightning/bolts/blob/master/02-peer-protocol.md#definition-of-channel_id
        
        Logger.info("Migrating LDK to LDKNode")
        let storagePath = Env.ldkStorage.path
        let sqlFilePath = Env.ldkStorage.appendingPathComponent("ldk_node_data.sqlite").path
        
        //Create path if doesn't exist
        let fileManager = FileManager.default
        var isDir: ObjCBool = true
        if !fileManager.fileExists(atPath: storagePath, isDirectory: &isDir) {
            try fileManager.createDirectory(atPath: storagePath, withIntermediateDirectories: true, attributes: nil)
            Logger.debug("Directory created at path: \(storagePath)")
        }
        
        Logger.debug(sqlFilePath, context: "SQLIte file path")
        
        //Can't migrate if data currently exists
        guard !fileManager.fileExists(atPath: sqlFilePath) else {
            throw AppError(serviceError: .ldkNodeSqliteAlreadyExists)
        }
        
        let db = try Connection(sqlFilePath)
        
        let table = Table("ldk_node_data")
        
        let pnCol = Expression<String>("primary_namespace")
        let snCol = Expression<String>("secondary_namespace")
        let keyCol = Expression<String>("key")
        let valueCol = Expression<Data?>("value")

        try db.run(table.create { t in
            t.column(pnCol, primaryKey: true)
            t.column(snCol)
            t.column(keyCol)
            t.column(valueCol)
        })
        
        //MARK change to this as the primary key
        //CREATE TABLE IF NOT EXISTS {} (
//        primary_namespace TEXT NOT NULL,
//        secondary_namespace TEXT DEFAULT \"\" NOT NULL,
//        key TEXT NOT NULL CHECK (key <> ''),
//        value BLOB, PRIMARY KEY ( primary_namespace, secondary_namespace, key )
//    );
        
        let insert = table.insert(pnCol <- "", snCol <- "", keyCol <- "manager", valueCol <- manager)
        let rowid = try db.run(insert)
        Logger.debug(rowid, context: "Inserted manager")
        
        let seconds = UInt64(NSDate().timeIntervalSince1970)
        let nanoSeconds = UInt32.init(truncating: NSNumber(value: seconds * 1000 * 1000))
        let keysManager = KeysManager(
            seed: [UInt8](seed),
            startingTimeSecs: seconds,
            startingTimeNanos: nanoSeconds
        )
        
        for monitor in monitors {
            guard let channelMonitor = Bindings.readThirtyTwoBytesChannelMonitor(ser: [UInt8](monitor), argA: keysManager.asEntropySource(), argB: keysManager.asSignerProvider()).getValue()?.1 else {
                Logger.error("Could not read channel monitor")
                continue
            }
                        
            let fundingTx = Data(channelMonitor.getFundingTxo().0.getTxid()!).hex
            let index = channelMonitor.getFundingTxo().0.getIndex()
                        
            //let key = format!("{}_{}", funding_txo.txid.to_string(), funding_txo.index);
            let key = "\(fundingTx)_\(index)"            
            
            let insert = table.insert(
                pnCol <- "monitors",
                snCol <- "",
                keyCol <- key,
                valueCol <- monitor
            )
            
            try db.run(insert)
            Logger.debug(key, context: "Inserted monitor")
        }
        
        //TODO iterate through monitors and insert
        
        //        let entries = try db.prepare(table)
        
        //        for entry in entries {
        //            Logger.debug(entry.get("key"))
        //        }
    }
}
