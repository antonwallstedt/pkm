# Paths
VAULT   := $(CURDIR)/notes-vault
STAGING := $(CURDIR)/notes-staging
SITE    := $(CURDIR)/notes-site
BIN     := $(SITE)/utils/notes-publish/target/release/notes-publish

# ─────────────────────────────────────────
# Setup
# ─────────────────────────────────────────

.PHONY: setup
setup: ## Run first-time setup (secrets, variables, Cloudflare project)
	@./scripts/setup.sh

.PHONY: install
install: ## Build notes-publish binary locally
	cargo build --release --manifest-path $(SITE)/utils/notes-publish/Cargo.toml

# ─────────────────────────────────────────
# Publishing
# ─────────────────────────────────────────

.PHONY: preview
preview: $(BIN) ## Dry run — show what would be published
	@$(BIN) \
		--vault $(VAULT) \
		--staging $(STAGING) \
		--dry-run || [ $$? -eq 2 ]

.PHONY: deploy
deploy: $(BIN) ## Filter, copy, commit, and open PR in notes-staging
	@$(BIN) \
		--vault $(VAULT) \
		--staging $(STAGING) \
		--owner $(shell gh api user --jq '.login') \
		--repo $(shell basename $(STAGING)) \
		--token $(shell gh auth token) \
		--yes || [ $$? -eq 2 ]

# ─────────────────────────────────────────
# Local development
# ─────────────────────────────────────────

.PHONY: sync
sync: $(BIN) ## Sync public vault notes to notes-staging locally (no GitHub PR)
	@$(BIN) \
		--vault $(VAULT) \
		--staging $(STAGING) || [ $$? -eq 2 ]

.PHONY: serve
serve: ## Serve Quartz site from notes-staging with live reload
	cd $(SITE) && npx quartz build --serve -d $(STAGING)

.PHONY: build
build: ## Build Quartz site from notes-staging (production)
	cd $(SITE) && npx quartz build -d $(STAGING)

# ─────────────────────────────────────────
# Sync
# ─────────────────────────────────────────

.PHONY: pull
pull: ## Pull latest on all submodules
	git -C $(VAULT) pull origin main
	git -C $(STAGING) pull origin main
	git -C $(SITE) pull origin v4

# ─────────────────────────────────────────

.PHONY: help
help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help