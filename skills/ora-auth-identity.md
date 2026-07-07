---
name: ora-auth-identity
description: Audits a Salesforce org's authentication and identity posture. Checks MFA enforcement, session security settings, SSO configuration, connected app OAuth policies, password policies, and trusted IP ranges. Part of the Org Risk Audit (ORA) tool. Weight: 15% of global score.
whenToUse: Invoked by the org-risk-audit master skill for the Authentication & Identity domain. Can also be run standalone with /ora-auth-identity.
---

# ORA — Authentication & Identity

> **Domain weight:** 15% of global org risk score
> **MCP servers:** `salesforce-api-context`, `sobject-reads`
> **Fallback:** `sf data query --use-tooling-api` / `sf data query`
> **Scoring contract:** See `ora-scoring-contract`

---

## How to Run This Skill

You will be asked two things before the scan begins:
1. Which org to target (alias or username)
2. Scan mode: Quick or Deep (if not already passed by the master skill)

Then work through each check below in order. Collect all findings before calculating the final score.

---

## Quick Scan Checks (run in both modes)

### QS-1 — MFA Enforcement (Org-Level)

**What to query via Tooling API:**
```soql
SELECT Id, RequireHttps, RequireMfa, MfaDirectUiLoginEnabled
FROM SecuritySettings
```
Use: `sf data query --target-org <org> --use-tooling-api`

If `SecuritySettings` is not accessible, check the profile-level MFA permission as a proxy:
```soql
SELECT Id, Name, PermissionsMultiFactorAuthentication
FROM Profile
WHERE UserType = 'Standard'
  AND PermissionsMultiFactorAuthentication = false
ORDER BY Name
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- `RequireMfa = false` at org level AND no profiles have `PermissionsMultiFactorAuthentication = true` → 🔴 Critical
- `RequireMfa = false` but some profiles enforce MFA → 🟠 High (partial enforcement, users without MFA profiles are exposed)
- `MfaDirectUiLoginEnabled = false` (SSO-only org where MFA is handled by IdP) → ✅ Pass with note
- `RequireMfa = true` → ✅ Pass

**Why it matters:** Salesforce mandated MFA for all production orgs. Its absence is both a compliance violation and the single most exploited authentication gap. Credential stuffing attacks are trivially defeated by MFA.

---

### QS-2 — Password Policy Strength

**What to query via Tooling API:**
```soql
SELECT Id, PasswordMaxLoginAttempts, PasswordMinLength,
       PasswordComplexity, PasswordExpiration, PasswordEnforceHistory,
       PasswordLockoutEffectivePeriod
FROM SecuritySettings
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- `PasswordMaxLoginAttempts = 0` (no lockout) → 🔴 Critical (enables brute-force)
- `PasswordMaxLoginAttempts > 10` → 🟠 High
- `PasswordMinLength < 8` → 🟠 High
- `PasswordComplexity` not set to require mixed case + numbers + symbols → 🟡 Medium
- `PasswordExpiration = 0` (never expires) when MFA is not enforced → 🟡 Medium
- `PasswordEnforceHistory = 0` (no history) → 🔵 Low
- `PasswordMaxLoginAttempts` between 3–10, `PasswordMinLength` ≥ 8, complexity enforced → ✅ Pass

**Why it matters:** Weak password policies are especially dangerous for orgs without MFA. Even with MFA, brute-force lockout is a denial-of-service vector against user accounts.

---

### QS-3 — Session Security Settings

