---
name: ora-user-profile
description: Audits a Salesforce org's user and profile management posture. Checks inactive users, frozen accounts, login hour/IP restrictions, licence consumption, stale integrations users, and duplicate/redundant profiles. Part of the Org Risk Audit (ORA) tool. Weight: 15% of global score.
whenToUse: Invoked by the org-risk-audit master skill for the User & Profile Management domain. Can also be run standalone with /ora-user-profile.
---

# ORA — User & Profile Management

> **Domain weight:** 15% of global org risk score
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

### QS-1 — Inactive Users Still Holding Licences

**What to query:**
```soql
SELECT COUNT(Id) inactiveCount
FROM User
WHERE IsActive = false
  AND UserType = 'Standard'
  AND LastLoginDate != null
```
Then get the total active licence count:
```soql
SELECT COUNT(Id) activeCount
FROM User
WHERE IsActive = true AND UserType = 'Standard'
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Inactive users with a prior login ≥ 20% of active user count → 🟠 High (licence waste and dormant account risk)
- Inactive users with a prior login ≥ 10% of active user count → 🟡 Medium
- Zero inactive users with prior logins → ✅ Pass

**Why it matters:** Inactive but licensed accounts waste spend and represent dormant credentials — password-reset flows can sometimes reactivate them. Salesforce licences are per-seat and each unused licence is a potential attack vector.

---

### QS-2 — Users Who Have Never Logged In

**What to query:**
```soql
SELECT COUNT(Id) neverLoggedIn
FROM User
WHERE IsActive = true
  AND UserType = 'Standard'
  AND LastLoginDate = null
  AND CreatedDate < LAST_N_DAYS:90
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Active users who never logged in AND were created >90 days ago > 5% of active user base → 🟡 Medium
- Count > 10% of active user base → 🟠 High
- Count ≤ 5% → ✅ Pass

**Why it matters:** Accounts created but never used may belong to departed staff, abandoned projects, or integration setups that were never completed. They hold licences and profile permissions with no accountability.

---

### QS-3 — Frozen Users

**What to query:**
```soql
SELECT COUNT(Id) frozenCount
FROM UserLogin
WHERE IsFrozen = true
```
Then check if any frozen users still hold dangerous permissions via their profile:
```soql
SELECT u.Id, u.Name, u.Profile.Name, u.Profile.PermissionsModifyAllData
FROM User u
WHERE u.IsActive = true
  AND u.UserLogin.IsFrozen = true
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Frozen users with `PermissionsModifyAllData = true` on their profile → 🟠 High (frozen ≠ deprovisioned; permissions are preserved)
- Frozen user count > 10 and none deactivated in the past 30 days → 🟡 Medium (process gap: freezing used as substitute for deactivation)
- Frozen count ≤ 5 with no dangerous permissions → ✅ Pass

**Why it matters:** Freezing a user prevents login but does not remove the licence or revoke permissions. It is a temporary measure, not a proper offboarding step. Long-frozen accounts are often forgotten.

---

### QS-4 — Login IP Range Restrictions

**What to query:**
```soql
SELECT Id, Name, UserType,
       (SELECT Id, StartAddress, EndAddress FROM LoginIpRanges)
FROM Profile
WHERE UserType = 'Standard'
ORDER BY Name
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- System Administrator profile has no IP restrictions → 🟠 High
- More than 50% of standard profiles have no IP restrictions in an org with >50 active users → 🟡 Medium
- All standard profiles have no IP restrictions AND org has no trusted IP ranges set at the org level → 🟠 High
- At least admin profiles have IP restrictions → ✅ Pass (partial credit)

**Why it matters:** Without IP restrictions, a compromised credential can be used from anywhere in the world. IP restrictions are a simple, high-value control especially for admin and integration accounts.

---

### QS-5 — Login Hour Restrictions

