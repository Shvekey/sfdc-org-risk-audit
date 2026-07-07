---
name: ora-automation-health
description: Audits a Salesforce org's automation health. Checks for redundant/conflicting triggers and flows on the same object, inactive automations consuming metadata limits, Flow interview errors, scheduled job backlog, and Process Builder/Workflow Rule usage requiring migration. Part of the Org Risk Audit (ORA) tool. Weight: 10% of global score.
whenToUse: Invoked by the org-risk-audit master skill for the Automation Health domain. Can also be run standalone with /ora-automation-health.
---

# ORA — Automation Health

> **Domain weight:** 10% of global org risk score
> **MCP servers:** `metadata-experts`, `sobject-reads`
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

### QS-1 — Multiple Triggers on the Same Object

**What to query via Tooling API:**
```soql
SELECT Id, Name, TableEnumOrId, Status, UsageBeforeInsert,
       UsageAfterInsert, UsageBeforeUpdate, UsageAfterUpdate,
       UsageBeforeDelete, UsageAfterDelete
FROM ApexTrigger
WHERE Status = 'Active'
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY TableEnumOrId, Name
```
Use: `sf data query --target-org <org> --use-tooling-api`

Group results by `TableEnumOrId`. Flag any object with more than one active trigger on the same event (e.g. two triggers with `UsageBeforeInsert = true` on the same object).

**Scoring rules:**
- Object with > 2 active triggers firing on the same event → 🔴 Critical (uncontrolled execution order)
- Object with 2 active triggers on the same event → 🟠 High
- Object with multiple triggers but on distinct events → 🟡 Medium (governance concern)
- All objects have at most one trigger per event → ✅ Pass

**Why it matters:** Salesforce does not guarantee execution order between multiple triggers on the same object event. Two triggers can conflict, partially overwrite each other's DML, or cause infinite recursion. Industry best practice is one trigger per object.

---

### QS-2 — Active Process Builders and Workflow Rules

**What to query via Tooling API:**
```soql
SELECT Id, DeveloperName, Status, TriggerType
FROM Flow
WHERE ProcessType IN ('Workflow', 'CustomEvent')
  AND Status = 'Active'
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY DeveloperName
```
Also count legacy Workflow Rules via metadata (if accessible):
```soql
SELECT Id, Name, TableEnumOrId
FROM WorkflowRule
WHERE (NamespacePrefix = null OR NamespacePrefix = '')
```
Use: `sf data query --target-org <org> --use-tooling-api`

Note: `WorkflowRule` may not be directly queryable via SOQL in all orgs. If unavailable, use Metadata API retrieve or note as manual check.

**Scoring rules:**
- Any active Process Builder flows → 🟠 High (Salesforce has announced retirement; each one is a migration liability)
- Active Workflow Rules > 10 → 🟠 High
- Active Workflow Rules 1–10 → 🟡 Medium
- No active Process Builders or Workflow Rules → ✅ Pass

**Why it matters:** Salesforce has retired Workflow Rules and Process Builder in favour of Flow. Active legacy automations represent unplanned migration work and have known limitations (no bulk support, governor limit exposure).

---

### QS-3 — Flow Interview Errors (Recent)

**What to query:**
```soql
SELECT Id, FlowVersionId, InterviewLabel, CurrentElement,
       ErrorMessage, CreatedDate
FROM FlowInterviewLog
WHERE CreatedDate = LAST_N_DAYS:30
  AND ErrorMessage != null
ORDER BY CreatedDate DESC
LIMIT 50
```
Use: `sf data query --target-org <org>`

Note: `FlowInterviewLog` requires the org to have Flow error logging enabled. If the object is not queryable, check `FlowInterviewLogEntry` or note as `⏭️ SKIPPED`.

