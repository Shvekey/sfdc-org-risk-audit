# Salesforce Org Risk Audit Tool

> **Created by [Udi Shvekey](https://github.com/Shvekey)** — Principal Technical Architect, Salesforce
> Built as a personal project to help Salesforce practitioners quickly surface security and implementation risks in production orgs.

A Claude Code skill suite that performs a comprehensive security and implementation risk analysis of a Salesforce production org.

## What It Does

Runs a multi-domain audit of a Salesforce org covering:

- Security & Access Control
- Authentication & Identity
- User & Profile Management
- Apex Code Quality
- Trigger Framework Conformance
- Automation Health
- Data Model & Architecture
- Org Configuration & Health

Each domain is scored 0–100. An overall weighted risk score is calculated and expressed as a RAG rating:

- 🔴 **Red**: 0–55 — Critical risk, immediate action required
- 🟡 **Amber**: 56–85 — Notable risk areas, remediation recommended
- 🟢 **Green**: 86–100 — Healthy, minor improvements possible

## Requirements

- [Claude Code](https://claude.ai/code) installed
- [Salesforce CLI (`sf`)](https://developer.salesforce.com/tools/salesforcecli) installed and authenticated to your target org
- The following Salesforce MCP servers configured in Claude Code (see [Installation](#installation)):
  - `sobject-reads`
  - `salesforce-api-context`
  - `metadata-experts`
  - `data-cloud-queries`

## Installation

Run the install script:

```bash
chmod +x install.sh
./install.sh
```

The script will:
1. Check prerequisites (Claude Code, `sf` CLI)
2. Copy all skills to `~/.claude/skills/`
3. Register the required Salesforce MCP servers in Claude Code
4. Verify MCP server connectivity

## Usage

In any Claude Code session:

```
/org-risk-audit
```

The skill will:
1. Ask which org to target
2. Check MCP server connectivity
3. Run a quick scan and show preliminary scores
4. Ask if you want a full deep scan
5. Produce the final risk report
6. Offer to export the report as a markdown file

## Disclaimers

See [DISCLAIMER.md](DISCLAIMER.md) for the full list. Key points:

- This tool is **read-only** — it makes no changes to your org
- Managed package components are **excluded** from analysis
- Results represent a **point-in-time snapshot**
- Requires Tooling API access on the authenticated user

## Structure

```
sfdc-org-risk-audit/
├── skills/
│   ├── org-risk-audit.md              # Master skill (entry point)
│   ├── ora-scoring-contract.md        # Shared scoring conventions
│   ├── ora-security-access.md         # Domain: Security & Access Control
│   ├── ora-auth-identity.md           # Domain: Authentication & Identity
│   ├── ora-user-profile.md            # Domain: User & Profile Management
│   ├── ora-apex-quality.md            # Domain: Apex Code Quality
│   ├── trigger-framework-audit.md     # Domain: Trigger Framework Conformance
│   ├── ora-automation-health.md       # Domain: Automation Health
│   ├── ora-data-model.md              # Domain: Data Model & Architecture
│   └── ora-org-config.md              # Domain: Org Configuration & Health
├── install.sh
├── README.md
└── DISCLAIMER.md
```

## Contributing

PRs welcome. Please test against a sandbox before submitting changes to any sub-skill.

## Author

**Udi Shvekey** — Principal Technical Architect at Salesforce, specializing in Pharma and Med-tech enterprise architecture.
Built out of a passion for helping Salesforce customers and practitioners build secure, well-architected orgs.

GitHub: [@Shvekey](https://github.com/Shvekey)

## License

MIT
