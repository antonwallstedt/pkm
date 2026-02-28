#!/bin/bash
set -e

# ─────────────────────────────────────────
# notes-publish setup script
# Configures all GitHub secrets, variables,
# and Cloudflare resources for a fresh install.
# ─────────────────────────────────────────

# Check dependencies
for cmd in gh npx; do
  if ! command -v $cmd &>/dev/null; then
    echo "Error: $cmd is required but not installed."
    echo "  gh:  https://cli.github.com"
    echo "  npx: comes with Node.js — https://nodejs.org"
    exit 1
  fi
done

# Check gh auth
if ! gh auth status &>/dev/null; then
  echo "Error: not logged in to GitHub CLI."
  echo "  Run: gh auth login"
  exit 1
fi

OWNER=$(gh api user --jq '.login')

echo ""
echo "Setting up PKM for GitHub user: $OWNER"
echo ""

# ─────────────────────────────────────────
# Repo names
# ─────────────────────────────────────────

read -p "Vault repo name       [notes-vault]:   " VAULT_REPO;   VAULT_REPO=${VAULT_REPO:-notes-vault}
read -p "Staging repo name     [notes-staging]: " STAGING_REPO; STAGING_REPO=${STAGING_REPO:-notes-staging}
read -p "Site repo name        [notes-site]:    " SITE_REPO;    SITE_REPO=${SITE_REPO:-notes-site}
read -p "Cloudflare project    [notes]:         " CF_PROJECT;   CF_PROJECT=${CF_PROJECT:-notes}

echo ""
echo "You need three tokens. Instructions will be shown for each."
echo ""

# ─────────────────────────────────────────
# STAGING_PAT
# ─────────────────────────────────────────

echo "── STAGING_PAT ───────────────────────────────────────────────"
echo "Create a fine-grained PAT at:"
echo "  https://github.com/settings/personal-access-tokens/new"
echo ""
echo "Settings:"
echo "  Repository access: $OWNER/$STAGING_REPO only"
echo "  Permissions:"
echo "    Contents:      Read and write"
echo "    Pull requests: Read and write"
echo ""
read -sp "Paste STAGING_PAT: " STAGING_PAT; echo
echo ""

# ─────────────────────────────────────────
# NOTES_SITE_PAT
# ─────────────────────────────────────────

echo "── NOTES_SITE_PAT ────────────────────────────────────────────"
echo "Create a fine-grained PAT at:"
echo "  https://github.com/settings/personal-access-tokens/new"
echo ""
echo "Settings:"
echo "  Repository access: $OWNER/$SITE_REPO only"
echo "  Permissions:"
echo "    Contents: Read and write"
echo "    Actions:  Read and write"
echo ""
read -sp "Paste NOTES_SITE_PAT: " NOTES_SITE_PAT; echo
echo ""

# ─────────────────────────────────────────
# Cloudflare
# ─────────────────────────────────────────

echo "── CLOUDFLARE_API_TOKEN ──────────────────────────────────────"
echo "Create a token at:"
echo "  https://dash.cloudflare.com/profile/api-tokens"
echo ""
echo "Settings:"
echo "  Use custom token"
echo "  Permissions:"
echo "    Account → Cloudflare Pages → Edit"
echo "    Account → Account Settings → Read"
echo ""
read -sp "Paste CLOUDFLARE_API_TOKEN: " CF_TOKEN; echo
echo ""

read -sp "Paste CLOUDFLARE_ACCOUNT_ID: " CF_ACCOUNT_ID; echo
echo ""

# ─────────────────────────────────────────
# Apply secrets and variables
# ─────────────────────────────────────────

echo "Configuring $OWNER/$VAULT_REPO..."
gh secret set STAGING_PAT   --body "$STAGING_PAT"   --repo "$OWNER/$VAULT_REPO"
gh variable set STAGING_REPO      --body "$STAGING_REPO" --repo "$OWNER/$VAULT_REPO"
gh variable set STAGING_PATH      --body "$STAGING_REPO" --repo "$OWNER/$VAULT_REPO"
gh variable set NOTES_SITE_REPO   --body "$SITE_REPO"    --repo "$OWNER/$VAULT_REPO"

echo "Configuring $OWNER/$STAGING_REPO..."
gh secret set STAGING_PAT    --body "$STAGING_PAT"    --repo "$OWNER/$STAGING_REPO"
gh secret set NOTES_SITE_PAT --body "$NOTES_SITE_PAT" --repo "$OWNER/$STAGING_REPO"
gh variable set STAGING_REPO           --body "$STAGING_REPO" --repo "$OWNER/$STAGING_REPO"
gh variable set NOTES_SITE_REPO        --body "$SITE_REPO"    --repo "$OWNER/$STAGING_REPO"
gh variable set CLOUDFLARE_PROJECT_NAME --body "$CF_PROJECT"  --repo "$OWNER/$STAGING_REPO"

echo "Configuring $OWNER/$SITE_REPO..."
gh secret set STAGING_PAT         --body "$STAGING_PAT" --repo "$OWNER/$SITE_REPO"
gh secret set CLOUDFLARE_API_TOKEN --body "$CF_TOKEN"    --repo "$OWNER/$SITE_REPO"
gh secret set CLOUDFLARE_ACCOUNT_ID --body "$CF_ACCOUNT_ID" --repo "$OWNER/$SITE_REPO"
gh variable set CLOUDFLARE_PROJECT_NAME --body "$CF_PROJECT" --repo "$OWNER/$SITE_REPO"
gh variable set NOTES_SITE_REPO         --body "$SITE_REPO"  --repo "$OWNER/$SITE_REPO"

# ─────────────────────────────────────────
# Cloudflare Pages project
# ─────────────────────────────────────────

echo ""
echo "Creating Cloudflare Pages project '$CF_PROJECT'..."
CF_API_TOKEN=$CF_TOKEN npx wrangler pages project create "$CF_PROJECT" || echo "(project may already exist, continuing)"

# ─────────────────────────────────────────

echo ""
echo "✓ Setup complete."
echo ""
echo "Next steps:"
echo "  1. Clone all four repos into pkm/ as submodules"
echo "  2. Run: make install"
echo "  3. Run: make preview"
echo "  4. Run: make deploy"