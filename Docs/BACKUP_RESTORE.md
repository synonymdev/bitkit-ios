# Backup and Restore Guide

This document covers the backup and restore functionality for Paykit sessions and data.

## Table of Contents

1. [Overview](#overview)
2. [Backup Format](#backup-format)
3. [Encryption Specification](#encryption-specification)
4. [iOS Implementation](#ios-implementation)
5. [Android Implementation](#android-implementation)
6. [Testing Procedures](#testing-procedures)
7. [Troubleshooting](#troubleshooting)

---

## Overview

### What Gets Backed Up

| Data Type | Included | Notes |
|-----------|----------|-------|
| Session tokens | ✅ | Encrypted with user password |
| Session metadata | ✅ | Capabilities, expiry, peer info |
| Noise key cache | ❌ | Re-derived on restore |
| Private endpoints | ✅ | Encrypted |
| Contact list | ✅ | From Pubky follows |
| Payment history | ❌ | Stored separately in main wallet |

### What's NOT Backed Up

- Master seed (backed up with wallet mnemonic)
- Derived keys (re-computed from seed)
- Temporary session data
- Cache data

---

## Backup Format

### File Structure

```
paykit_backup_v1.bin
├── Header (32 bytes)
│   ├── Magic: "PKBK" (4 bytes)
│   ├── Version: 1 (2 bytes)
│   ├── Flags: 0x0001 (2 bytes) - encrypted
│   ├── Created: unix timestamp (8 bytes)
│   ├── Salt: random (16 bytes)
├── Encrypted Payload
│   ├── Nonce (12 bytes)
│   ├── Ciphertext (variable)
│   └── Tag (16 bytes)
```

### JSON Payload (before encryption)

```json
{
  "version": 1,
  "created_at": 1702900000,
  "sessions": [
    {
      "id": "session_abc123",
      "peer_pubkey": "z6Mk...",
      "capabilities": ["read", "write"],
      "expires_at": 1703000000,
      "session_secret": "encrypted_separately"
    }
  ],
  "private_endpoints": [
    {
      "method_id": "lightning",
      "endpoint": "lnurl...",
      "is_private": true
    }
  ],
  "contacts": [
    {
      "pubkey": "z6Mk...",
      "name": "Alice",
      "payment_methods": ["lightning", "onchain"]
    }
  ]
}
```

---

## Encryption Specification

### Algorithm

- **KDF**: Argon2id
- **Encryption**: ChaCha20-Poly1305
- **Salt**: 16 bytes random
- **Nonce**: 12 bytes random

### Key Derivation

```
password = user_provided_password
salt = random(16)
key = argon2id(password, salt, {
    memory: 64MB,
    iterations: 3,
    parallelism: 4,
    output_length: 32
})
```

### Encryption Process

```
nonce = random(12)
aad = header_bytes  // Additional authenticated data
(ciphertext, tag) = chacha20_poly1305_encrypt(key, nonce, plaintext, aad)
output = nonce || ciphertext || tag
```

### Decryption Process

```
(nonce, ciphertext, tag) = parse(encrypted_data)
plaintext = chacha20_poly1305_decrypt(key, nonce, ciphertext, tag, aad)
verify(plaintext)
```

---

## iOS Implementation

### Export Flow

```swift
final class PaykitBackupManager {
    
    func exportBackup(password: String) async throws -> Data {
        // 1. Gather data
        let sessions = sessionManager.getAllSessions()
        let endpoints = endpointStorage.getPrivateEndpoints()
        let contacts = contactStorage.getAllContacts()
        
        // 2. Create payload
        let payload = BackupPayload(
            version: 1,
            createdAt: Date(),
            sessions: sessions.map { $0.toBackupFormat() },
            privateEndpoints: endpoints,
            contacts: contacts
        )
        
        // 3. Serialize
        let jsonData = try JSONEncoder().encode(payload)
        
        // 4. Encrypt
        let salt = SecureRandom.bytes(16)
        let key = try deriveKey(password: password, salt: salt)
        let encrypted = try encrypt(data: jsonData, key: key)
        
        // 5. Create backup file
        var header = BackupHeader()
        header.magic = "PKBK"
        header.version = 1
        header.flags = 0x0001
        header.created = UInt64(Date().timeIntervalSince1970)
        header.salt = salt
        
        return header.toData() + encrypted
    }
    
    private func deriveKey(password: String, salt: Data) throws -> Data {
        let passwordData = password.data(using: .utf8)!
        return try Argon2.hash(
            password: passwordData,
            salt: salt,
            iterations: 3,
            memory: 64 * 1024,
            parallelism: 4,
            outputLength: 32
        )
    }
    
    private func encrypt(data: Data, key: Data) throws -> Data {
        let nonce = SecureRandom.bytes(12)
        let box = try ChaChaPoly.seal(data, using: key, nonce: nonce)
        return nonce + box.ciphertext + box.tag
    }
}
```

### Import Flow

```swift
extension PaykitBackupManager {
    
    func importBackup(data: Data, password: String) async throws -> ImportResult {
        // 1. Parse header
        guard data.count >= 32 else {
            throw BackupError.invalidFormat
        }
        
        let header = try BackupHeader.parse(data: data.prefix(32))
        guard header.magic == "PKBK" else {
            throw BackupError.invalidMagic
        }
        guard header.version == 1 else {
            throw BackupError.unsupportedVersion
        }
        
        // 2. Derive key
        let key = try deriveKey(password: password, salt: header.salt)
        
        // 3. Decrypt
        let encryptedData = data.suffix(from: 32)
        let plaintext = try decrypt(data: encryptedData, key: key)
        
        // 4. Parse payload
        let payload = try JSONDecoder().decode(BackupPayload.self, from: plaintext)
        
        // 5. Import data
        var imported = 0
        var skipped = 0
        
        for session in payload.sessions {
            if session.expiresAt > Date() {
                try await sessionManager.importSession(session)
                imported += 1
            } else {
                skipped += 1
            }
        }
        
        for endpoint in payload.privateEndpoints {
            try await endpointStorage.importEndpoint(endpoint)
        }
        
        for contact in payload.contacts {
            try await contactStorage.importContact(contact)
        }
        
        return ImportResult(
            sessionsImported: imported,
            sessionsSkipped: skipped,
            endpointsImported: payload.privateEndpoints.count,
            contactsImported: payload.contacts.count
        )
    }
    
    private func decrypt(data: Data, key: Data) throws -> Data {
        guard data.count >= 28 else { // nonce(12) + tag(16)
            throw BackupError.invalidCiphertext
        }
        
        let nonce = data.prefix(12)
        let tag = data.suffix(16)
        let ciphertext = data.dropFirst(12).dropLast(16)
        
        return try ChaChaPoly.open(
            SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
            using: key
        )
    }
}
```

### Share Sheet Integration

```swift
// Export and share
let backupData = try await backupManager.exportBackup(password: password)
let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("bitkit_paykit_backup.bin")
try backupData.write(to: url)

let shareSheet = UIActivityViewController(
    activityItems: [url],
    applicationActivities: nil
)
present(shareSheet, animated: true)
```

---

## Android Implementation

### Export Flow

```kotlin
class PaykitBackupManager @Inject constructor(
    private val sessionManager: SessionManager,
    private val endpointStorage: EndpointStorage,
    private val contactStorage: ContactStorage,
) {
    suspend fun exportBackup(password: String): ByteArray {
        // 1. Gather data
        val sessions = sessionManager.getAllSessions()
        val endpoints = endpointStorage.getPrivateEndpoints()
        val contacts = contactStorage.getAllContacts()
        
        // 2. Create payload
        val payload = BackupPayload(
            version = 1,
            createdAt = System.currentTimeMillis() / 1000,
            sessions = sessions.map { it.toBackupFormat() },
            privateEndpoints = endpoints,
            contacts = contacts
        )
        
        // 3. Serialize
        val jsonData = Json.encodeToString(payload).toByteArray()
        
        // 4. Encrypt
        val salt = SecureRandom().generateSeed(16)
        val key = deriveKey(password, salt)
        val encrypted = encrypt(jsonData, key)
        
        // 5. Create backup file
        val header = buildHeader(salt)
        
        return header + encrypted
    }
    
    private fun deriveKey(password: String, salt: ByteArray): ByteArray {
        return Argon2Factory.createAdvanced(Argon2Factory.Argon2Types.ARGON2id)
            .hash(3, 65536, 4, password.toByteArray(), salt)
            .rawHashBytes
    }
    
    private fun encrypt(data: ByteArray, key: ByteArray): ByteArray {
        val nonce = SecureRandom().generateSeed(12)
        val cipher = Cipher.getInstance("ChaCha20-Poly1305")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "ChaCha20"), 
            GCMParameterSpec(128, nonce))
        val ciphertext = cipher.doFinal(data)
        return nonce + ciphertext
    }
}
```

### Import Flow

```kotlin
suspend fun importBackup(data: ByteArray, password: String): ImportResult {
    // 1. Parse header
    require(data.size >= 32) { "Invalid backup format" }
    
    val header = parseHeader(data.sliceArray(0 until 32))
    require(header.magic == "PKBK") { "Invalid magic bytes" }
    require(header.version == 1) { "Unsupported version" }
    
    // 2. Derive key
    val key = deriveKey(password, header.salt)
    
    // 3. Decrypt
    val encryptedData = data.sliceArray(32 until data.size)
    val plaintext = decrypt(encryptedData, key)
    
    // 4. Parse payload
    val payload = Json.decodeFromString<BackupPayload>(String(plaintext))
    
    // 5. Import data
    var imported = 0
    var skipped = 0
    
    for (session in payload.sessions) {
        if (session.expiresAt > System.currentTimeMillis() / 1000) {
            sessionManager.importSession(session)
            imported++
        } else {
            skipped++
        }
    }
    
    for (endpoint in payload.privateEndpoints) {
        endpointStorage.importEndpoint(endpoint)
    }
    
    for (contact in payload.contacts) {
        contactStorage.importContact(contact)
    }
    
    return ImportResult(
        sessionsImported = imported,
        sessionsSkipped = skipped,
        endpointsImported = payload.privateEndpoints.size,
        contactsImported = payload.contacts.size
    )
}
```

---

## Testing Procedures

### Unit Tests

```swift
// iOS - BackupManagerTests.swift
func testExportImportRoundTrip() async throws {
    // Create test data
    let session = Session(id: "test", expiresAt: Date().addingTimeInterval(3600))
    try await sessionManager.save(session)
    
    // Export
    let password = "test_password_123"
    let backupData = try await backupManager.exportBackup(password: password)
    
    // Clear data
    try await sessionManager.deleteAll()
    
    // Import
    let result = try await backupManager.importBackup(data: backupData, password: password)
    
    XCTAssertEqual(result.sessionsImported, 1)
    
    // Verify
    let restored = try await sessionManager.getSession(id: "test")
    XCTAssertNotNil(restored)
}

func testDecryptionWithWrongPassword() async throws {
    let backupData = try await backupManager.exportBackup(password: "correct")
    
    do {
        _ = try await backupManager.importBackup(data: backupData, password: "wrong")
        XCTFail("Should have thrown")
    } catch {
        XCTAssertTrue(error is BackupError)
    }
}

func testExpiredSessionsSkipped() async throws {
    // Create expired session
    let expired = Session(id: "expired", expiresAt: Date().addingTimeInterval(-3600))
    try await sessionManager.save(expired)
    
    let backupData = try await backupManager.exportBackup(password: "test")
    try await sessionManager.deleteAll()
    
    let result = try await backupManager.importBackup(data: backupData, password: "test")
    
    XCTAssertEqual(result.sessionsSkipped, 1)
    XCTAssertEqual(result.sessionsImported, 0)
}
```

### E2E Tests

```swift
// iOS - BackupE2ETests.swift
func testBackupExportAndImportFlow() throws {
    // Navigate to backup
    app.buttons["Settings"].tap()
    app.buttons["Paykit"].tap()
    app.buttons["Backup"].tap()
    
    // Tap export
    app.buttons["Export Backup"].tap()
    
    // Enter password
    let passwordField = app.secureTextFields["Password"]
    passwordField.tap()
    passwordField.typeText("TestPassword123!")
    app.buttons["Continue"].tap()
    
    // Wait for export
    XCTAssertTrue(app.staticTexts["Backup Created"].waitForExistence(timeout: 10))
    
    // Now test import
    app.buttons["Done"].tap()
    app.buttons["Import Backup"].tap()
    
    // Select file (simulated)
    // ...
    
    // Enter password
    passwordField.tap()
    passwordField.typeText("TestPassword123!")
    app.buttons["Import"].tap()
    
    // Verify success
    XCTAssertTrue(app.staticTexts["Import Successful"].waitForExistence(timeout: 10))
}
```

### Verification Checklist

- [ ] Export creates valid file
- [ ] Import with correct password succeeds
- [ ] Import with wrong password fails with clear error
- [ ] Expired sessions are skipped
- [ ] Contacts are merged correctly
- [ ] Private endpoints are encrypted
- [ ] File can be shared via system share sheet
- [ ] File can be imported from Files app
- [ ] Backup works offline
- [ ] Large backups (100+ sessions) work

---

## Troubleshooting

### Common Issues

#### 1. Wrong Password Error

**Symptom**: "Decryption failed" or "Invalid password"

**Cause**: Password doesn't match the one used for export

**Solution**: Use the exact same password used during export

#### 2. Unsupported Version

**Symptom**: "Unsupported backup version"

**Cause**: Backup created with newer app version

**Solution**: Update app to latest version

#### 3. Corrupted File

**Symptom**: "Invalid backup format"

**Cause**: File was modified or partially downloaded

**Solution**: Re-download or re-export the backup

#### 4. No Sessions Imported

**Symptom**: Import succeeds but shows 0 sessions imported

**Cause**: All sessions in backup were expired

**Solution**: Create new sessions in source app and re-export

### Recovery Options

If backup is lost:
1. Sessions can be re-created by connecting to Pubky-ring again
2. Contacts can be re-synced from Pubky follows
3. Private endpoints can be re-generated

---

## Security Considerations

1. **Password Strength**: Enforce minimum 8 characters with complexity
2. **Memory Protection**: Clear password from memory after use
3. **File Handling**: Delete temporary files after share/import
4. **No Cloud Sync**: Backup files should not auto-sync to cloud

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | Dec 2025 | Initial backup format |

