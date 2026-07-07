---
name: ora-org-config
description: Audits a Salesforce org's configuration and operational health. Checks storage consumption, API usage trends, sandbox refresh cadence, critical limits headroom, Einstein/feature enablement hygiene, and My Domain configuration. Part of the Org Risk Audit (ORA) tool. Weight: 10% of global score.
whenToUse: Invoked by the org-risk-audit master skill for the Org Configuration & Health domain. Can also be run standalone with /ora-org-config.
---

# ORA — Org Configuration & Health

> **Domain weight:** 10% of global org risk score
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

### QS-1 — My Domain Configuration

**What to query via Tooling API:**
```soql
SELECT Id, Domain, DomainType, HttpsOption
FROM Domain
```
Use: `sf data query --target-org <org> --use-tooling-api`

Also check Enhanced Domains enablement:
```soql
SELECT Id, UseEnhancedDomains
FROM DomainSettings
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- No My Domain configured (org still on legacy `na*.salesforce.com` format) → 🔴 Critical (required for SSO, Lightning, and many security features)
- My Domain configured but `HttpsOption` not set to `HttpsOnly` → 🟠 High
- My Domain configured but Enhanced Domains not enabled (if available in org edition) → 🟡 Medium
- My Domain with HTTPS-only and Enhanced Domains → ✅ Pass

**Why it matters:** My Domain is a prerequisite for SSO, Lightning Experience, and several security controls. Without it, the org is running on a shared Salesforce subdomain, which prevents proper CORS, CSP, and cookie policies.

---

### QS-2 — Data and File Storage Consumption

**What to query:**
```soql
SELECT StorageUsed, StorageTotal
FROM Organization
```
Use: `sf data query --target-org <org>`

Note: If `Organization` object does not expose storage fields directly, check via `sf org display --target-org <org>` or Limits API endpoint `GET /services/data/vXX.0/limits/`.

**Scoring rules:**
- Data storage > 90% consumed → 🔴 Critical (org will hit hard limit; new records will fail to save)
- Data storage 80–90% consumed → 🟠 High
- Data storage 70–80% consumed → 🟡 Medium
- File storage > 90% consumed → 🟠 High
- Storage ≤ 70% → ✅ Pass

**Why it matters:** When data storage hits 100%, Salesforce prevents all new record creation. This is an unplanned outage that cannot be resolved without data deletion or licence purchase — neither of which is fast.

---

### QS-3 — API Request Limit Consumption

**What to query via Limits API:**
Use `sf org display --target-org <org>` or REST endpoint `GET /services/data/vXX.0/limits/` to retrieve `DailyApiRequests`.

Parse `Max` and `Remaining` values. Calculate: `usedPercent = (Max - Remaining) / Max * 100`.

**Scoring rules:**
- Daily API requests > 90% consumed by midday (high-velocity orgs) → 🟠 High
- Daily API requests > 80% consumed → 🟡 Medium
- Bulk API daily limit > 80% consumed → 🟡 Medium
- API consumption ≤ 70% → ✅ Pass

Note: API limits reset daily. This check reflects a point-in-time snapshot; flag if consumption at query time is unexpectedly high relative to time of day.

**Why it matters:** API throttling causes integration failures. When the daily API limit is hit, all external system integrations fail until the limit resets at midnight Pacific time — a full-day outage for connected systems.

---

### QS-4 — Critical Governor Limit Headroom

Check key org-level limits via the Limits API (`GET /services/data/vXX.0/limits/`):

Key limits to check:
- `DailyAsyncApexExecutions` — scheduled/batch Apex
- `DailyBulkApiRequests` — Bulk API v1
- `DailyBulkV2QueryFileStorageMB` — Bulk API v2 query storage
- `DailyGenericStreamingApiEvents` — Platform Events
- `HourlyODataCallout` — OData callouts
- `MassEmail` — daily mass email limit

**Scoring rules:**
- Any limit at > 90% consumed → 🟠 High per limit
- Any limit at > 75% consumed → 🟡 Medium per limit
- All limits < 75% → ✅ Pass

---

### QS-5 — Deployed Sandbox Count vs Licence Entitlement

**What to query:**
```soql
SELECT Id, SandboxName, SandboxInfoId, LicenseType, Status,
       CreatedDate, LastModifiedDate
FROM SandboxProcess
WHERE Status = 'Completed'
ORDER BY CreatedDate DESC
```
Use: `sf data query --target-org <org>`

Also check sandbox licences available:
```soql
SELECT Name, TotalLicenses, UsedLicenses
FROM UserLicense
WHERE Name LIKE '%Sandbox%'
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- All sandbox slots consumed and no refresh history in 90 days → 🟡 Medium (stale full-copy sandboxes blocking refresh cadence)
- Sandbox last refreshed > 180 days ago (for full/partial copy sandboxes used for testing) → 🟡 Medium
- No sandboxes at all (production-only workflow) → 🟠 High (no safe testing environment)
- At least one developer sandbox refreshed within 90 days → ✅ Pass

**Why it matters:** Stale sandboxes drift from production configuration, making test results unreliable. Teams without sandbox access test changes directly in production, dramatically increasing deployment risk.

