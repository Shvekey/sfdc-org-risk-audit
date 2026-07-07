---
name: ora-data-model
description: Audits a Salesforce org's data model architecture and quality. Checks for field sprawl, lookup vs master-detail misuse, deprecated field types, object and field limit headroom, missing descriptions, and long-text field overuse. Part of the Org Risk Audit (ORA) tool. Weight: 10% of global score.
whenToUse: Invoked by the org-risk-audit master skill for the Data Model & Architecture domain. Can also be run standalone with /ora-data-model.
---

# ORA — Data Model & Architecture

> **Domain weight:** 10% of global org risk score
> **MCP servers:** `metadata-experts`, `salesforce-api-context`
> **Fallback:** `sf data query --use-tooling-api`
> **Scoring contract:** See `ora-scoring-contract`

---

## How to Run This Skill

You will be asked two things before the scan begins:
1. Which org to target (alias or username)
2. Scan mode: Quick or Deep (if not already passed by the master skill)

Then work through each check below in order. Collect all findings before calculating the final score.

---

## Quick Scan Checks (run in both modes)

### QS-1 — Custom Object and Field Limit Headroom

**What to query via Tooling API:**
```soql
SELECT QualifiedApiName, Label, IsCustomizable, IsDeprecatedAndHidden
FROM EntityDefinition
WHERE IsCustomizable = true
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY QualifiedApiName
```
Use: `sf data query --target-org <org> --use-tooling-api`

Count total custom objects (names ending in `__c`). Enterprise Edition limit is 800 custom objects. Check the Limits API for `CustomTabsInApp` or retrieve object count from `sf org display`.

Also count custom fields across core objects:
```soql
SELECT EntityDefinition.QualifiedApiName, COUNT(Id) fieldCount
FROM FieldDefinition
WHERE EntityDefinition.IsCustomizable = true
  AND IsCustom = true
  AND (NamespacePrefix = null OR NamespacePrefix = '')
GROUP BY EntityDefinition.QualifiedApiName
ORDER BY fieldCount DESC
LIMIT 20
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- Custom object count > 90% of org limit → 🔴 Critical
- Custom object count > 75% of org limit → 🟠 High
- Any single object with > 500 custom fields → 🟠 High (approaching per-object limit of ~800 depending on edition)
- Any single object with > 350 custom fields → 🟡 Medium
- Object and field counts < 75% of limits → ✅ Pass

**Why it matters:** Hitting custom object or field limits causes deployments to fail. Orgs that approach limits unexpectedly face emergency data model restructuring or costly licence upgrades.

---

### QS-2 — Fields With No Description

**What to query via Tooling API:**
```soql
SELECT QualifiedApiName, EntityDefinition.QualifiedApiName,
       Label, DataType, Description
FROM FieldDefinition
WHERE IsCustom = true
  AND Description = null
  AND EntityDefinition.IsCustomizable = true
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY EntityDefinition.QualifiedApiName, QualifiedApiName
LIMIT 50
```
Use: `sf data query --target-org <org> --use-tooling-api`

Count the total, then sample the first 50 for reporting.

**Scoring rules:**
- > 80% of custom fields have no description → 🟡 Medium (systemic documentation gap)
- > 50% of custom fields have no description → 🔵 Low
- Custom fields on core objects (Account, Contact, Lead, Opportunity, Case) without descriptions > 50% → 🟡 Medium
- All custom fields documented → ✅ Pass

**Why it matters:** Undocumented fields become unmaintainable. Teams are afraid to delete them (unknown impact), developers guess their purpose, and data migration projects become high-risk archaeology exercises.

---

### QS-3 — Deprecated or Unused Custom Fields (Heuristic)

**What to query via Tooling API:**
```soql
SELECT QualifiedApiName, Label, DataType, IsDeprecatedAndHidden,
       EntityDefinition.QualifiedApiName
FROM FieldDefinition
WHERE IsCustom = true
  AND IsDeprecatedAndHidden = true
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY EntityDefinition.QualifiedApiName
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- Any deprecated-and-hidden fields present → 🔵 Low per field (these count against field limits but are inaccessible)
- More than 20 deprecated-and-hidden fields → 🟡 Medium
- Zero deprecated-and-hidden fields → ✅ Pass

