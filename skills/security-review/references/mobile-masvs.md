# Mobile — OWASP MASVS v2.1.0

<!-- Inspired by: davila7/claude-code-templates `owasp-security` (MIT · Copyright (c) 2025 Daniel (San) Ávila)
     Canonical content: OWASP MASVS v2.1.0 (2024-01-18) — 8 control groups. -->

**Read only when the project has a mobile app.** This harness's axis guides are all web at present
(4 frontend axes · 8 backend axes), so mobile is a place the axis guides do not cover.

One core premise for mobile: **the device is in the attacker's hands.** Client-side validation,
obfuscation and root detection only raise the difficulty; they are not a boundary. The boundary is always the server.

| Control group | What to check |
| --- | --- |
| **MASVS-STORAGE** | Does sensitive data stay in plaintext locally. Credentials in Keychain (iOS) / Keystore (Android). Does it leak into logs, backups or screenshot caches |
| **MASVS-CRYPTO** | Standard libraries only. No hardcoded keys. Do keys come from the platform's secure storage and is there a rotation procedure |
| **MASVS-AUTH** | Does the authentication ruling happen **on the server**. Biometrics are UX, not authorization — re-check the server token after unlock |
| **MASVS-NETWORK** | TLS enforced. If certificate or public key pinning is used, is there a rotation plan. Is there no plaintext fallback |
| **MASVS-PLATFORM** | Minimize exposed components (Android exported Activity/Service/Provider). Is deep link input validated. The exposure surface of the JS bridge in WebView |
| **MASVS-CODE** | Dependencies current. Are debug symbols and test code absent from the release. Is input validation duplicated on the server |
| **MASVS-RESILIENCE** | Root/jailbreak, debugger and tampering detection. **This is defense in depth, not a boundary** — if an asset is protected by this alone, that is a design defect |
| **MASVS-PRIVACY** | Is the data collected minimal. Do permission requests match the actual features. What do third-party SDKs send |

**Audit order**: STORAGE → NETWORK → AUTH accounts for most real incidents. Look at RESILIENCE last,
and only to check whether any design treats it as a boundary.
