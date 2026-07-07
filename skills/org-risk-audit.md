---
name: org-risk-audit
description: Master orchestrator for the Salesforce Org Risk Audit (ORA) tool. Coordinates all eight domain sub-skills, collects domain scores, calculates the weighted global score, and produces an executive summary report. Run this skill to perform a full or targeted audit of a Salesforce org.
whenToUse: Run when the user asks for a Salesforce org risk audit, org health check, org assessment, or security review. Can be directed at any org the user has authenticated via the Salesforce CLI (sf auth).
---

# ORA — Org Risk Audit (Master Skill)

> **Scoring contract:** See `ora-scoring-contract`
> **ORA sub-skills:** `ora-security-access`, `ora-auth-identity`, `ora-user-profile`, `ora-apex-quality`, `ora-automation-health`, `ora-org-config`, `ora-data-model`, `trigger-framework-audit`
> **sf-skills used:** `dx-code-analyzer-run`, `dx-code-analyzer-configure`, `platform-apex-test-run`, `platform-apex-logs-debug`, `platform-soql-query`, `platform-metadata-retrieve`, `dx-org-switch`

---

## Step 0 — sf-skills Availability Check

This tool delegates several checks to skills from the [forcedotcom/sf-skills](https://github.com/forcedotcom/sf-skills) library. Before running, verify they are installed:

```bash
npx skills list 2>/dev/null | grep -E "dx-code-analyzer-run|platform-apex-test-run|platform-apex-logs-debug"
```

If the skills are not found, install them:
```bash
npx skills add forcedotcom/sf-skills
```

If `npx skills add` is unavailable or fails, the audit will fall back to the built-in CLI queries defined in each sub-skill. Note this in the report header:
```
⚠️  sf-skills not available — using sf CLI fallback for Apex analysis. Install with: npx skills add forcedotcom/sf-skills
```

---

## Step 1 — Gather Inputs

Before running any checks, ask the user:

**Question 1 — Target org:**
> Which Salesforce org should I audit? Please provide the org alias or username (as shown in `sf org list`).

**Question 2 — Scan mode:**
> Which scan mode?
> - **Quick Scan** — metadata counts and existence checks only. Completes in ~2 minutes. Produces a preliminary score.
> - **Deep Scan** — full metadata body analysis, Apex code scanning, Flow XML parsing. Completes in ~10–15 minutes. Produces the final score.

**Question 3 — Scope (optional):**
> Run all 8 domains, or focus on specific ones?
> Options: All (default) | Security | Auth | Users | Apex | Automation | Config | DataModel | Triggers
> (Accept comma-separated list for partial scope, e.g. "Security, Auth, Apex")

If the user does not answer Question 3, default to **All**.

---

## Step 2 — Authenticate and Verify Org Access

Before running sub-skills, verify the target org is authenticated and accessible:

```bash
sf org display --target-org <org>
```

If the command fails, stop and inform the user:
```
❌ Cannot connect to org '<org>'. Please verify the alias is correct and run:
   sf org login web --alias <org>
```

If successful, display a brief confirmation:
```
✅ Connected to: <OrgName> (<OrgId>)
   Type: <Production | Sandbox | Scratch>
   API Version: <version>
   User: <username>
```

---

## Step 3 — Run Sub-Skills

Run each selected domain sub-skill in sequence. Pass the following context to each:
- Target org alias
- Scan mode (Quick or Deep)
- sf-skills availability (available or fallback)
- Indicate the sub-skill is being invoked by the master skill (so it skips re-asking for org/mode)

**Execution order** (run in this sequence to allow later skills to reference earlier results):
1. `ora-security-access` — Security & Access Control (20%)
2. `ora-auth-identity` — Authentication & Identity (15%)
3. `ora-user-profile` — User & Profile Management (15%)
4. `ora-apex-quality` — Apex Code Quality (15%) — delegates to `dx-code-analyzer-run`, `platform-apex-test-run`, `platform-apex-logs-debug`
5. `ora-automation-health` — Automation Health (10%) — delegates to `platform-metadata-retrieve` for Flow XML in deep scan
6. `ora-org-config` — Org Configuration & Health (10%)
7. `ora-data-model` — Data Model & Architecture (10%)
8. `trigger-framework-audit` — Trigger Framework (5%) — delegates to `dx-code-analyzer-run` for body analysis in deep scan

After each sub-skill completes, display its output block immediately (do not wait for all domains to finish before showing results). This allows the user to begin reviewing findings while later domains are still running.

If a sub-skill cannot run (MCP error, permission error, CLI error), mark that domain as `N/A` and continue. Renormalize weights at the end.

### sf-skills delegation reference

| sf-skill | Used by | Purpose |
|---|---|---|
| `dx-org-switch` | master | Ensure target org is active before running sub-skills |
| `platform-apex-test-run` | `ora-apex-quality` QS-1 | Test coverage analysis with class-level breakdown |
| `platform-apex-logs-debug` | `ora-apex-quality` QS-2 | Active debug log analysis |
| `dx-code-analyzer-configure` | `ora-apex-quality` deep scan | Set up Code Analyzer for the org's project if not already configured |
| `dx-code-analyzer-run` | `ora-apex-quality` DS-1–5, `trigger-framework-audit` DS-1–5 | AST-based Apex scanning: SOQL-in-loops, DML-in-loops, SOQL injection, `without sharing`, hardcoded IDs |
| `platform-metadata-retrieve` | `ora-automation-health` DS-2, `ora-data-model` DS-4 | Retrieve Flow XML and field metadata for deep scan body analysis |
| `platform-soql-query` | all sub-skills | SOQL query generation and optimisation assistance when constructing complex queries |

---

## Step 4 — Collect Domain Scores

As each sub-skill completes, record its domain score. Use the following table to track progress:

| Domain | Sub-Skill | Weight | Score | Weighted Points | Status |
|---|---|---|---|---|---|
| Security & Access Control | `ora-security-access` | 20% | — | — | — |
| Authentication & Identity | `ora-auth-identity` | 15% | — | — | — |
| User & Profile Management | `ora-user-profile` | 15% | — | — | — |
| Apex Code Quality | `ora-apex-quality` | 15% | — | — | — |
| Automation Health | `ora-automation-health` | 10% | — | — | — |
| Org Configuration & Health | `ora-org-config` | 10% | — | — | — |
| Data Model & Architecture | `ora-data-model` | 10% | — | — | — |
| Trigger Framework | `trigger-framework-audit` | 5% | — | — | — |

---

## Step 5 — Calculate Global Score

### Standard calculation (all domains ran):
```
global_score = (security × 0.20) + (auth × 0.15) + (users × 0.15) + (apex × 0.15)
             + (automation × 0.10) + (config × 0.10) + (datamodel × 0.10) + (triggers × 0.05)
```

### If one or more domains are N/A (renormalize):
1. Sum the weights of domains that ran successfully.
2. Divide each successful domain's weight by that sum to get renormalized weights.
3. Apply the renormalized weights to calculate the global score.
4. Clearly note which domains were excluded and the renormalization applied.

**Example:** If `ora-apex-quality` (15%) could not run:
- Remaining weight sum = 85%
- Each remaining weight ÷ 0.85
- Security: 20/85 = 23.5%, Auth: 15/85 = 17.6%, etc.

---

## Step 6 — Produce Executive Summary

After all domain scans complete, output the following consolidated report:

```
╔══════════════════════════════════════════════════════════════╗
║          SALESFORCE ORG RISK AUDIT — EXECUTIVE SUMMARY       ║
╚══════════════════════════════════════════════════════════════╝

Org:        <OrgName> (<username>)
Org ID:     <OrgId>
Scan Date:  <date>
Scan Mode:  <Quick Scan — preliminary | Deep Scan — final>
Scope:      <All domains | listed domains>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 GLOBAL ORG RISK SCORE                        [score]/100 [RAG]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

DOMAIN SCORES
─────────────────────────────────────────────────────────────
 Security & Access Control    [score]/100 [RAG]   (20%)
 Authentication & Identity    [score]/100 [RAG]   (15%)
 User & Profile Management    [score]/100 [RAG]   (15%)
 Apex Code Quality            [score]/100 [RAG]   (15%)
 Automation Health            [score]/100 [RAG]   (10%)
 Org Configuration & Health   [score]/100 [RAG]   (10%)
 Data Model & Architecture    [score]/100 [RAG]   (10%)
 Trigger Framework            [score]/100 [RAG]    (5%)
─────────────────────────────────────────────────────────────

TOP CRITICAL FINDINGS (across all domains)
[List up to 10 critical findings ranked by severity, one line each:
  🔴 [Domain] — [Finding title]: [one-line description]
]

TOP HIGH FINDINGS
[List up to 10 high findings:
  🟠 [Domain] — [Finding title]: [one-line description]
]

FINDING SUMMARY
  🔴 Critical:  [n]
  🟠 High:      [n]
  🟡 Medium:    [n]
  🔵 Low:       [n]
  ✅ Passed:    [n]

RECOMMENDED ACTIONS (top 5 by risk × effort)
  1. [Action] — [Domain] — Expected score improvement: +[n] points
  2. [Action] — [Domain] — Expected score improvement: +[n] points
  3. [Action] — [Domain] — Expected score improvement: +[n] points
  4. [Action] — [Domain] — Expected score improvement: +[n] points
  5. [Action] — [Domain] — Expected score improvement: +[n] points

[If Quick Scan: note below]
⚠️  This is a PRELIMINARY score based on Quick Scan mode.
    Re-run with Deep Scan for full body analysis and final scoring.
    Deep Scan checks not run: DS-1 through DS-5 in each domain.
```

---

## Step 7 — Offer Follow-Up Options

After the executive summary, offer:

```
What would you like to do next?

  1. Deep dive into a specific domain  (e.g. "show me the full Security report")
  2. Re-run a single domain            (e.g. after remediating findings)
  3. Export findings as CSV            (list all findings with domain, severity, title, fix)
  4. Re-run full audit in Deep Scan mode  (if Quick Scan was used)
  5. Nothing — I'm done
```

For option 3 (CSV export), format all findings as:
```
Domain,Severity,Check ID,Finding Title,Evidence,Fix
Security & Access Control,Critical,QS-2,Guest user has ViewAllData,Profile.PermissionsViewAllData = true,Remove ViewAllData from guest profile
...
```

---

## Scoring Reference

For convenience, the global score thresholds:

| Score | RAG | Meaning |
|---|---|---|
| 86–100 | 🟢 Green | Healthy org — maintain and monitor |
| 56–85 | 🟡 Amber | Needs attention — prioritise High findings this quarter |
| 0–55 | 🔴 Red | Critical risk — address Critical findings immediately |

Domain weights:

| Domain | Weight |
|---|---|
| Security & Access Control | 20% |
| Authentication & Identity | 15% |
| User & Profile Management | 15% |
| Apex Code Quality | 15% |
| Automation Health | 10% |
| Org Configuration & Health | 10% |
| Data Model & Architecture | 10% |
| Trigger Framework | 5% |
| **Total** | **100%** |
