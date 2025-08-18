import Foundation
import LightningDevKit // TODO: remove this when we no longer need it to read funding_tx and index from monitors
import SQLite

typealias Expression = SQLite.Expression

class MigrationsService {
    static var shared = MigrationsService()

    private init() {}
}

// MARK: Migrations for RN Bitkit to Swift Bitkit

extension MigrationsService {
    func ldkToLdkNode(walletIndex: Int, seed: Data, manager: Data, monitors: [Data]) throws {
        Logger.info("Migrating LDK to LDKNode")
        let ldkStorage = Env.ldkStorage(walletIndex: walletIndex)
        let sqlFilePath = ldkStorage.appendingPathComponent("ldk_node_data.sqlite").path

        // Create path if doesn't exist
        let fileManager = FileManager.default
        var isDir: ObjCBool = true
        if !fileManager.fileExists(atPath: ldkStorage.path, isDirectory: &isDir) {
            try fileManager.createDirectory(atPath: ldkStorage.path, withIntermediateDirectories: true, attributes: nil)
            Logger.debug("Directory created at path: \(ldkStorage.path)")
        }

        Logger.debug(sqlFilePath, context: "SQLIte file path")

        // Can't migrate if data currently exists
        guard !fileManager.fileExists(atPath: sqlFilePath) else {
            throw AppError(serviceError: .ldkNodeSqliteAlreadyExists)
        }

        let db = try Connection(sqlFilePath)

        let table = Table("ldk_node_data")

        let pnCol = Expression<String>("primary_namespace")
        let snCol = Expression<String>("secondary_namespace")
        let keyCol = Expression<String>("key")
        let valueCol = Expression<Data?>("value")

        try db.run(
            table.create { t in
                t.column(pnCol, primaryKey: true)
                t.column(snCol)
                t.column(keyCol)
                t.column(valueCol)
            }
        )

        // TODO: use create statement directly from LDK-node instead
        // CREATE TABLE IF NOT EXISTS {} (
        //        primary_namespace TEXT NOT NULL,
        //        secondary_namespace TEXT DEFAULT \"\" NOT NULL,
        //        key TEXT NOT NULL CHECK (key <> ''),
        //        value BLOB, PRIMARY KEY ( primary_namespace, secondary_namespace, key )
        //    );

        let insert = table.insert(pnCol <- "", snCol <- "", keyCol <- "manager", valueCol <- manager)
        let rowid = try db.run(insert)
        Logger.debug(rowid, context: "Inserted manager")

        let seconds = UInt64(NSDate().timeIntervalSince1970)
        let nanoSeconds = UInt32(truncating: NSNumber(value: seconds * 1000 * 1000))
        let keysManager = KeysManager(
            seed: [UInt8](seed),
            startingTimeSecs: seconds,
            startingTimeNanos: nanoSeconds
        )

        for monitor in monitors {
            // MARK: get funding_tx and index using plain LDK

            // https://github.com/lightning/bolts/blob/master/02-peer-protocol.md#definition-of-channel_id
            guard let channelMonitor = Bindings.readThirtyTwoBytesChannelMonitor(
                ser: [UInt8](monitor), argA: keysManager.asEntropySource(), argB: keysManager.asSignerProvider()
            ).getValue()?.1
            else {
                Logger.error("Could not read channel monitor using readThirtyTwoBytesChannelMonitor")
                throw AppError(serviceError: .ldkToLdkNodeMigration)
            }

            let fundingTx = Data(channelMonitor.getFundingTxo().0.getTxid()!.reversed()).hex
            let index = channelMonitor.getFundingTxo().0.getIndex()

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
    }
}