---

## Deep Scan Checks (deep scan mode only)

### DS-1 — CORS and CSP Trusted Sites

**What to query via Tooling API:**
```soql
SELECT Id, UrlPattern, IsActive
FROM CorsWhitelistOrigin
WHERE IsActive = true
```
```soql
SELECT Id, EndpointUrl, IsActive, Context
FROM CspTrustedSite
WHERE IsActive = true
  AND (NamespacePrefix = null OR NamespacePrefix = '')
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- CORS allowlist contains a wildcard (`*`) or `null` origin → 🔴 Critical
- CORS allowlist contains `http://` (non-HTTPS) origins → 🟠 High
- CSP trusted sites list contains `*` wildcard → 🟠 High
- CSP trusted sites with `http://` entries → 🟡 Medium
- CORS and CSP entries are all HTTPS with specific domains → ✅ Pass

**Why it matters:** Wildcard CORS allowlists permit any origin to make cross-site requests to the org's APIs. This enables cross-site request forgery from any domain and negates the browser's same-origin policy.

---

### DS-2 — Remote Site Settings and Callout Configurations

**What to query:**
```soql
SELECT Id, EndpointUrl, IsActive, DisableProtocolSecurity
FROM RemoteSiteSetting
WHERE IsActive = true
  AND (NamespacePrefix = null OR NamespacePrefix = '')
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- `DisableProtocolSecurity = true` on any Remote Site Setting → 🔴 Critical (disables SSL certificate verification for callouts to that endpoint)
- Active Remote Site Setting with `http://` endpoint → 🟠 High (callouts transmit data in plaintext)
- More than 30 active Remote Site Settings → 🟡 Medium (governance concern)
- All active settings use HTTPS with protocol security enabled → ✅ Pass

**Why it matters:** `DisableProtocolSecurity = true` means Salesforce will send callouts to that endpoint without verifying the SSL certificate — equivalent to passing `-k` to curl. Man-in-the-middle attacks against those integrations succeed silently.

---

### DS-3 — Email Deliverability and Relay Settings

**What to query via Tooling API:**
```soql
SELECT Id, AccessLevel, SmtpHost, SmtpPort,
       SmtpUsername, TlsSetting
FROM EmailServicesAddress
```
Also retrieve organisation email settings:
```soql
SELECT Id, SmtpHost, SmtpPort, SmtpUsername, UseSsl
FROM OrgEmailSettings
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- Email relay configured with `UseSsl = false` or `TlsSetting = 'None'` → 🟠 High (email credentials and content transmitted in plaintext)
- Email deliverability set to `System email only` in a production org (blocks all user-facing email) → 🟡 Medium (check if intentional)
- Email relay SMTP host pointing to an internal/private IP → 🟡 Medium (flag for review)
- TLS-enabled relay or Salesforce-native email → ✅ Pass

---

### DS-4 — Installed Packages and AppExchange Security Review Status

**What to query:**
```soql
SELECT Id, SubscriberPackage.Name, SubscriberPackage.NamespacePrefix,
       SubscriberPackageVersion.Name, SubscriberPackageVersion.MajorVersion,
       SubscriberPackageVersion.MinorVersion, SubscriberPackageVersion.PatchVersion,
       SubscriberPackageVersion.IsSecurityReviewed
FROM InstalledSubscriberPackage
ORDER BY SubscriberPackage.Name
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Any installed package with `IsSecurityReviewed = false` → 🟠 High per package (not reviewed by Salesforce security team)
- More than 20 installed packages → 🟡 Medium (sprawl increases attack surface)
- All installed packages security-reviewed → ✅ Pass

**Why it matters:** Unreviewed AppExchange packages run as trusted code inside your org with access to all data and metadata. They bypass all security controls that apply to your own Apex code.

---

### DS-5 — Platform Cache and Custom Metadata Configuration Hygiene

**What to query via Tooling API:**
```soql
SELECT Id, DeveloperName, IsDefaultPartition, Capacity
FROM PlatformCachePartition
WHERE (NamespacePrefix = null OR NamespacePrefix = '')
```
Also check Custom Metadata type record counts:
```soql
SELECT QualifiedApiName, Label
FROM EntityDefinition
WHERE IsCustomizable = true
  AND QualifiedApiName LIKE '%__mdt'
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY QualifiedApiName
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- No Platform Cache partitions configured in an org with heavy Apex usage (>50 classes) → 🔵 Low (missed performance optimisation)
- Platform Cache partition capacity at 0 KB (allocated but empty) → 🔵 Low
- More than 50 Custom Metadata types with no clear naming convention → 🔵 Low (governance)
- Platform Cache configured with reasonable capacity → ✅ Pass

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
 ORG CONFIGURATION & HEALTH         [n]/100 [RAG]
 [QUICK SCAN — preliminary] OR [DEEP SCAN — final]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

End with:
```
ORG CONFIGURATION & HEALTH SCORE: [n]/100 [RAG]
Weight in global score: 10%
Weighted contribution: [n × 0.10] points
```