**What to query via Tooling API:**
```soql
SELECT Id, SessionTimeout, SessionTimeoutWarning,
       ForceLogoutOnSessionTimeout, LockSessionsToDomain,
       LockSessionsToIp, UseLocalStorageForLogoutUrl,
       EnableSMSBasedTwoFactor, RequireHttps
FROM SessionSettings
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- `RequireHttps = false` → 🔴 Critical (sessions transmitted in plaintext)
- `SessionTimeout` > 8 hours (value in minutes: > 480) → 🟠 High
- `LockSessionsToIp = false` AND `LockSessionsToDomain = false` → 🟡 Medium (session tokens not bound to origin)
- `ForceLogoutOnSessionTimeout = false` → 🟡 Medium
- `SessionTimeout` ≤ 4 hours AND `RequireHttps = true` → ✅ Pass

**Why it matters:** Long-lived sessions that are not bound to IP or domain can be hijacked via token theft. HTTPS is non-negotiable — any org serving sessions over HTTP is trivially compromised on any shared network.

---

### QS-4 — Trusted IP Ranges at Org Level

**What to query:**
```soql
SELECT Id, StartAddress, EndAddress, Description
FROM NetworkAccess
ORDER BY StartAddress
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- No trusted IP ranges defined AND login IP restrictions not set on admin profiles (cross-reference `ora-user-profile` QS-4) → 🟡 Medium
- Trusted IP range includes `0.0.0.0` to `255.255.255.255` (entire internet) → 🔴 Critical
- A single range covers a CIDR wider than /8 (i.e. > 16 million IPs) → 🟠 High
- Trusted ranges are present and reasonably scoped → ✅ Pass

**Why it matters:** Trusted IP ranges bypass the email verification step for logins from unknown locations. An over-permissive range effectively disables this protection for all users.

---

### QS-5 — Connected Apps with Full OAuth Scope

**What to query via Tooling API:**
```soql
SELECT Id, Name, OptionsAllowAdminApprovedUsersOnly,
       Scopes, RefreshTokenValidityPeriod,
       OptionsRefreshTokenValidityMetric
FROM ConnectedApplication
WHERE (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY Name
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- Any connected app with `Scopes` containing `full` or `api` AND `OptionsAllowAdminApprovedUsersOnly = false` → 🔴 Critical (any user can authorise)
- Any connected app with `Scopes = 'full'` → 🟠 High (regardless of admin approval setting)
- `RefreshTokenValidityPeriod = 0` (refresh tokens never expire) → 🟠 High
- Connected apps restricted to admin-approved users only with scoped permissions → ✅ Pass

**Why it matters:** Connected apps with `full` scope and no admin-approval requirement allow any authenticated user to grant a third-party application complete access to the org on their behalf — including data export and admin operations.

---

### QS-6 — SSO Configuration Presence

**What to query via Tooling API:**
```soql
SELECT Id, Name, SamlVersion, Issuer, OptionsUserProvisioning,
       AttributeFormat, AttributeName
FROM SamlSsoConfig
WHERE (NamespacePrefix = null OR NamespacePrefix = '')
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- No SSO configuration in a production org with >50 users → 🟡 Medium (users relying solely on Salesforce-native credentials)
- SSO configured but `OptionsUserProvisioning = false` (users must be manually created) → 🔵 Low
- SSO configured with user provisioning → ✅ Pass
- SSO not applicable (small org, internal tool) → note as context, no deduction

**Why it matters:** SSO centralises authentication at the enterprise IdP, where stronger controls (MFA, conditional access, device compliance) can be enforced. Orgs without SSO cannot inherit enterprise identity controls.

---

## Deep Scan Checks (deep scan mode only)

### DS-1 — OAuth Token Audit: Long-Lived Tokens in Use

**What to query:**
```soql
SELECT Id, AppName, UserId, User.Name, UseCount, LastUsedDate,
       ConnectedApp.Name
FROM OauthToken
ORDER BY LastUsedDate DESC
LIMIT 100
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- OAuth tokens last used > 180 days ago that are still active → 🟡 Medium per token set (stale authorisations)
- OAuth tokens belonging to inactive users → 🟠 High (orphaned access grants)
- OAuth tokens for connected apps that no longer exist in the org → 🟠 High
- All active tokens used within 90 days and assigned to active users → ✅ Pass

**Why it matters:** Long-lived OAuth tokens that are never revoked accumulate silently. A token issued to a departed user's account continues to provide API access even after the user is deactivated if the token was issued before deactivation.

---

### DS-2 — Auth Providers (Social Login) Configuration

**What to query via Tooling API:**
```soql
SELECT Id, FriendlyName, ProviderType, ConsumerKey,
       DefaultScopes, RegistrationHandlerClass
FROM AuthProvider
WHERE (NamespacePrefix = null OR NamespacePrefix = '')
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- Any `ProviderType` of `Google`, `Facebook`, or `GitHub` in a production org → 🟠 High (consumer identity providers not appropriate for business data)
- Auth provider with no `RegistrationHandlerClass` set → 🟠 High (user provisioning is uncontrolled)
- Auth provider with `DefaultScopes` including `email` only (no profile claims) → 🟡 Medium (insufficient claims for identity assurance)
- Auth providers restricted to enterprise IdP types (SAML, OpenID Connect to corporate IdP) → ✅ Pass