**What to query:**
```soql
SELECT Id, Name,
       (SELECT Id, DayOfWeek, TimeStart, TimeEnd FROM LoginHours)
FROM Profile
WHERE UserType = 'Standard'
ORDER BY Name
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- System Administrator profile has no login hour restrictions → 🟡 Medium
- No profiles in the org have any login hour restrictions (LoginHours subquery returns empty for all) → 🟡 Medium
- Integration user profiles have no login hour restrictions → 🔵 Low

**Why it matters:** Login hour restrictions ensure that user accounts can only be used during expected working hours, limiting the window for credential misuse.

---

### QS-6 — Integration / Service Users Without Dedicated Profiles

Integration users should have their own profiles with the minimum permissions required. Check for integration users sharing profiles with human users:

**What to query:**
```soql
SELECT Profile.Name, COUNT(Id) userCount,
       SUM(CASE WHEN Name LIKE '%integration%' OR Name LIKE '%service%'
                  OR Name LIKE '%api%' OR Name LIKE '%system%'
                THEN 1 ELSE 0 END) likelyIntegrations
FROM User
WHERE IsActive = true AND UserType = 'Standard'
GROUP BY Profile.Name
HAVING COUNT(Id) > 1
ORDER BY userCount DESC
```
Note: `CASE`/`SUM` is not supported in SOQL. Use two separate queries:
```soql
SELECT Id, Name, Profile.Name
FROM User
WHERE IsActive = true
  AND UserType = 'Standard'
  AND (Name LIKE '%integration%' OR Name LIKE '%service%'
       OR Name LIKE '%api%' OR Name LIKE '%system%')
ORDER BY Profile.Name
```
Then check whether those profiles are shared with non-integration users by reviewing the profile names. Flag profiles shared between suspected integration users and humans.

Use: `sf data query --target-org <org>`

**Scoring rules:**
- Integration users sharing a profile with 10+ human users → 🟠 High (blast radius of integration credential compromise)
- Integration users with `PermissionsModifyAllData = true` → 🔴 Critical (see also QS-3 in `ora-security-access`)
- Integration users sharing profiles with any human users → 🟡 Medium
- All integration users on dedicated profiles → ✅ Pass

**Why it matters:** Integration users should follow least privilege. Sharing profiles with human users means permission changes for humans unintentionally affect system integrations and vice versa.

---

## Deep Scan Checks (deep scan mode only)

### DS-1 — Users With No MFA Enrollment (when MFA not org-enforced)

First check if MFA is enforced at the org level (covered in `ora-auth-identity`). If it is not, check individual user MFA registration:

**What to query:**
```soql
SELECT COUNT(Id) noMfaCount
FROM User
WHERE IsActive = true
  AND UserType = 'Standard'
  AND Id NOT IN (
    SELECT UserId FROM TwoFactorInfo WHERE Type = 'TOTP'
  )
```
Fallback if TwoFactorInfo is not queryable:
```soql
SELECT Id, Name, Profile.Name
FROM User
WHERE IsActive = true
  AND UserType = 'Standard'
  AND StayInTouchNote = null
```
Note: `StayInTouchNote` is not a reliable MFA proxy. If `TwoFactorInfo` is not accessible, mark this check as `⏭️ SKIPPED` with a note to verify in Setup > Identity Verification.

Use: `sf data query --target-org <org>`

**Scoring rules:**
- >50% of active users have no MFA enrollment (when org-level MFA not enforced) → 🔴 Critical
- 20–50% of active users have no MFA enrollment → 🟠 High
- <20% → 🟡 Medium
- All users enrolled or org-level enforcement active → ✅ Pass (defer to `ora-auth-identity` score)

**Why it matters:** MFA is the single most effective control against credential-based attacks. Salesforce mandated it for all orgs — unenrolled users represent a compliance gap and an attack vector.

---

### DS-2 — Stale Active Users (No Login in 180+ Days)

**What to query:**
```soql
SELECT Id, Name, Profile.Name, LastLoginDate, CreatedDate
FROM User
WHERE IsActive = true
  AND UserType = 'Standard'
  AND LastLoginDate < LAST_N_DAYS:180
