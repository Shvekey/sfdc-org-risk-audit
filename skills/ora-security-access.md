---
name: ora-security-access
description: Audits a Salesforce org's security and access control posture. Checks OWD sharing model, guest user exposure, dangerous profile/permission set permissions, field-level security gaps, public group risks, and clickjack/XSS protections. Part of the Org Risk Audit (ORA) tool. Weight: 20% of global score.
whenToUse: Invoked by the org-risk-audit master skill for the Security & Access Control domain. Can also be run standalone with /ora-security-access.
---

# ORA — Security & Access Control

> **Domain weight:** 20% of global org risk score
> **MCP servers:** `sobject-reads`, `salesforce-api-context`
> **Fallback:** `sf data query` / `sf data query --use-tooling-api`
> **Scoring contract:** See `ora-scoring-contract`

---

## How to Run This Skill

You will be asked two things before the scan begins:
1. Which org to target (alias or username)
2. Scan mode: Quick or Deep (if not already passed by the master skill)

Then work through each check below in order. Collect all findings before calculating the final score.

---

## Quick Scan Checks (run in both modes)

These checks use count queries and metadata existence checks only. No body parsing.

### QS-1 — Organisation-Wide Defaults (OWDs)

**What to query:**
```soql
SELECT QualifiedApiName, Label, InternalSharingModel, ExternalSharingModel
FROM EntityDefinition
WHERE IsCustomizable = true
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY InternalSharingModel DESC
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- Any standard business object (Account, Contact, Lead, Opportunity, Case, Contract) with `InternalSharingModel = 'ReadWrite'` or `'Read'` and `ExternalSharingModel = 'ReadWrite'` or `'Read'` → 🟠 High per object
- Any custom object with `ExternalSharingModel = 'ReadWrite'` → 🔴 Critical
- Any custom object with `ExternalSharingModel = 'Read'` → 🟠 High
- Any object with `InternalSharingModel = 'ReadWrite'` (Public Read/Write internally) on sensitive objects (Contact, Lead, Case) → 🟡 Medium

**Why it matters:** Overly permissive OWDs are the broadest access risk in Salesforce — they grant access to every user by default with no further configuration needed.

---

### QS-2 — Guest User Exposure

**What to query:**
```soql
SELECT Id, Name, IsActive, UserType, Profile.Name
FROM User
WHERE UserType = 'Guest' AND IsActive = true
```
Use: `sf data query --target-org <org>`

Then for each active guest user's profile, check dangerous permissions:
```soql
SELECT Id, Name, PermissionsViewAllData, PermissionsModifyAllData,
       PermissionsCreateRecords, PermissionsEditOwnRecord
FROM Profile
WHERE UserType = 'Guest'
```

**Scoring rules:**
- Guest user exists AND `PermissionsViewAllData = true` → 🔴 Critical
- Guest user exists AND `PermissionsModifyAllData = true` → 🔴 Critical
- Guest user exists AND `PermissionsCreateRecords = true` on sensitive objects → 🟠 High
- Active guest user with no associated active Experience Cloud site → 🟡 Medium (orphaned guest user)

**Why it matters:** The guest user profile is the most exploited misconfiguration in Salesforce. It represents unauthenticated public internet access to your org's data.

---

### QS-3 — Profiles with Dangerous Permissions

**What to query:**
```soql
SELECT Id, Name, UserType,
       PermissionsModifyAllData, PermissionsViewAllData,
       PermissionsManageUsers, PermissionsAuthorApex,
       PermissionsCustomizeApplication, PermissionsDataExport
FROM Profile
WHERE UserType = 'Standard'
  AND (PermissionsModifyAllData = true
    OR PermissionsViewAllData = true
    OR PermissionsManageUsers = true)
