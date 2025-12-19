# Telemetry and Monitoring Guide

This guide covers structured logging, metrics collection, and crash reporting for Paykit integration.

## Table of Contents

1. [Logging Architecture](#logging-architecture)
2. [iOS Logging](#ios-logging)
3. [Android Logging](#android-logging)
4. [Crashlytics Integration](#crashlytics-integration)
5. [Metrics Collection](#metrics-collection)
6. [Privacy Considerations](#privacy-considerations)

---

## Logging Architecture

### Log Levels

| Level | Usage | Example |
|-------|-------|---------|
| Error | Unexpected failures requiring attention | Payment failed, session expired |
| Warning | Recoverable issues | Rate limited, fallback used |
| Info | Key operations | Session created, payment completed |
| Debug | Detailed flow information | Handshake steps, cache hits |
| Trace | Fine-grained debugging | Byte-level operations |

### Structured Log Format

```json
{
  "timestamp": "2025-12-18T12:34:56.789Z",
  "level": "info",
  "module": "paykit.session",
  "event": "session_created",
  "correlation_id": "abc123",
  "data": {
    "session_id": "redacted",
    "ttl_seconds": 86400,
    "capabilities": ["read", "write"]
  }
}
```

### Sensitive Data Handling

**NEVER LOG:**
- Private keys
- Session secrets
- Full payment addresses
- User identifiers (without hashing)
- Biometric data

**ALLOWED (with care):**
- Truncated public keys (first 8 chars)
- Hashed session IDs
- Payment amounts (aggregated, not individual)
- Error codes and stack traces

---

## iOS Logging

### OSLog Integration

```swift
import OSLog

extension Logger {
    static let paykit = Logger(subsystem: "to.bitkit", category: "paykit")
    static let session = Logger(subsystem: "to.bitkit", category: "paykit.session")
    static let payment = Logger(subsystem: "to.bitkit", category: "paykit.payment")
    static let noise = Logger(subsystem: "to.bitkit", category: "paykit.noise")
}

// Usage
Logger.paykit.info("Session created", metadata: [
    "ttl": ttlSeconds,
    "capabilities": capabilities.joined(separator: ",")
])

Logger.paykit.error("Payment failed", metadata: [
    "error_code": error.code,
    "method": methodId
])
```

### PaykitLogger Implementation

```swift
/// Centralized Paykit logging with privacy controls
final class PaykitLogger {
    static let shared = PaykitLogger()
    
    private let logger = Logger(subsystem: "to.bitkit", category: "paykit")
    private let isDebugBuild: Bool
    
    private init() {
        #if DEBUG
        isDebugBuild = true
        #else
        isDebugBuild = false
        #endif
    }
    
    // MARK: - Session Events
    
    func sessionCreated(ttlSeconds: Int, capabilities: [String]) {
        logger.info("Session created: ttl=\(ttlSeconds)s, caps=\(capabilities.joined(separator: ","))")
        
        Analytics.log(event: "paykit_session_created", params: [
            "ttl_bucket": ttlBucket(ttlSeconds),
            "capability_count": capabilities.count
        ])
    }
    
    func sessionExpired(reason: SessionExpiryReason) {
        logger.info("Session expired: \(reason.rawValue)")
        
        Analytics.log(event: "paykit_session_expired", params: [
            "reason": reason.rawValue
        ])
    }
    
    func sessionRefreshFailed(error: Error) {
        logger.error("Session refresh failed: \(error.localizedDescription)")
        
        Crashlytics.log("Session refresh failed")
        Crashlytics.record(error: error)
    }
    
    // MARK: - Payment Events
    
    func paymentInitiated(methodId: String, amountSats: UInt64) {
        logger.info("Payment initiated: method=\(methodId), amount=\(amountBucket(amountSats))")
        
        Analytics.log(event: "paykit_payment_initiated", params: [
            "method": methodId,
            "amount_bucket": amountBucket(amountSats)
        ])
    }
    
    func paymentCompleted(methodId: String, durationMs: Int) {
        logger.info("Payment completed: method=\(methodId), duration=\(durationMs)ms")
        
        Analytics.log(event: "paykit_payment_completed", params: [
            "method": methodId,
            "duration_bucket": durationBucket(durationMs)
        ])
    }
    
    func paymentFailed(methodId: String, error: PaykitError) {
        logger.error("Payment failed: method=\(methodId), error=\(error.code)")
        
        Analytics.log(event: "paykit_payment_failed", params: [
            "method": methodId,
            "error_code": error.code
        ])
        
        Crashlytics.log("Payment failed: \(error.code)")
    }
    
    // MARK: - Noise Protocol Events
    
    func handshakeStarted(peerPubkeyPrefix: String) {
        if isDebugBuild {
            logger.debug("Handshake started: peer=\(peerPubkeyPrefix)...")
        }
    }
    
    func handshakeCompleted(durationMs: Int) {
        logger.info("Handshake completed: duration=\(durationMs)ms")
        
        Analytics.log(event: "paykit_handshake_completed", params: [
            "duration_bucket": durationBucket(durationMs)
        ])
    }
    
    func handshakeFailed(error: NoiseError) {
        logger.error("Handshake failed: \(error.localizedDescription)")
        
        Crashlytics.log("Noise handshake failed")
        Crashlytics.record(error: error)
    }
    
    // MARK: - Helper Functions
    
    private func ttlBucket(_ seconds: Int) -> String {
        switch seconds {
        case 0..<3600: return "< 1h"
        case 3600..<86400: return "1h-24h"
        case 86400..<604800: return "1d-7d"
        default: return "> 7d"
        }
    }
    
    private func amountBucket(_ sats: UInt64) -> String {
        switch sats {
        case 0..<1000: return "< 1k"
        case 1000..<10000: return "1k-10k"
        case 10000..<100000: return "10k-100k"
        case 100000..<1000000: return "100k-1M"
        default: return "> 1M"
        }
    }
    
    private func durationBucket(_ ms: Int) -> String {
        switch ms {
        case 0..<100: return "< 100ms"
        case 100..<500: return "100-500ms"
        case 500..<1000: return "500ms-1s"
        case 1000..<5000: return "1-5s"
        default: return "> 5s"
        }
    }
}
```

### Console.app Filtering

View Paykit logs in Console.app:

1. Open Console.app
2. Select your device/simulator
3. Filter by: `subsystem:to.bitkit category:paykit`

---

## Android Logging

### Timber Integration

```kotlin
// In Application class
class BitkitApp : Application() {
    override fun onCreate() {
        super.onCreate()
        
        if (BuildConfig.DEBUG) {
            Timber.plant(Timber.DebugTree())
        } else {
            Timber.plant(CrashlyticsTree())
        }
    }
}

// Custom Crashlytics tree
class CrashlyticsTree : Timber.Tree() {
    override fun log(priority: Int, tag: String?, message: String, t: Throwable?) {
        if (priority >= Log.WARN) {
            Firebase.crashlytics.log("$tag: $message")
            t?.let { Firebase.crashlytics.recordException(it) }
        }
    }
}
```

### PaykitLogger Implementation

```kotlin
/**
 * Centralized Paykit logging with privacy controls
 */
object PaykitLogger {
    private const val TAG = "Paykit"
    
    // MARK: - Session Events
    
    fun sessionCreated(ttlSeconds: Int, capabilities: List<String>) {
        Timber.tag(TAG).i("Session created: ttl=${ttlSeconds}s, caps=${capabilities.joinToString()}")
        
        Firebase.analytics.logEvent("paykit_session_created") {
            param("ttl_bucket", ttlBucket(ttlSeconds))
            param("capability_count", capabilities.size.toLong())
        }
    }
    
    fun sessionExpired(reason: SessionExpiryReason) {
        Timber.tag(TAG).i("Session expired: ${reason.name}")
        
        Firebase.analytics.logEvent("paykit_session_expired") {
            param("reason", reason.name)
        }
    }
    
    fun sessionRefreshFailed(error: Throwable) {
        Timber.tag(TAG).e(error, "Session refresh failed")
        
        Firebase.crashlytics.log("Session refresh failed")
        Firebase.crashlytics.recordException(error)
    }
    
    // MARK: - Payment Events
    
    fun paymentInitiated(methodId: String, amountSats: ULong) {
        Timber.tag(TAG).i("Payment initiated: method=$methodId, amount=${amountBucket(amountSats)}")
        
        Firebase.analytics.logEvent("paykit_payment_initiated") {
            param("method", methodId)
            param("amount_bucket", amountBucket(amountSats))
        }
    }
    
    fun paymentCompleted(methodId: String, durationMs: Long) {
        Timber.tag(TAG).i("Payment completed: method=$methodId, duration=${durationMs}ms")
        
        Firebase.analytics.logEvent("paykit_payment_completed") {
            param("method", methodId)
            param("duration_bucket", durationBucket(durationMs))
        }
    }
    
    fun paymentFailed(methodId: String, error: PaykitError) {
        Timber.tag(TAG).e("Payment failed: method=$methodId, error=${error.code}")
        
        Firebase.analytics.logEvent("paykit_payment_failed") {
            param("method", methodId)
            param("error_code", error.code)
        }
        
        Firebase.crashlytics.log("Payment failed: ${error.code}")
    }
    
    // MARK: - Noise Protocol Events
    
    fun handshakeStarted(peerPubkeyPrefix: String) {
        if (BuildConfig.DEBUG) {
            Timber.tag(TAG).d("Handshake started: peer=$peerPubkeyPrefix...")
        }
    }
    
    fun handshakeCompleted(durationMs: Long) {
        Timber.tag(TAG).i("Handshake completed: duration=${durationMs}ms")
        
        Firebase.analytics.logEvent("paykit_handshake_completed") {
            param("duration_bucket", durationBucket(durationMs))
        }
    }
    
    fun handshakeFailed(error: NoiseError) {
        Timber.tag(TAG).e(error, "Handshake failed")
        
        Firebase.crashlytics.log("Noise handshake failed")
        Firebase.crashlytics.recordException(error)
    }
    
    // MARK: - Helper Functions
    
    private fun ttlBucket(seconds: Int): String = when {
        seconds < 3600 -> "< 1h"
        seconds < 86400 -> "1h-24h"
        seconds < 604800 -> "1d-7d"
        else -> "> 7d"
    }
    
    private fun amountBucket(sats: ULong): String = when {
        sats < 1000u -> "< 1k"
        sats < 10000u -> "1k-10k"
        sats < 100000u -> "10k-100k"
        sats < 1000000u -> "100k-1M"
        else -> "> 1M"
    }
    
    private fun durationBucket(ms: Long): String = when {
        ms < 100 -> "< 100ms"
        ms < 500 -> "100-500ms"
        ms < 1000 -> "500ms-1s"
        ms < 5000 -> "1-5s"
        else -> "> 5s"
    }
}
```

### Logcat Filtering

View Paykit logs in Logcat:

```bash
adb logcat -s Paykit:*
```

---

## Crashlytics Integration

### iOS Setup

```swift
// In AppDelegate
import FirebaseCrashlytics

func application(_ application: UIApplication, 
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    FirebaseApp.configure()
    
    // Set user identifier (hashed)
    if let userId = WalletManager.shared.userId {
        Crashlytics.crashlytics().setUserID(userId.sha256Prefix(8))
    }
    
    return true
}
```

### Android Setup

```kotlin
// In Application class
override fun onCreate() {
    super.onCreate()
    
    // Set user identifier (hashed)
    WalletManager.userId?.let { userId ->
        Firebase.crashlytics.setUserId(userId.sha256Prefix(8))
    }
}
```

### Custom Keys

```swift
// iOS
Crashlytics.crashlytics().setCustomValue("paykit_1.0", forKey: "paykit_version")
Crashlytics.crashlytics().setCustomValue("noise_1.0", forKey: "noise_version")
```

```kotlin
// Android
Firebase.crashlytics.setCustomKey("paykit_version", "1.0")
Firebase.crashlytics.setCustomKey("noise_version", "1.0")
```

---

## Metrics Collection

### Key Metrics

| Metric | Type | Description |
|--------|------|-------------|
| paykit_sessions_active | Gauge | Current active sessions |
| paykit_handshake_duration_ms | Histogram | Handshake duration |
| paykit_payment_duration_ms | Histogram | Payment completion time |
| paykit_payment_success_rate | Counter | Success/failure ratio |
| paykit_cache_hit_rate | Counter | Noise key cache effectiveness |

### Firebase Analytics Events

| Event | Parameters |
|-------|------------|
| paykit_session_created | ttl_bucket, capability_count |
| paykit_session_expired | reason |
| paykit_payment_initiated | method, amount_bucket |
| paykit_payment_completed | method, duration_bucket |
| paykit_payment_failed | method, error_code |
| paykit_handshake_completed | duration_bucket |

### Custom Metrics Implementation

```swift
// iOS Metrics Collector
final class PaykitMetrics {
    static let shared = PaykitMetrics()
    
    private var handshakeDurations: [Int] = []
    private var paymentDurations: [Int] = []
    private var activeSessions = 0
    
    func recordHandshake(durationMs: Int) {
        handshakeDurations.append(durationMs)
        
        // Report to analytics every 100 samples
        if handshakeDurations.count >= 100 {
            reportHandshakeMetrics()
            handshakeDurations.removeAll()
        }
    }
    
    func recordPayment(durationMs: Int, success: Bool) {
        if success {
            paymentDurations.append(durationMs)
        }
    }
    
    func sessionOpened() {
        activeSessions += 1
    }
    
    func sessionClosed() {
        activeSessions = max(0, activeSessions - 1)
    }
    
    private func reportHandshakeMetrics() {
        let p50 = percentile(handshakeDurations, 50)
        let p99 = percentile(handshakeDurations, 99)
        
        Analytics.log(event: "paykit_metrics", params: [
            "handshake_p50": p50,
            "handshake_p99": p99,
            "active_sessions": activeSessions
        ])
    }
}
```

---

## Privacy Considerations

### Data Minimization

1. **Use buckets instead of exact values** for amounts and durations
2. **Hash identifiers** before logging or analytics
3. **Aggregate data** before sending to servers
4. **No PII** in logs or analytics

### User Consent

```swift
// iOS
final class AnalyticsConsent {
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "analytics_enabled") }
        set { 
            UserDefaults.standard.set(newValue, forKey: "analytics_enabled")
            Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(newValue)
            Analytics.setAnalyticsCollectionEnabled(newValue)
        }
    }
}
```

### GDPR Compliance

- Provide opt-out mechanism
- Allow data deletion requests
- Document what data is collected
- Retain data only as needed

---

## Dashboard Recommendations

### Grafana/DataDog Panels

1. **Session Health**
   - Active sessions over time
   - Session creation rate
   - Session expiry reasons

2. **Payment Performance**
   - Payment success rate
   - Payment duration (p50, p99)
   - Failures by error code

3. **Noise Protocol**
   - Handshake success rate
   - Handshake duration
   - Rate limit triggers

4. **Alerts**
   - Payment failure rate > 5%
   - Handshake failure rate > 1%
   - Active sessions spike/drop > 50%

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | Dec 2025 | Initial telemetry guide |

