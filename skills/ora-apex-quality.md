---
name: ora-apex-quality
description: Audits a Salesforce org's Apex code quality and safety. Checks for SOQL/DML in loops, missing bulkification, test coverage gaps, active debug logs, hardcoded IDs, and unsafe dynamic Apex patterns. Part of the Org Risk Audit (ORA) tool. Weight: 15% of global score.
whenToUse: Invoked by the org-risk-audit master skill for the Apex Code Quality domain. Can also be run standalone with /ora-apex-quality.
---

# ORA — Apex Code Quality

> **Domain weight:** 15% of global org risk score
> **MCP servers:** `metadata-experts`, `sobject-reads`
> **Fallback:** `sf data query --use-tooling-api` / `sf data query`
> **Scoring contract:** See `ora-scoring-contract`
> **sf-skills (preferred):** `platform-apex-test-run` (QS-1), `platform-apex-logs-debug` (QS-2), `dx-code-analyzer-run` (DS-1–5)

---

## How to Run This Skill

You will be asked two things before the scan begins:
1. Which org to target (alias or username)
2. Scan mode: Quick or Deep (if not already passed by the master skill)

Then work through each check below in order. Collect all findings before calculating the final score.

---

## Quick Scan Checks (run in both modes)

### QS-1 — Overall Apex Test Coverage

**Preferred method — delegate to `platform-apex-test-run`:**

Invoke the `platform-apex-test-run` sf-skill to retrieve coverage data. It runs `sf apex run test --code-coverage --result-format json` and returns structured per-class and org-wide coverage results. Use its output directly for scoring — no additional queries needed.

**Fallback (if sf-skills not available):**
```soql
SELECT PercentCovered
FROM ApexOrgWideCoverage
```
Use: `sf data query --target-org <org> --use-tooling-api`

Also get class-level breakdown for the lowest-covered classes:
```soql
SELECT ApexClassOrTrigger.Name, NumLinesCovered, NumLinesUncovered
FROM ApexCodeCoverageAggregate
WHERE (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY NumLinesUncovered DESC
LIMIT 20
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- Org-wide coverage < 75% → 🔴 Critical (below Salesforce deployment threshold)
- Org-wide coverage 75–84% → 🟠 High (at the legal minimum but insufficient for production confidence)
- Org-wide coverage 85–94% → 🟡 Medium
- Any individual class with 0% coverage AND > 50 lines → 🟠 High per class
- Org-wide coverage ≥ 95% → ✅ Pass

**Why it matters:** Test coverage is the primary signal of code reliability. Low coverage means untested code paths run in production, and deployments are fragile — a single new test failure can lock the org.

---

### QS-2 — Active Apex Debug Logs

**Preferred method — delegate to `platform-apex-logs-debug`:**

Invoke the `platform-apex-logs-debug` sf-skill. It retrieves active `TraceFlag` records, analyses log levels, and identifies long-running or sensitive traces. Use its structured findings directly for scoring.

**Fallback (if sf-skills not available):**
```soql
SELECT Id, TracedEntityId, TracedEntity.Name,
       LogType, ExpirationDate, DebugLevel.DeveloperName,
       DebugLevel.ApexCode, DebugLevel.Database
FROM TraceFlag
WHERE ExpirationDate > TODAY
ORDER BY ExpirationDate DESC
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Any active `TraceFlag` with `DebugLevel.ApexCode = 'FINEST'` or `'FINE'` → 🟠 High (verbose logging degrades performance and may expose sensitive data in logs)
- Active trace flags on integration or admin users → 🟠 High
- Active trace flags with expiration > 7 days from today → 🟡 Medium
- More than 5 active trace flags in total → 🟡 Medium
- No active trace flags → ✅ Pass

**Why it matters:** Debug logs at FINEST level capture full query results, variable values, and DML row contents. Left active in production they create a data exposure risk and degrade governor limit headroom for real traffic.

---

### QS-3 — Apex Classes With No Test Coverage (Heuristic)

Using the coverage aggregate from QS-1, identify production classes (no `Test` suffix/prefix in name) with zero lines covered:

**What to query via Tooling API:**
```soql
SELECT ApexClassOrTrigger.Name, NumLinesCovered, NumLinesUncovered
FROM ApexCodeCoverageAggregate
WHERE NumLinesCovered = 0
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY NumLinesUncovered DESC
LIMIT 20
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- Production classes with 0 lines covered AND > 100 lines of code → 🟠 High per class (up to 3; if >3 classes escalate to 🔴 Critical)
- Production classes with 0 lines covered AND 10–100 lines → 🟡 Medium per class
- All production classes with at least some coverage → ✅ Pass

---

### QS-4 — Invalid or Inactive Apex Classes

**What to query via Tooling API:**
```soql
SELECT Id, Name, Status, IsValid, LengthWithoutComments
FROM ApexClass
WHERE (Status != 'Active' OR IsValid = false)
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY Name
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- Any `IsValid = false` class → 🟠 High per class (compile error in production)
- More than 5 invalid classes → 🔴 Critical (systemic compilation failures)
- All classes valid and active → ✅ Pass

**Why it matters:** Invalid Apex classes indicate the org has compilation errors in production. This blocks future deployments and indicates the org metadata is inconsistent.

