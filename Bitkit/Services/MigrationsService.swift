//
//  MigrationsService.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/23.
//

import Foundation
import SQLite

class MigrationsService {
    static var shared = MigrationsService()
    
    private init() {}
    
    func migrateAll() async throws {
        Logger.debug("Handling all migrations.")
        try await ServiceQueue.background(.migration) {
            try self.ldkToLdkNode()
        }
    }
}

//MARK: Migrations for RN Bitkit to Swift Bitkit
extension MigrationsService {
    func ldkToLdkNode() throws {
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
        
        let pn = Expression<String>("primary_namespace")
        let sn = Expression<String>("secondary_namespace")
        let key = Expression<String>("key")
        let value = Expression<Data?>("value")

        try db.run(table.create { t in
            t.column(pn, primaryKey: true)
            t.column(sn)
            t.column(key)
            t.column(value)
        })
        
        //        let entries = try db.prepare(table)
        
        //        for entry in entries {
        //            Logger.debug(entry.get("key"))
        //        }
    }
}