ORDER BY Name
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Any non-System Administrator profile with `PermissionsModifyAllData = true` → 🔴 Critical per profile
- Any non-System Administrator profile with `PermissionsViewAllData = true` → 🟠 High per profile
- More than 2 profiles with `PermissionsManageUsers = true` → 🟡 Medium
- Any profile with both `PermissionsAuthorApex = true` AND `PermissionsModifyAllData = true` (non-admin) → 🔴 Critical

**Why it matters:** Profiles with Modify All Data or View All Data bypass all record-level sharing — sharing rules, OWDs, and ownership are completely irrelevant for these users.

---

### QS-4 — Permission Sets with Dangerous Permissions

**What to query:**
```soql
SELECT Id, Name, Label,
       PermissionsModifyAllData, PermissionsViewAllData,
       PermissionsManageUsers, PermissionsAuthorApex,
       PermissionsDataExport
FROM PermissionSet
WHERE IsOwnedByProfile = false
  AND (NamespacePrefix = null OR NamespacePrefix = '')
  AND (PermissionsModifyAllData = true
    OR PermissionsViewAllData = true
    OR PermissionsManageUsers = true
    OR PermissionsDataExport = true)
ORDER BY Name
```
Use: `sf data query --target-org <org>`

Then check how many users each dangerous permission set is assigned to:
```soql
SELECT PermissionSet.Name, COUNT(AssigneeId) userCount
FROM PermissionSetAssignment
WHERE PermissionSet.PermissionsModifyAllData = true
  OR PermissionSet.PermissionsViewAllData = true
GROUP BY PermissionSet.Name
```

**Scoring rules:**
- Permission set with `PermissionsModifyAllData = true` assigned to >5 users → 🔴 Critical
- Permission set with `PermissionsModifyAllData = true` assigned to ≤5 users → 🟠 High
- Permission set with `PermissionsViewAllData = true` assigned to >10 users → 🟠 High
- Permission set with `PermissionsDataExport = true` → 🟡 Medium (flag for review)

**Why it matters:** Permission sets are often created without the same scrutiny as profiles. Dangerous permissions can silently accumulate in permission sets assigned to integration users or broad user groups.

---

### QS-5 — Active User Count vs Admin Count

**What to query:**
```soql
SELECT COUNT(Id) totalUsers FROM User WHERE IsActive = true AND UserType = 'Standard'
```
```soql
SELECT COUNT(Id) adminUsers FROM User
WHERE IsActive = true AND UserType = 'Standard'
  AND Profile.PermissionsModifyAllData = true
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Admin % of total users > 20% → 🟠 High
- Admin % of total users > 10% → 🟡 Medium
- Fewer than 2 active admins → 🟡 Medium (single point of failure)
- Admin % ≤ 5% → ✅ Pass

**Why it matters:** Too many admins means too many accounts that can bypass all security controls. Industry best practice is ≤5% of users with admin-equivalent access.

---

## Deep Scan Checks (deep scan mode only)

### DS-1 — Field-Level Security Gaps on Sensitive Objects

For each of the following sensitive standard objects — `Contact`, `Lead`, `Account`, `Case`, `Opportunity` — check if any profile other than System Administrator has both Read AND Edit FLS on fields commonly considered sensitive (SSN, date of birth, financial fields, custom fields ending in `SSN__c`, `DOB__c`, `TaxId__c`, `BankAccount__c`, `Password__c`, `Token__c`).

**What to query:**
```soql
SELECT Id, SobjectType, Field, PermissionsRead, PermissionsEdit,
       Parent.Name, Parent.ProfileId
FROM FieldPermissions
WHERE SobjectType IN ('Contact', 'Lead', 'Account', 'Case')
  AND PermissionsEdit = true
  AND (Field LIKE '%SSN%' OR Field LIKE '%DOB%' OR Field LIKE '%TaxId%'
    OR Field LIKE '%BankAccount%' OR Field LIKE '%Password%'
    OR Field LIKE '%Token%' OR Field LIKE '%Secret%')
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Any profile other than System Administrator with Edit FLS on fields matching sensitive patterns → 🟠 High per field/profile combination
- More than 5 such combinations → escalate to 🔴 Critical