Note: True "unused" field detection requires checking field references in Apex, Flows, reports, and page layouts — covered in DS-2.

---

### QS-4 — Record Type Sprawl

**What to query:**
```soql
SELECT SobjectType, COUNT(Id) rtCount
FROM RecordType
WHERE IsActive = true
  AND (NamespacePrefix = null OR NamespacePrefix = '')
GROUP BY SobjectType
ORDER BY rtCount DESC
LIMIT 20
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Any object with > 20 active record types → 🟡 Medium (complexity risk)
- Any object with > 50 active record types → 🟠 High
- Total active record types across all objects > 200 → 🟡 Medium
- Objects with ≤ 10 record types each → ✅ Pass

**Why it matters:** Record type sprawl indicates data model complexity was used as a substitute for proper object modelling. It makes page layout management, validation rules, and reporting significantly more complex.

---

### QS-5 — External ID Fields

**What to query via Tooling API:**
```soql
SELECT QualifiedApiName, Label, DataType, IsExternalId, IsUnique,
       EntityDefinition.QualifiedApiName
FROM FieldDefinition
WHERE IsCustom = true
  AND IsExternalId = true
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY EntityDefinition.QualifiedApiName
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- External ID field that is not also marked `IsUnique = true` → 🟠 High (non-unique external IDs break upsert operations)
- More than 3 external ID fields on a single object → 🟡 Medium (limit is typically 3 indexed external IDs per object)
- External ID fields present and correctly configured → ✅ Pass

**Why it matters:** Non-unique external ID fields cause upsert operations to fail when duplicate values exist. Exceeding the external ID index limit causes Salesforce to silently stop indexing additional fields, degrading query performance.

---

## Deep Scan Checks (deep scan mode only)

### DS-1 — Master-Detail vs Lookup Relationship Appropriateness

**What to query via Tooling API:**
```soql
SELECT QualifiedApiName, Label, DataType, RelationshipName,
       ReferenceTo, EntityDefinition.QualifiedApiName
FROM FieldDefinition
WHERE IsCustom = true
  AND DataType IN ('MasterDetail', 'Lookup')
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY EntityDefinition.QualifiedApiName
```
Use: `sf data query --target-org <org> --use-tooling-api`

Evaluate: Master-detail relationships enforce cascade delete and roll-up summary support. Lookups are optional references. Flag cases where a lookup is likely a design error:
- Lookup to User or Profile on a transactional object where the relationship is actually required (should be master-detail)
- Master-detail used where the child can exist independently (wrong cascade semantics)

**Scoring rules:**
- Required lookup fields (where 90%+ of records have values) that are not master-detail → 🔵 Low per relationship (missed roll-up summary capability)
- Master-detail to a non-standard object where cascade-delete is clearly unintended → 🟡 Medium
- More than 2 master-detail relationships on a single object → 🟡 Medium (limit is 2 master-detail fields per object)
- Relationships are appropriately typed → ✅ Pass

---

### DS-2 — Fields Referenced Nowhere (Dead Field Detection)

For the 20 most-populated custom objects, check which custom fields are not referenced in:
- Any active Apex class or trigger body (from `ora-apex-quality` DS-1 corpus)
- Any active Flow metadata
- Any active Validation Rule
- Any active Report (heuristic — not always queryable)

**What to query via Tooling API:**
```soql
SELECT Id, QualifiedApiName, EntityDefinition.QualifiedApiName, Label, DataType
FROM FieldDefinition
WHERE IsCustom = true
  AND (NamespacePrefix = null OR NamespacePrefix = '')
  AND EntityDefinition.QualifiedApiName IN (
    'Account', 'Contact', 'Lead', 'Opportunity', 'Case'
  )
ORDER BY EntityDefinition.QualifiedApiName, QualifiedApiName
```
Use: `sf data query --target-org <org> --use-tooling-api`

Cross-reference field API names against Apex class bodies and Flow metadata strings. Fields not found in any reference are candidate dead fields.