---

### QS-5 — Recent Apex Job Failures

**What to query:**
```soql
SELECT Id, ApexClass.Name, JobType, Status, ExtendedStatus,
       NumberOfErrors, TotalJobItems, CompletedDate
FROM AsyncApexJob
WHERE Status = 'Failed'
  AND CompletedDate = LAST_N_DAYS:30
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY CompletedDate DESC
LIMIT 20
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Same class failing ≥ 3 times in 30 days → 🟠 High
- Total failed jobs > 10 in 30 days → 🟡 Medium
- Any job with `NumberOfErrors` > 0 AND `TotalJobItems` > 100 (bulk failure) → 🟠 High
- Zero failed jobs in 30 days → ✅ Pass

**Why it matters:** Repeated async job failures mean business logic is silently broken in production. Failed batches often mean records are not being processed, integrations are broken, or data is accumulating in an error state.

---

## Deep Scan Checks (deep scan mode only)

### DS-1–5 — Apex Code Analysis via Salesforce Code Analyzer

**Preferred method — delegate to `dx-code-analyzer-run`:**

This single sf-skill replaces the five manual body-scan checks below. It uses AST-based static analysis (not regex heuristics) and produces structured, accurate findings with file/line evidence.

**Setup (if not already configured):** First invoke `dx-code-analyzer-configure` to ensure a `code-analyzer.yml` exists for the org's Apex project directory. This is a one-time step.

**Run the scan:**

Invoke `dx-code-analyzer-run` targeting the org's Apex source directory, scoped to the rules that map to our five checks:

| Our Check | Code Analyzer Engine | Rule / Category |
|---|---|---|
| DS-1: SOQL in loops | SFGE | `ApexFlsViolationRule` / `PerformanceRules` |
| DS-2: DML in loops | SFGE | `PerformanceRules` |
| DS-3: Hardcoded IDs | PMD | `ApexSuspiciousCode` / `HardcodedId` |
| DS-4: SOQL injection | PMD, SFGE | `ApexSecurityRules` / `ApexSoqlInjection` |
| DS-5: `without sharing` | PMD | `ApexSecurityRules` / `ApexSharingViolations` |

Suggested invocation context for `dx-code-analyzer-run`:
> Run Salesforce Code Analyzer on the Apex classes and triggers in this org's source directory. Focus on: SOQL in loops, DML in loops, hardcoded Salesforce IDs, SOQL injection via unsanitised dynamic queries, and `without sharing` classes in trigger context. Target org: `<org>`. Include fixes where available.

Map Code Analyzer severity levels to ORA severities:
- Code Analyzer **Critical** → 🔴 Critical
- Code Analyzer **High** → 🟠 High
- Code Analyzer **Moderate** → 🟡 Medium
- Code Analyzer **Low** → 🔵 Low

**Scoring rules** (applied to Code Analyzer output):

*DS-1 — SOQL in loops:*
- Violation in a trigger file → 🔴 Critical per trigger
- Violation in a non-trigger class → 🟠 High per class
- No violations → ✅ Pass

*DS-2 — DML in loops:*
- Violation in a trigger file → 🔴 Critical per trigger
- Violation in a class called from trigger context → 🔴 Critical
- Violation in a standalone class → 🟠 High
- No violations → ✅ Pass

*DS-3 — Hardcoded IDs:*
- Violation in a trigger file → 🔴 Critical
- Violation in a production class → 🟠 High per class
- Violation in a test class only → 🟡 Medium
- No violations → ✅ Pass

*DS-4 — SOQL injection:*
- Unsanitised dynamic SOQL → 🔴 Critical per instance
- Concatenated query with escaping present → 🟡 Medium
- No violations → ✅ Pass

*DS-5 — `without sharing` in trigger context:*
- `without sharing` class with DML, invoked from trigger → 🔴 Critical
- `without sharing` class invoked from trigger, no DML → 🟠 High
- `without sharing` in batch/scheduled-only context → 🔵 Low
- No violations → ✅ Pass

---

**Fallback (if sf-skills or a local Apex project directory are not available):**

Retrieve Apex class and trigger bodies via Tooling API and apply manual heuristic scanning:

```soql
SELECT Id, Name, Body
FROM ApexClass
WHERE Status = 'Active'
  AND (NamespacePrefix = null OR NamespacePrefix = '')
  AND Name NOT LIKE '%Test%'
  AND Name NOT LIKE 'Test%'
```
```soql
SELECT Id, Name, Body
FROM ApexTrigger
WHERE Status = 'Active'
  AND (NamespacePrefix = null OR NamespacePrefix = '')
```
Use: `sf data query --target-org <org> --use-tooling-api`

Apply pattern matching for each of DS-1 through DS-5 as described above. Mark all findings from the fallback path with `[heuristic — confirm manually]` in the evidence field, since body-text regex cannot confirm loop nesting or call graph depth.

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
 APEX CODE QUALITY                  [n]/100 [RAG]
 [QUICK SCAN — preliminary] OR [DEEP SCAN — final]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

End with:
```
APEX CODE QUALITY SCORE: [n]/100 [RAG]
Weight in global score: 15%
Weighted contribution: [n × 0.15] points
```