**Why it matters:** FLS is the last line of defence for sensitive field data. If a user's profile grants read/edit to sensitive fields broadly, sharing rules and record ownership offer no protection.

---

### DS-2 — Object-Level Security on Custom Objects

For all custom objects (`QualifiedApiName LIKE '%__c'`), check if any non-admin profile has Create/Read/Edit/Delete (CRUD) access enabled in bulk:

**What to query:**
```soql
SELECT Id, SobjectType, PermissionsRead, PermissionsCreate,
       PermissionsEdit, PermissionsDelete, PermissionsViewAllRecords,
       PermissionsModifyAllRecords, Parent.Name
FROM ObjectPermissions
WHERE SobjectType LIKE '%__c'
  AND (PermissionsViewAllRecords = true OR PermissionsModifyAllRecords = true)
ORDER BY SobjectType
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Non-admin profile/permission set with `PermissionsModifyAllRecords = true` on a custom object → 🟠 High per object
- More than 3 such objects → 🔴 Critical
- `PermissionsViewAllRecords = true` on custom objects broadly → 🟡 Medium

---

### DS-3 — Public Groups with Broad Membership

**What to query:**
```soql
SELECT Id, Name, Type FROM Group
WHERE Type = 'Regular'
ORDER BY Name
```
For each group, count members:
```soql
SELECT GroupId, COUNT(Id) memberCount
FROM GroupMember
GROUP BY GroupId
ORDER BY memberCount DESC
LIMIT 20
```
Use: `sf data query --target-org <org>`

Check if any sharing rules reference these groups with write access (query `SharingRules` via Metadata API retrieve if available, otherwise note as manual check required).

**Scoring rules:**
- Any public group with >50% of active users as members used in a sharing rule with write access → 🟠 High
- Public group with ALL internal users effectively as members → 🔴 Critical
- More than 20 public groups with no clear naming convention → 🔵 Low (governance risk)

---

### DS-4 — Security Headers (Clickjack, XSS, CSP)

**What to query via Tooling API:**
```soql
SELECT Id, ClickjackProtectionLevel, ContentSniffingProtection,
       XssProtection, ReferrerPolicy
FROM SecuritySettings
```
Use: `sf data query --target-org <org> --use-tooling-api`

Note: Available fields vary by org. Retrieve what is available and skip unavailable fields.

**Scoring rules:**
- `ClickjackProtectionLevel` not set to `AllowSameDomainFraming` or stricter → 🟠 High
- `ContentSniffingProtection = false` → 🟡 Medium
- `XssProtection = false` → 🟠 High
- All protections enabled → ✅ Pass

**Why it matters:** Clickjacking attacks against Salesforce are well-documented. These settings are trivial to enable and their absence represents negligent configuration.

---

### DS-5 — Sharing Model Enforcement on Critical Custom Objects

For each custom object, verify that objects with sensitive data (`ExternalSharingModel = 'Private'`) have at least one active sharing rule or rely on role hierarchy, not public access.

Cross-reference OWD results from QS-1 with object names containing patterns like `Payment__c`, `Medical__c`, `Financial__c`, `Health__c`, `PII__c`, `Personal__c`.

**Scoring rules:**
- Custom object name suggests sensitive data AND `ExternalSharingModel` is not `Private` → 🔴 Critical
- Custom object name suggests sensitive data AND `InternalSharingModel` is `ReadWrite` → 🟠 High

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
 SECURITY & ACCESS CONTROL          [n]/100 [RAG]
 [QUICK SCAN — preliminary] OR [DEEP SCAN — final]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

End with:
```
SECURITY & ACCESS CONTROL SCORE: [n]/100 [RAG]
Weight in global score: 20%
Weighted contribution: [n × 0.20] points
```