**Scoring rules:**
- Same flow failing > 10 times in 30 days → 🟠 High per flow
- Any flow failure that affects a record-triggered flow on a core object (Account, Contact, Opportunity, Case) → 🟠 High
- Total flow errors > 50 in 30 days → 🟡 Medium
- Zero flow errors in 30 days → ✅ Pass

**Why it matters:** Flow errors cause record saves to fail silently (in autolaunched flows with fault paths) or visibly (in screen flows). Repeated failures indicate broken business logic in production.

---

### QS-4 — Scheduled Flow and Batch Job Backlog

**What to query:**
```soql
SELECT Id, ApexClass.Name, JobType, Status, JobItemsProcessed,
       TotalJobItems, NumberOfErrors, CreatedDate, CompletedDate
FROM AsyncApexJob
WHERE Status IN ('Queued', 'Holding')
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY CreatedDate ASC
LIMIT 50
```
Use: `sf data query --target-org <org>`

Also check scheduled flows:
```soql
SELECT Id, FlowVersionId, Status, StartDate, InterviewLabel
FROM FlowInterview
WHERE Status = 'Waiting'
ORDER BY StartDate ASC
LIMIT 50
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Queued/Holding batch jobs > 20 → 🟠 High (Apex flex queue backlog indicating processing delays)
- Same batch job queued > 5 times (stuck re-queue pattern) → 🟠 High
- Scheduled flow interviews > 100 in Waiting state → 🟡 Medium
- Queued jobs ≤ 5 → ✅ Pass

**Why it matters:** A backlogged Apex flex queue means scheduled business processes are not running on time. More than 100 jobs in the Holding state indicates the org's async processing is overwhelmed.

---

### QS-5 — Inactive Flows Consuming Version Limits

**What to query via Tooling API:**
```soql
SELECT DeveloperName, COUNT(Id) versionCount,
       MAX(VersionNumber) latestVersion
FROM Flow
WHERE ProcessType NOT IN ('Login', 'Logout')
  AND (NamespacePrefix = null OR NamespacePrefix = '')
GROUP BY DeveloperName
ORDER BY versionCount DESC
LIMIT 20
```
Use: `sf data query --target-org <org> --use-tooling-api`

Also count total inactive flow versions:
```soql
SELECT COUNT(Id) inactiveCount
FROM Flow
WHERE Status = 'Obsolete'
  AND (NamespacePrefix = null OR NamespacePrefix = '')
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- Any single flow with > 50 obsolete versions → 🟡 Medium (governance/maintenance debt)
- Total obsolete flow versions > 500 → 🟡 Medium
- Total obsolete flow versions > 1000 → 🟠 High (approaching metadata limits)
- Obsolete versions ≤ 100 → ✅ Pass

**Why it matters:** Salesforce orgs have metadata limits on the number of flow versions. Accumulating thousands of obsolete versions can cause deployments to fail and slows Flow Builder in the UI.

---

## Deep Scan Checks (deep scan mode only)

### DS-1 — Flow and Trigger Conflicts on the Same Object

Using triggers from QS-1 and flows from the org, identify objects that have both active triggers AND active record-triggered flows firing on the same event:

**What to query via Tooling API:**
```soql
SELECT Id, DeveloperName, TriggerOrder, TriggerType,
       RecordTriggerType, ProcessType, Status
FROM Flow
WHERE ProcessType = 'AutoLaunchedFlow'
  AND TriggerType = 'RecordBeforeSave'
  AND Status = 'Active'
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY DeveloperName
```
Use: `sf data query --target-org <org> --use-tooling-api`

Cross-reference with trigger list from QS-1. Flag objects with both a trigger and a before-save flow that both perform field updates (potential conflicts).

**Scoring rules:**
- Object with both a before-save flow AND a trigger that updates the same fields → 🟠 High (race condition / overwrite risk)
- Object with before-save flow AND trigger with no apparent conflict → 🟡 Medium (complexity risk, document execution order)
- Clean separation between trigger and flow responsibilities → ✅ Pass

