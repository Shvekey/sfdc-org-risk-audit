#!/usr/bin/env bash

# Salesforce Org Risk Audit Tool — Installer
# Created by Udi Shvekey (https://github.com/Shvekey)
# https://github.com/Shvekey/sfdc-org-risk-audit

set -e

SKILLS_DIR="$HOME/.claude/skills"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "================================================="
echo " Salesforce Org Risk Audit Tool — Installer"
echo "================================================="
echo ""

# ── Prerequisite checks ──────────────────────────────

echo "Checking prerequisites..."
echo ""

# Claude Code
if ! command -v claude &>/dev/null; then
  echo "❌  Claude Code not found. Install it from https://claude.ai/code and re-run this script."
  exit 1
else
  echo "✅  Claude Code: $(claude --version 2>/dev/null || echo 'found')"
fi

# Salesforce CLI
if ! command -v sf &>/dev/null; then
  echo "❌  Salesforce CLI (sf) not found. Install it from https://developer.salesforce.com/tools/salesforcecli and re-run."
  exit 1
else
  echo "✅  Salesforce CLI: $(sf --version 2>/dev/null | head -1)"
fi

echo ""

# ── Install skills ────────────────────────────────────

echo "Installing skills to $SKILLS_DIR ..."
mkdir -p "$SKILLS_DIR"

for skill in "$SCRIPT_DIR"/skills/*.md; do
  cp "$skill" "$SKILLS_DIR/"
  echo "  ✅  Installed: $(basename "$skill")"
done

echo ""

# ── Register MCP servers ──────────────────────────────

echo "Registering Salesforce MCP servers in Claude Code..."
echo ""

register_mcp() {
  local name=$1
  local url=$2
  if claude mcp add "$name" -s user -t http "$url" 2>/dev/null; then
    echo "  ✅  Registered: $name"
  else
    echo "  ⚠️   Already registered or failed: $name (check with: claude mcp list)"
  fi
}

register_mcp "sobject-reads"       "https://api.salesforce.com/platform/mcp/v1/platform/sobject-reads"
register_mcp "salesforce-api-context" "https://api.salesforce.com/platform/mcp/v1/platform/salesforce-api-context"
register_mcp "metadata-experts"    "https://api.salesforce.com/platform/mcp/v1/platform/metadata-experts"
register_mcp "data-cloud-queries"  "https://api.salesforce.com/platform/mcp/v1/data/data-cloud-queries"

echo ""

# ── Salesforce Connected App instructions ─────────────

echo "================================================="
echo " Enabling MCP in your Salesforce Org"
echo "================================================="
echo ""
echo "To allow Claude to connect to your org via MCP, ensure the following"
echo "is configured in your Salesforce org:"
echo ""
echo "  1. Go to Setup → Connected Apps → Manage Connected Apps"
echo "  2. Locate or create a Connected App for Claude Code MCP access"
echo "  3. Ensure the following OAuth scopes are enabled:"
echo "       - Access and manage your data (api)"
echo "       - Perform requests at any time (refresh_token, offline_access)"
echo "       - Access the Salesforce platform (platform)"
echo "  4. Go to Setup → Session Settings and ensure:"
echo "       - 'Use OAuth 2.0 for API Integration' is enabled"
echo "  5. Authenticate via: sf org login web --alias <your-org-alias>"
echo ""
echo "For detailed MCP setup documentation, visit:"
echo "  https://developer.salesforce.com/docs/platform/mcp/guide"
echo ""

# ── Done ──────────────────────────────────────────────

echo "================================================="
echo " Installation Complete!"
echo "================================================="
echo ""
echo "Start a new Claude Code session and run:"
echo ""
echo "  /org-risk-audit"
echo ""
echo "to begin your org risk analysis."
echo ""