**Scoring rules:**
- More than 30 unreferenced custom fields on core objects → 🟡 Medium
- More than 100 unreferenced custom fields across the org → 🟠 High (field limit consumption with no value)
- Unreferenced fields present but fewer than 30 → 🔵 Low
- All fields referenced in at least one automation or code asset → ✅ Pass

**Why it matters:** Dead fields consume field limits, slow page loads, clutter page layouts, confuse users, and make data migration projects harder. Orgs accumulate them rapidly when deletions are never governed.

---

### DS-3 — Long Text Area Overuse

**What to query via Tooling API:**
```soql
SELECT QualifiedApiName, Label, DataType, Length,
       EntityDefinition.QualifiedApiName
FROM FieldDefinition
WHERE IsCustom = true
  AND DataType IN ('LongTextArea', 'Html')
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY EntityDefinition.QualifiedApiName, Length DESC
```
Use: `sf data query --target-org <org> --use-tooling-api`

**Scoring rules:**
- Long text area fields configured with max length (131,072 chars) on a high-volume object (> 100K records) → 🟡 Medium (storage inflation)
- More than 10 long text area or rich text fields on a single object → 🟡 Medium
- Rich text (HTML) fields exposed to users who can paste content → 🟡 Medium (stored XSS vector if not sanitised on rendering)
- Long text fields used judiciously → ✅ Pass

**Why it matters:** Rich text fields are a stored XSS vector if content is rendered without sanitisation in custom Visualforce or LWC components. Long text area fields with max length on high-volume objects inflate data storage costs significantly.

---

### DS-4 — Formula Field Complexity

**What to query via Tooling API:**
```soql
SELECT QualifiedApiName, Label, DataType, EntityDefinition.QualifiedApiName,
       Metadata
FROM FieldDefinition
WHERE IsCustom = true
  AND DataType LIKE '%Formula%'
  AND (NamespacePrefix = null OR NamespacePrefix = '')
ORDER BY EntityDefinition.QualifiedApiName
LIMIT 50
```
Use: `sf data query --target-org <org> --use-tooling-api`

Parse `Metadata` to get the formula body. Flag formulas that:
- Reference more than 5 cross-object hops (e.g. `Account.Owner.Manager.Department`)
- Contain nested `IF` statements more than 3 levels deep

**Scoring rules:**
- Formula with > 5 cross-object hops → 🟠 High per field (each hop is a query; formula fields on large objects cause severe performance degradation)
- Formula with > 3 nested IFs → 🟡 Medium
- Formulas referencing deleted or renamed fields (invalid formulas) → 🟠 High
- All formulas simple and valid → ✅ Pass

**Why it matters:** Cross-object formula fields generate SOQL under the hood for every record load. On objects with millions of records, deeply nested cross-object formulas cause list view and report timeouts.

---

### DS-5 — Validation Rule Count and Complexity

**What to query:**
```soql
SELECT EntityDefinition.QualifiedApiName, COUNT(Id) ruleCount
FROM ValidationRule
WHERE Active = true
  AND (NamespacePrefix = null OR NamespacePrefix = '')
GROUP BY EntityDefinition.QualifiedApiName
ORDER BY ruleCount DESC
LIMIT 20
```
Use: `sf data query --target-org <org>`

**Scoring rules:**
- Any single object with > 20 active validation rules → 🟡 Medium (complexity risk; rules execute serially on save)
- Any single object with > 50 active validation rules → 🟠 High (performance and maintainability concern)
- Total active validation rules across org > 500 → 🟡 Medium
- Validation rule counts reasonable per object → ✅ Pass

**Why it matters:** Validation rules execute synchronously on every record save. Too many rules on high-volume objects degrade DML performance. Rules that overlap or contradict each other create support nightmares when users cannot save records.

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
 DATA MODEL & ARCHITECTURE          [n]/100 [RAG]
 [QUICK SCAN — preliminary] OR [DEEP SCAN — final]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

End with:
```
DATA MODEL & ARCHITECTURE SCORE: [n]/100 [RAG]
Weight in global score: 10%
Weighted contribution: [n × 0.10] points
```