**Why it matters:** Allowing social login providers (Google personal, Facebook) into a business org means someone with any Google account can potentially authenticate if the registration handler is not correctly restrictive.

---

### DS-3 — Named Credentials and External Credentials

**What to query via Tooling API:**
```soql
SELECT Id, DeveloperName, Endpoint, PrincipalType,
       Protocol, AllowMergeFieldsInBody, AllowMergeFieldsInHeader
FROM NamedCredential
WHERE (NamespacePrefix = null OR NamespacePrefix = '')
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- `AllowMergeFieldsInBody = true` OR `AllowMergeFieldsInHeader = true` → 🟠 High per credential (user-controlled data injected into outbound auth headers — SSRF/injection risk)
- `Protocol = 'Password'` (Basic Auth) named credential calling an external endpoint over HTTP (non-HTTPS endpoint) → 🔴 Critical
- `Protocol = 'Password'` over HTTPS → 🟡 Medium (Basic Auth is weaker than OAuth; flag for review)
- Named credentials using OAuth or certificate-based auth → ✅ Pass

**Why it matters:** Named credentials with merge field injection allow Apex code — or even formula fields — to inject attacker-controlled data into outbound authentication headers, creating server-side request forgery vectors.

---

### DS-4 — Certificate and Key Management

**What to query via Tooling API:**
```soql
SELECT Id, DeveloperName, ExpirationDate, KeySize, MasterLabel,
       OptionsIsClientCertificate
FROM Certificate
WHERE (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY ExpirationDate ASC
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- Certificate expiring within 30 days → 🟠 High per certificate (imminent service disruption)
- Certificate expiring within 90 days → 🟡 Medium
- Certificate with `KeySize < 2048` → 🟠 High (weak key length)
- Certificate already expired → 🔴 Critical (dependent integrations using it are broken or bypassed)
- All certificates valid >90 days with KeySize ≥ 2048 → ✅ Pass

**Why it matters:** Expired certificates break SSO, API integrations, and mutual TLS. Weak key sizes violate modern cryptographic standards and are trivially breakable with sufficient compute.

---

### DS-5 — Lightning Login / Passwordless Authentication Configuration

**What to query via Tooling API:**
```soql
SELECT Id, EnableLightningLogin
FROM SecuritySettings
```
Also check profile-level permission:
```soql
SELECT Id, Name, PermissionsLightningLoginUser
FROM Profile
WHERE PermissionsLightningLoginUser = true
  AND UserType = 'Standard'
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY Name
```
Use: `sf data query --target-org <org> --use-tooling-api` and `sf data query --target-org <org>`

**Scoring rules:**
- Lightning Login enabled AND admin profiles have `PermissionsLightningLoginUser = true` → 🟡 Medium (passwordless on admin accounts reduces one authentication factor)
- Lightning Login enabled but MFA is also enforced → ✅ Pass (Lightning Login requires a registered device, equivalent to MFA)
- Lightning Login disabled or restricted to non-admin users → ✅ Pass

**Why it matters:** Lightning Login is device-bound passwordless authentication. It is generally secure, but enabling it on admin accounts in an org without MFA can reduce authentication assurance if device registration controls are weak.

---

## Score Calculation

After all applicable checks complete, calculate the domain score:

```
Start: 100
Deduct: (Critical findings × 25) + (High findings × 12) + (Medium findings × 5) + (Low findings × 2)
Floor:  0
```

Apply RAG threshold:
- 🟢 86–100
- 🟡 56–85
- 🔴 0–55

---

## Output Template

Follow the exact output format defined in `ora-scoring-contract` Section 6. Use this domain header:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 AUTHENTICATION & IDENTITY          [n]/100 [RAG]
 [QUICK SCAN — preliminary] OR [DEEP SCAN — final]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

End with:
```
AUTHENTICATION & IDENTITY SCORE: [n]/100 [RAG]
Weight in global score: 15%
Weighted contribution: [n × 0.15] points
```