ORDER BY LastLoginDate ASC
LIMIT 50
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Stale active users (no login in 180+ days) > 10% of active user base → 🟠 High
- Stale active users > 5% → 🟡 Medium
- Any stale user with System Administrator profile → 🟠 High (admin accounts should be regularly reviewed)
- ≤5% stale → ✅ Pass

**Why it matters:** Stale active accounts represent orphaned credentials that may belong to departed employees who were not fully offboarded. They hold full licence and permission grants.

---

### DS-3 — Profiles With Duplicate or Near-Identical Permission Sets

Look for profiles that are clones of standard profiles with minimal changes — a sign of poor profile hygiene:

**What to query:**
```soql
SELECT Id, Name, Description, UserType, UserLicense.Name
FROM Profile
WHERE UserType = 'Standard'
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY UserLicense.Name, Name
```
Use: `sf data query --target-org <org>`

Then count users per profile:
```soql
SELECT Profile.Name, COUNT(Id) userCount
FROM User
WHERE IsActive = true AND UserType = 'Standard'
GROUP BY Profile.Name
ORDER BY userCount ASC
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Profiles with 0 active users assigned → 🔵 Low per profile (dead configuration, governance debt)
- Profiles with 0 active users AND `PermissionsModifyAllData = true` → 🟡 Medium (dangerous orphaned profile)
- Total custom profile count > 3× number of distinct job functions implied by user count distribution → 🟡 Medium (profile sprawl)
- Profile count ≤ 10 with clear user distribution → ✅ Pass

**Why it matters:** Profile sprawl makes security reviews harder, increases the chance of misconfiguration, and indicates the org has no governance process for access management.

---

### DS-4 — User Licence Consumption

**What to query:**
```soql
SELECT Name, TotalLicenses, UsedLicenses, Status
FROM UserLicense
ORDER BY UsedLicenses DESC
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Any licence type at ≥95% utilisation → 🟡 Medium (capacity risk, not security risk)
- Any licence type at 100% utilisation → 🟠 High (cannot provision emergency/recovery accounts)
- Salesforce or Salesforce Platform licence at 100% → 🟠 High specifically (blocks adding admin recovery accounts)
- Utilisation ≤ 80% → ✅ Pass

**Why it matters:** A fully consumed licence pool means you cannot add emergency admin accounts or onboard replacements during incidents. This is an operational and recovery risk.

---

### DS-5 — Users Assigned Multiple Permission Sets With Elevated Permissions

**What to query:**
```soql
SELECT AssigneeId, Assignee.Name, COUNT(Id) psCount
FROM PermissionSetAssignment
WHERE PermissionSet.IsOwnedByProfile = false
  AND PermissionSet.PermissionsModifyAllData = true
  OR PermissionSet.PermissionsViewAllData = true
GROUP BY AssigneeId, Assignee.Name
HAVING COUNT(Id) > 1
ORDER BY psCount DESC
LIMIT 20
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Any non-admin user with 2+ permission sets each granting `PermissionsModifyAllData` or `PermissionsViewAllData` → 🟠 High (privilege accumulation)
- Any user with >5 permission sets total (regardless of content) → 🟡 Medium (review required)
- No users with stacked elevated permission sets → ✅ Pass

**Why it matters:** Permission set stacking allows users to accumulate privileges that would never be granted if reviewed holistically. Each permission set is often reviewed in isolation, masking the total effective access.

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
 USER & PROFILE MANAGEMENT          [n]/100 [RAG]
 [QUICK SCAN — preliminary] OR [DEEP SCAN — final]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

End with:
```
USER & PROFILE MANAGEMENT SCORE: [n]/100 [RAG]
Weight in global score: 15%
Weighted contribution: [n × 0.15] points
```
