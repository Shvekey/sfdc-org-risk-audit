---
name: trigger-framework-audit
description: Audits a Salesforce org's Apex trigger architecture and framework hygiene. Checks for framework presence and consistency, logic-in-trigger anti-patterns, recursion guards, bypass mechanisms, and trigger handler test quality. Part of the Org Risk Audit (ORA) tool. Weight: 5% of global score.
whenToUse: Invoked by the org-risk-audit master skill for the Trigger Framework domain. Can also be run standalone with /trigger-framework-audit.
---

# ORA — Trigger Framework Audit

> **Domain weight:** 5% of global org risk score
> **MCP servers:** `metadata-experts`
> **Fallback:** `sf data query --use-tooling-api`
> **Scoring contract:** See `ora-scoring-contract`
> **sf-skills (preferred for deep scan):** `dx-code-analyzer-run` (DS-1, DS-3–5), `platform-apex-test-run` (DS-2)

---

## How to Run This Skill

You will be asked two things before the scan begins:
1. Which org to target (alias or username)
2. Scan mode: Quick or Deep (if not already passed by the master skill)

Then work through each check below in order. Collect all findings before calculating the final score.

---

## Quick Scan Checks (run in both modes)

### QS-1 — Trigger Body Complexity (Logic in Trigger)

Retrieve all active trigger bodies:

```soql
SELECT Id, Name, TableEnumOrId, Body, LengthWithoutComments
FROM ApexTrigger
WHERE Status = 'Active'
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY LengthWithoutComments DESC
```
Use: `sf data query --target-org <org> --use-tooling-api`

Evaluate trigger body content:
- **Thin trigger pattern (ideal):** Body contains only a single method dispatch call (e.g. `TriggerHandler.run()`, `AccountTriggerHandler.execute(Trigger.new)`) and nothing else
- **Logic-in-trigger anti-pattern:** Body contains `if`, `for`, SOQL queries, DML, or field assignments directly

**Scoring rules:**
- Trigger body > 30 lines of code (excluding comments and whitespace) → 🟠 High per trigger
- Trigger body > 10 lines AND contains direct SOQL or DML → 🔴 Critical per trigger
- Trigger body ≤ 5 lines and delegates to a handler class → ✅ Pass per trigger
- More than 50% of triggers contain logic directly → 🟠 High (systemic pattern)

**Why it matters:** Logic in trigger bodies is untestable in isolation, unextendable, and the primary source of SOQL-in-loop and recursion bugs. A thin trigger pattern that delegates to a handler class is the industry standard.

---

### QS-2 — Trigger Handler Class Detection

Using the trigger bodies from QS-1, extract the handler class names being called (pattern: class name followed by `.` and a method name in the trigger body). Then verify those handler classes exist:

