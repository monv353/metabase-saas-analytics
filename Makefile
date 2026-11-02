# All Docker commands run on the remote host; nothing here starts containers locally.
REMOTE      ?= myserver
REMOTE_DIR  ?= ~/portfolio/metabase-saas-analytics
COMPOSE     := docker compose
SSH         := ssh $(REMOTE)
RUN         := $(SSH) 'cd $(REMOTE_DIR) &&

.PHONY: help sync deploy provision verify tunnel status logs down reset screenshot

help:            ## List targets
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

sync:            ## Copy the project (including .env) to the remote host
	@test -f .env || (echo ".env missing: cp .env.example .env and fill it in" && exit 1)
	$(SSH) 'mkdir -p $(REMOTE_DIR)'
	rsync -az --delete --exclude .git --exclude docs --exclude __pycache__ ./ $(REMOTE):$(REMOTE_DIR)/
	$(SSH) 'chmod 600 $(REMOTE_DIR)/.env'

deploy: sync     ## Sync, then start the stack and wait until every service is healthy
	$(RUN) $(COMPOSE) up -d --wait --wait-timeout 600 && $(COMPOSE) ps'

provision: sync  ## Create admin, connect warehouse, build questions + dashboard (idempotent)
	$(RUN) python3 provision.py'

verify:          ## Check via the API that the dashboard exists and every card returns rows
	$(RUN) python3 provision.py --verify-only'

tunnel:          ## Forward localhost:3300 to Metabase on the remote host (Ctrl-C to close)
	@echo "Open http://localhost:3300 once the tunnel is up"
	ssh -N -L 3300:127.0.0.1:3300 $(REMOTE)

status:          ## Container status and memory use
	$(RUN) $(COMPOSE) ps && docker stats --no-stream $$($(COMPOSE) ps -q)'

logs:            ## Tail Metabase logs
	$(RUN) $(COMPOSE) logs --tail 100 -f metabase'

down:            ## Stop the stack (data volumes are kept)
	$(RUN) $(COMPOSE) down'

reset:           ## Stop the stack AND delete its volumes (re-seeds on next deploy)
	@read -p "Delete pf-metabase volumes on $(REMOTE)? [y/N] " a && [ "$$a" = y ]
	$(RUN) $(COMPOSE) down -v'

CHROME ?= /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
screenshot:      ## Save docs/dashboard.png via headless Chrome through a temporary tunnel (macOS)
	@set -a; . ./.env; set +a; \
	ssh -N -o ExitOnForwardFailure=yes -L 3300:127.0.0.1:3300 $(REMOTE) & TUN=$$!; \
	"$(CHROME)" --headless=new --remote-debugging-port=9333 --user-data-dir=$$(mktemp -d) --hide-scrollbars about:blank >/dev/null 2>&1 & CHR=$$!; \
	sleep 4; node scripts/screenshot.mjs docs/dashboard.png; RC=$$?; kill $$CHR $$TUN; exit $$RC