---

### DS-2 — Flows With No Fault Path on DML Operations

Retrieve flow metadata for record-triggered flows that perform DML (Create/Update/Delete Records elements) and check whether a Fault connector is configured:

**What to query via Tooling API:**
```soql
SELECT Id, DeveloperName, Metadata
FROM Flow
WHERE ProcessType = 'AutoLaunchedFlow'
  AND Status = 'Active'
  AND (NamespacePrefix = null OR NamespacePrefix = '')
```
Use: `sf data query --target-org <org> --use-tooling-api`

Parse the `Metadata` field (Flow XML) and check: for each `recordCreates`, `recordUpdates`, `recordDeletes` element, verify there is a `faultConnector` defined.

**Scoring rules:**
- Record-triggered flow with DML element and no fault path → 🟠 High per flow (uncaught DML errors surface as cryptic page errors to users)
- Screen flow with DML element and no fault path → 🟡 Medium
- All DML elements have fault paths → ✅ Pass

**Why it matters:** Without a fault path, any DML error in a flow causes the entire transaction to fail with a generic error message. Users cannot understand what went wrong, and admins have no logging to diagnose it.

---

### DS-3 — Recursive Flow / Trigger Detection

Using flow metadata from DS-2, check for flows that update the same object they are triggered by without a recursion guard:

**Pattern:** A record-triggered flow on Object X contains a `recordUpdates` element targeting Object X, and there is no custom field used as a recursion guard (a boolean field set to true before the update and checked at the flow entry decision).

**Scoring rules:**
- Flow updates same object it triggers on with no recursion guard → 🔴 Critical (can cause infinite loop until governor limit hit)
- Flow updates a related object that has its own flow back to the original object → 🟠 High (cross-object recursion)
- Recursion guard present and correctly structured → ✅ Pass

**Why it matters:** Recursive flows hit the 2,000 flow interview limit per transaction, failing the record save. In the worst case, they cause cascading failures across all records in a bulk operation.

---

### DS-4 — Scheduled Jobs Without Error Notification

**What to query:**
```soql
SELECT Id, CronJobDetail.Name, CronJobDetail.JobType,
       State, NextFireTime, PreviousFireTime, TimesTriggered
FROM CronTrigger
WHERE State IN ('ACQUIRED', 'WAITING', 'PAUSED', 'ERROR')
ORDER BY NextFireTime ASC
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Any scheduled job in `ERROR` state → 🟠 High per job
- Any scheduled job in `PAUSED` state not paused intentionally (cross-reference recent deployments) → 🟡 Medium
- Scheduled jobs with `TimesTriggered = 0` and `PreviousFireTime = null` that were created > 7 days ago → 🟡 Medium (never ran)
- All scheduled jobs in `WAITING` state with recent `PreviousFireTime` → ✅ Pass

---

### DS-5 — Flow API Version Staleness

Using flow metadata from DS-2, check the `ApiVersion` field for active flows:

**Scoring rules:**
- Active flows with `ApiVersion` < 50.0 (Summer '20) → 🟠 High per flow (pre-dates major Flow improvements; likely using deprecated elements)
- Active flows with `ApiVersion` < 55.0 (Summer '22) → 🟡 Medium
- Active flows with `ApiVersion` more than 6 versions behind current → 🟡 Medium
- All active flows within 3 API versions of current → ✅ Pass

**Why it matters:** Stale API versions mean flows are using older element behaviour and may not benefit from bug fixes and performance improvements introduced in newer releases. Salesforce occasionally deprecates old element behaviour without backporting fixes to older API versions.

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
 AUTOMATION HEALTH                  [n]/100 [RAG]
 [QUICK SCAN — preliminary] OR [DEEP SCAN — final]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

End with:
```
AUTOMATION HEALTH SCORE: [n]/100 [RAG]
Weight in global score: 10%
Weighted contribution: [n × 0.10] points
```
