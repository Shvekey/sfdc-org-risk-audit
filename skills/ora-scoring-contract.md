---
name: ora-scoring-contract
description: Shared scoring conventions, severity definitions, output formatting template, RAG thresholds, domain weights, and MCP fallback rules used by all Salesforce Org Risk Audit sub-skills. This is not an executable skill — it is a reference standard every sub-skill must conform to.
---

# ORA Scoring Contract

This document defines the shared standards all sub-skills in the Salesforce Org Risk Audit (ORA) tool must follow. Read this before building or modifying any sub-skill.

---

## 1. Severity Levels

Every finding must be assigned one of four severity levels:

| Level | Label | Definition |
|---|---|---|
| 🔴 | **Critical** | Represents an immediate, exploitable risk or a severe implementation flaw with potential for data loss, breach, or regulatory non-compliance. Must be addressed before go-live or as an emergency in production. |
| 🟠 | **High** | Significant risk or best-practice violation that materially increases attack surface or technical debt. Should be addressed within the current sprint or release cycle. |
| 🟡 | **Medium** | Moderate risk or implementation gap. Not immediately dangerous but creates cumulative exposure over time. Should be addressed within the quarter. |
| 🔵 | **Low** | Minor deviation from best practice. Low blast radius. Recommended to address in regular maintenance cycles. |

---

## 2. Score Deduction Table

Each domain starts at **100**. Findings deduct points based on severity. Domain score floor is **0** (cannot go negative).

| Severity | Points Deducted Per Finding | Max Deduction Per Finding Type |
|---|---|---|
| Critical | -25 | No cap — each Critical finding costs 25 points |
| High | -12 | No cap |
| Medium | -5 | No cap |
| Low | -2 | No cap |

**Example:** A domain with 2 Critical + 1 High + 3 Medium findings scores:
`100 - (2×25) - (1×12) - (3×5) = 100 - 50 - 12 - 15 = 23/100 🔴`

Sub-skills must calculate and display the domain score using this exact formula.

---

## 3. RAG Thresholds

Applied to both individual domain scores and the global consolidated score.

| Score Range | RAG | Label |
|---|---|---|
| 86 – 100 | 🟢 | Green — Healthy |
| 56 – 85 | 🟡 | Amber — Needs Attention |
| 0 – 55 | 🔴 | Red — Critical Risk |

---

## 4. Domain Weights (Global Score)

The master skill calculates a weighted average of all domain scores for the overall org risk score.

| Domain | Sub-Skill | Weight |
|---|---|---|
| Security & Access Control | `ora-security-access` | 20% |
| Authentication & Identity | `ora-auth-identity` | 15% |
| User & Profile Management | `ora-user-profile` | 15% |
| Apex Code Quality | `ora-apex-quality` | 15% |
| Automation Health | `ora-automation-health` | 10% |
| Org Configuration & Health | `ora-org-config` | 10% |
| Data Model & Architecture | `ora-data-model` | 10% |
| Trigger Framework | `trigger-framework-audit` | 5% |
| **Total** | | **100%** |

**Global score formula:**
```
global_score = (security×0.20) + (auth×0.15) + (users×0.15) + (apex×0.15)
             + (automation×0.10) + (config×0.10) + (datamodel×0.10) + (triggers×0.05)
```

---

## 5. Scan Modes

Every sub-skill must support two modes. The master skill passes the mode as context when invoking each sub-skill.

### Quick Scan
- Metadata counts and existence checks only
- No Apex/Flow body parsing
- No record-level population queries
- Completes in seconds
- Produces a **preliminary score** with reduced confidence
- Mark preliminary scores with: `[QUICK SCAN — preliminary]`

### Deep Scan
- Full metadata body analysis (Apex, Flow XML, Profiles, Permission Sets)
- Record-level queries where relevant (user counts, active debug logs, etc.)
- Complete finding list with evidence
- Produces the **final score**
- Mark final scores with: `[DEEP SCAN — final]`

Checks that are inherently deep (e.g. reading Apex class bodies) should only run in deep scan mode and must be skipped — not estimated — in quick scan mode.

---

## 6. Output Format (per sub-skill)

Every sub-skill must produce output in this exact structure:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 [DOMAIN NAME]                    [SCORE]/100 [RAG]
 [SCAN MODE label]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔴 CRITICAL FINDINGS ([n])
  ┌─ [Finding Title]
  │  What:   [concise description of what was found]
  │  Risk:   [why this is dangerous]
  │  Fix:    [specific remediation step]
  └─ Evidence: [query result, count, or field value that triggered this]

🟠 HIGH FINDINGS ([n])
  [same structure]

🟡 MEDIUM FINDINGS ([n])
  [same structure]

🔵 LOW FINDINGS ([n])
  [same structure]

✅ CHECKS PASSED ([n])
  - [check name]: [one-line confirmation]

[DOMAIN NAME] SCORE: [n]/100 [RAG emoji]
Weight in global score: [x]%
Weighted contribution: [n × weight] points
```

If a domain has zero findings at a severity level, omit that section entirely. Do not print empty sections.

---

## 7. MCP Server Usage & Fallback Convention

Sub-skills must attempt MCP tools first. If an MCP tool is unavailable or returns an error, fall back to `sf` CLI and annotate the output.

| MCP Server | Primary Use | Fallback |
|---|---|---|
| `sobject-reads` | Query org records (Users, DebugLevels, AsyncApexJob, etc.) | `sf data query --target-org <org>` |
| `salesforce-api-context` | Connected Apps, SSO, session settings, CORS, CSP, Named Credentials | `sf data query --use-tooling-api` |
| `metadata-experts` | Apex bodies, Flow metadata, Triggers, Profiles, Permission Sets, Fields | `sf data query --use-tooling-api` |
| `data-cloud-queries` | Data Cloud segments and objects | Skip with note if unavailable — Data Cloud may not be provisioned |

When falling back, add this inline warning in output:
```
⚠️  MCP unavailable ([server-name]) — used sf CLI fallback. Results may be incomplete.
```

When a check cannot be completed via either method, mark it:
```
⏭️  SKIPPED: [check name] — [reason]
```

---

## 8. Managed Package Exclusion

All sub-skills must exclude managed package components from analysis. A component belongs to a managed package if its `NamespacePrefix` is non-null and non-empty, or if its `ApiName`/`QualifiedApiName` contains a namespace prefix pattern.

Always filter queries with:
```soql
WHERE NamespacePrefix = null OR NamespacePrefix = ''
```

Or for Tooling API queries that don't expose `NamespacePrefix`, check that the name does not match the pattern `^[a-zA-Z0-9]+__[a-zA-Z]`.

---

## 9. Evidence Standard

Every finding must include evidence — the actual data that triggered it. Acceptable evidence forms:

- A count (`Found 14 users with Modify All Data`)
- A list of names (up to 10 items; if more, show first 10 and note `...and N more`)
- A field value or setting (`PasswordMaxLoginAttempts = 0`)
- A code excerpt (max 3 lines, enough to confirm the pattern)

Never raise a finding without evidence. If evidence cannot be retrieved, mark the check as `⏭️ SKIPPED` instead.

---

## 10. Scoring Integrity Rules

- A domain score must be recalculated fresh each run — never cached or estimated from a previous run
- Quick scan scores must be clearly marked as preliminary and not used in final global scoring
- If a sub-skill cannot run (MCP down, insufficient permissions, CLI error), its domain score is marked `N/A` and excluded from the global weighted average — the remaining weights are renormalized to sum to 100%
- The global score must always show which domains were included and which were excluded
