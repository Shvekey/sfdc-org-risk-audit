# Disclaimers

## Unofficial Project

This tool is a **personal project** created by Udi Shvekey in a private capacity. It is **not an official Salesforce product**, is **not affiliated with Salesforce, Inc.**, and is **not supported or endorsed by Salesforce in any way**. The fact that the author is employed by Salesforce as a Principal Technical Architect does not imply any official standing, certification, or endorsement of this tool by Salesforce.

Use of this tool does not constitute engagement with Salesforce support or professional services.

## Read-Only

This tool makes **no changes** to your Salesforce org. All operations are read-only queries against org metadata and data. No records are created, updated, or deleted.

## Managed Packages Excluded

Analysis is scoped to **unmanaged (org-owned) components only**. Apex classes, triggers, flows, and metadata belonging to managed packages (identified by a namespace prefix) are excluded from all scans. Results therefore reflect only the org's custom and configuration layer, not any ISV or AppExchange package code.

## Point-in-Time Snapshot

Results represent the state of the org **at the moment the scan is run**. Org configuration, code, and permissions change over time. Re-run the audit periodically to maintain an accurate picture.

## Tooling API Access Required

The authenticated Salesforce user running this tool must have access to the **Tooling API** and sufficient permissions to query metadata types (ApexClass, ApexTrigger, Flow, Profile, PermissionSet, etc.). Results may be incomplete if the user lacks the necessary permissions.

## MCP Server Dependency

This tool relies on **official Salesforce MCP servers** for data retrieval. MCP server availability, authentication, and response accuracy are outside the control of this project. If an MCP server is unavailable, the tool falls back to Salesforce CLI (`sf`) queries where possible and will clearly indicate any gaps in coverage.

## No Warranty

This tool is provided **"as is"**, without warranty of any kind, express or implied. The author accepts no liability for decisions made based on the output of this tool. Always validate findings with a qualified Salesforce architect or security professional before taking remediation action in a production org.

## Data Sensitivity

This tool queries org metadata and configuration. It does **not** query business data records (no customer PII, no transaction data). However, metadata outputs (profile names, field names, user counts, etc.) may be considered sensitive in some organizations. Handle report outputs accordingly and do not share them publicly.