```soql
SELECT Id, Name, LengthWithoutComments, IsValid
FROM ApexClass
WHERE Status = 'Active'
  AND (Name LIKE '%TriggerHandler%' OR Name LIKE '%Handler%'
       OR Name LIKE '%Trigger%')
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY Name
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- Triggers that reference a handler class that does not exist (invalid reference) → 🔴 Critical per trigger (compile/runtime error)
- Triggers with no identifiable handler pattern and > 10 lines of logic → 🟠 High (covered in QS-1)
- All triggers delegate to valid handler classes → ✅ Pass

---

### QS-3 — Framework Consistency

Check whether a consistent trigger framework is in use across all triggers. A consistent framework means:
- All triggers follow the same dispatch pattern (same base class, same method signature)
- Handler class names follow a convention (`<ObjectName>TriggerHandler`, `<ObjectName>Handler`, etc.)

From the trigger and handler class lists gathered above, evaluate naming consistency and dispatch pattern consistency.

**Scoring rules:**
- Triggers use > 2 distinct dispatch patterns (mixed frameworks) → 🟠 High (multiple frameworks in conflict)
- Some triggers use a framework, some are standalone — mixed approach → 🟡 Medium
- Consistent single framework with uniform naming → ✅ Pass
- No framework at all (all triggers contain logic directly) → 🟠 High (covered also by QS-1)

**Why it matters:** Multiple trigger frameworks in the same org means different teams are operating with different rules, bypasses, and recursion guard mechanisms. Framework conflicts can cause handlers from different frameworks to interfere with each other.

---

### QS-4 — Bypass / Kill Switch Mechanism

Check whether the trigger framework has a bypass or disable mechanism, and whether it is properly secured:

From handler class bodies, look for patterns like:
- `TriggerSettings__c` custom setting checked before execution
- `BypassTrigger__c` or similar fields on User
- Static boolean flags (`TriggerHandler.bypass(...)`)

Then check if the bypass control is accessible to non-admin users:
```soql
SELECT Id, Name, SetupOwnerId, <bypass_field>__c
FROM TriggerSettings__c
LIMIT 10
```
(Adjust object and field names to match what is found in the org.)

**Scoring rules:**
- No bypass mechanism exists → 🟡 Medium (no way to disable a broken trigger in production without a deployment)
- Bypass mechanism exists but is controlled by a hierarchy custom setting accessible to all users → 🟠 High (users can disable their own trigger processing)
- Bypass mechanism is admin-only (protected custom setting or permission-gated) → ✅ Pass
- Bypass mechanism disabled for all triggers in production AND no deployment pipeline to re-enable → 🟡 Medium (stuck if a trigger needs emergency disable)

**Why it matters:** A bypass mechanism is an emergency lever — you need it when a trigger causes a production incident and you cannot wait for a full deployment. But if it is accessible to non-admins, it becomes an attack vector to disable data validation and business rules.

---

## Deep Scan Checks (deep scan mode only)

> **Note:** DS-1, DS-3, DS-4, and DS-5 analyse Apex class bodies. If `dx-code-analyzer-run` (from sf-skills) is available, delegate the body scanning to it rather than querying bodies manually. Use the prompt:
> > "Run Salesforce Code Analyzer on the trigger handler classes in this project. Focus on: recursion without guards, trigger context variable coupling, future/queueable calls without bulkification guards, and cross-trigger field dependencies. Target org: `<org>`."
> Map Code Analyzer findings to ORA severities as defined in `ora-apex-quality`. Fall back to manual Tooling API body retrieval only if sf-skills are unavailable.

---

### DS-1 — Recursion Guard Implementation

Using handler class bodies from QS-2 (or Code Analyzer output), scan for recursion guard patterns. Common correct patterns:
- Static `Set<Id>` or `Boolean` flag checked at the top of the handler before processing
- Check-and-set pattern: `if (processedIds.contains(record.Id)) continue; processedIds.add(record.Id);`

Flag handlers that update the same object they handle without any recursion guard (covered broadly in `ora-automation-health` DS-3, but here assess the code-level pattern).

**Scoring rules:**
- Handler class with no recursion guard AND the trigger fires on `after update` → 🔴 Critical (any update inside the handler re-fires the trigger infinitely)
- Handler class with no recursion guard but trigger only fires on `before insert` (no re-fire risk) → ✅ Pass
- Static boolean guard present but reset incorrectly (reset inside the handler instead of in a test setup) → 🟡 Medium
- Correct check-and-set pattern using a Set of IDs → ✅ Pass

---

### DS-2 — Test Class Coverage of Trigger Handlers

Using the coverage data from `ora-apex-quality` QS-1, extract coverage for the handler classes identified in QS-2:

```soql
SELECT ApexClassOrTrigger.Name, NumLinesCovered, NumLinesUncovered
FROM ApexCodeCoverageAggregate
WHERE ApexClassOrTrigger.Name IN (<handler class names>)
  AND (NamespacePrefix = null OR NamespacePrefix = '')
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- Handler class with < 75% coverage → 🟠 High per class
- Handler class with < 90% coverage → 🟡 Medium per class
- Any handler class with 0% coverage → 🔴 Critical (untested trigger logic in production)
- All handler classes ≥ 90% coverage → ✅ Pass

---

### DS-3 — Trigger Context Variable Usage

Using handler class bodies from QS-2, scan for improper use of trigger context variables:

**Patterns to flag:**
- Direct reference to `Trigger.new` or `Trigger.old` inside a handler class method (context variables should be passed as parameters, not accessed globally — they are null outside trigger context)
- `Trigger.isExecuting` checks inside handler classes (handler should not need to know if it is in trigger context)
- `System.isBatch()` or `System.isFuture()` checks used as a substitute for proper context design

**Scoring rules:**
- Handler class directly referencing `Trigger.new`/`Trigger.old` (not passed as parameter) → 🟡 Medium per class (tightly coupled to trigger context; untestable without trigger invocation)
- Handler class checking `Trigger.isExecuting` → 🟡 Medium
- Context variables correctly passed as parameters to handler methods → ✅ Pass

---

### DS-4 — Future and Queueable Usage in Trigger Context

Using handler class bodies, scan for `@future` method calls or `System.enqueueJob()` inside trigger handler logic:

**Scoring rules:**
- `@future` called from within a trigger handler on every trigger execution without a guard → 🟠 High (exceeds the 50 future calls per transaction limit on bulk operations)
- `System.enqueueJob()` called in a loop or without checking `Limits.getQueueableJobs()` → 🟠 High
- Future/queueable invocations guarded with `if (!System.isFuture() && !System.isBatch())` → 🟡 Medium (correct guard but async chain is hard to test)
- Async calls properly bulkified (one enqueue for the full batch, not per-record) → ✅ Pass

---

### DS-5 — Trigger Order Dependency

Cross-reference the trigger list from `ora-automation-health` QS-1 with handler class bodies. Check whether any handler class explicitly depends on execution order — e.g. reads a field value set by another trigger and assumes it has already run.

**Pattern:** Handler A reads `record.FieldSetByTriggerB__c` and branches on its value. If Trigger B has not fired yet (order not guaranteed), Handler A's logic is wrong.

**Scoring rules:**
- Identifiable cross-trigger field dependency with no guaranteed order → 🟠 High per dependency
- Comment in code acknowledging order dependency ("must run after X") with no enforcement mechanism → 🟡 Medium
- No cross-trigger dependencies identified → ✅ Pass

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
 TRIGGER FRAMEWORK                  [n]/100 [RAG]
 [QUICK SCAN — preliminary] OR [DEEP SCAN — final]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

End with:
```
TRIGGER FRAMEWORK SCORE: [n]/100 [RAG]
Weight in global score: 5%
Weighted contribution: [n × 0.05] points
```
