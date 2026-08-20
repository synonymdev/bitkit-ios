import Foundation

/// Fills in wallet ids that predate wallet-scoped activity data before a backup envelope is
/// decoded. Each Core-owned array field is handed to the matching Core migration helper as raw
/// JSON, so the app never edits Core model JSON itself. Records that already carry a wallet id are
/// left unchanged, so this is safe to run on current backups too.
///
/// Pure and free of the core FFI — the migrations are injected — so the change detection that
/// drives the post-restore rewrite can be unit tested. `BackupService` supplies the real
/// `migrateBackup*Json` helpers.
enum BackupFieldMigration {
    struct Result {
        let data: Data
        /// Whether any field's parsed JSON actually differs from what the server sent, meaning the
        /// stored envelope predates wallet-scoped activity data and is worth rewriting once the
        /// restore has persisted it.
        let changed: Bool
    }

    static func apply(_ dataBytes: Data, fieldMigrations: [String: (String) throws -> String]) -> Result {
        guard var root = (try? JSONSerialization.jsonObject(with: dataBytes)) as? [String: Any] else {
            return Result(data: dataBytes, changed: false)
        }

        var changed = false

        for (field, migrate) in fieldMigrations {
            guard let array = root[field] as? [Any] else { continue }

            do {
                let arrayData = try JSONSerialization.data(withJSONObject: array)
                let migratedJson = try migrate(String(decoding: arrayData, as: UTF8.self))
                guard let migratedData = migratedJson.data(using: .utf8),
                      let migratedArray = try (JSONSerialization.jsonObject(with: migratedData)) as? [Any]
                else { continue }

                // Compare the parsed elements rather than the raw strings: core's serializer may
                // reorder object keys without changing a value, and `NSDictionary.isEqual` ignores
                // key order. Records are still compared positionally, so a migration that reordered
                // the array would report a change it did not make — one wasted upload, which is the
                // safe direction to be wrong in.
                if !(array as NSArray).isEqual(migratedArray as NSArray) {
                    changed = true
                }
                root[field] = migratedArray
            } catch {
                // The envelope stays readable without this field's migration, and for one that
                // already carries wallet ids nothing is lost at all. Failing the whole category
                // here would be worse.
                Logger.warn("Backup field migration failed for '\(field)': \(error)", context: "BackupFieldMigration")
            }
        }

        guard changed, let migrated = try? JSONSerialization.data(withJSONObject: root) else {
            return Result(data: dataBytes, changed: false)
        }

        return Result(data: migrated, changed: true)
    }
}
