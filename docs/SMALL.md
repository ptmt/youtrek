# SMALL

## Login form: Wi‑Fi-aware base URL prefill

- Implemented auto-prefill for the setup login form base URL when no stored draft URL is available.
- In `Sources/YouTrek/App/Windows/SetupWindow.swift`:
  - On `preload()`, if `container.storedConfigurationDraft().baseURL` is empty and current Wi‑Fi SSID contains `JetBrains` (case-insensitive), `baseURLString` is set to `https://youtrack.jetbrains.com`.
  - Added `currentSSID()` helper in the same file using `CWWiFiClient.shared().interface()?.ssid()`.
- The behavior is non-intrusive: existing draft base URL values continue to take precedence; SSID-based prefill applies only as fallback.
