SHELL := /bin/bash
ENV_FILE ?= .env

define run_with_env
	@if [ -f $(ENV_FILE) ]; then \
		bash -lc 'set -a; source $(ENV_FILE); set +a; $(1)'; \
	else \
		echo "$(ENV_FILE) not found" >&2; \
		exit 1; \
	fi
endef

.PHONY: build
build:
	$(call run_with_env,forge build)

.PHONY: test
test:
	$(call run_with_env,forge test)

.PHONY: test-ci
test-ci:
	@: "$${MONAD_RPC_URL:?MONAD_RPC_URL is required}"
	@: "$${ATLAS_ADDRESS:?ATLAS_ADDRESS is required}"
	@: "$${ATLAS_VERIFICATION_ADDRESS:?ATLAS_VERIFICATION_ADDRESS is required}"
	forge test

.PHONY: all
all: build test
