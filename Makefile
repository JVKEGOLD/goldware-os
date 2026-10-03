.DEFAULT_GOAL := help
.PHONY: help setup update doctor app install run-server test check

help: ## Show this help
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z_-]+:.*## /{printf "  %-12s %s\n",$$1,$$2}' $(MAKEFILE_LIST)

setup: ## Install everything (models, build, install app)
	scripts/setup.sh

update: ## Get the latest GoldWare OS, keeping your settings and your own changes
	scripts/update.sh

doctor: ## Read-only health check with fix commands
	scripts/doctor.sh

app: ## Build app/build/GoldWareOS.app
	cd app && ./build.sh

install: ## Copy the built app to /Applications
	scripts/setup.sh --only install

run-server: ## Run the local dashboard server on 127.0.0.1:4188
	python3 server/goldware_server.py

test: ## Run python tests and the app self-tests
	python3 -m unittest discover -s tests -v
	@for t in hand quadrants chord wake shelf lets-work terminal-commands agent-peek tour; do \
	  echo "== app self-test: $$t"; \
	  GOLDWARE_DATA="$${TMPDIR:-/tmp}/gw-test-data" app/.build/release/GoldWareOS --test-$$t || exit 1; \
	done

check: test ## Tests, privacy gate, config validation
	scripts/check_private.sh
	python3 server/goldware_server.py --check
