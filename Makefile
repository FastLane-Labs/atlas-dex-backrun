# Include .env file if it exists
-include .env

# Default network and RPC settings
NETWORK ?= monad-testnet
# Extract network type and name from NETWORK variable (e.g., eth-mainnet -> ETH_MAINNET)
NETWORK_UPPER = $(shell echo $(NETWORK) | tr 'a-z-' 'A-Z_')
# Override any existing RPC_URL with the network-specific one
RPC_URL = $($(NETWORK_UPPER)_RPC_URL)
# Default fork block (can be overridden)
FORK_BLOCK ?= latest

# Conditionally set the fork block number flag
ifeq ($(FORK_BLOCK),latest)
  FORK_BLOCK_FLAG = 
else
  FORK_BLOCK_FLAG = --fork-block-number $(FORK_BLOCK)
endif

# Debug target
debug-network:
	@echo "NETWORK: $(NETWORK)"
	@echo "NETWORK_UPPER: $(NETWORK_UPPER)"
	@echo "RPC_URL: $(RPC_URL)"
	@echo "FORK_BLOCK: $(FORK_BLOCK)"
	@echo "FORK_BLOCK_FLAG: $(FORK_BLOCK_FLAG)"

# Declare all PHONY targets
.PHONY: all clean install build test test-gas format snapshot anvil size update
.PHONY: deploy test-deploy fork-anvil fork-test-deploy
.PHONY: deploy-address-hub deploy-shmonad deploy-taskmanager deploy-paymaster deploy-sponsored-executor
.PHONY: upgrade-address-hub upgrade-shmonad upgrade-taskmanager upgrade-paymaster
.PHONY: test-deploy-address-hub test-deploy-shmonad test-deploy-taskmanager test-deploy-paymaster test-deploy-sponsored-executor
.PHONY: test-upgrade-address-hub test-upgrade-shmonad test-upgrade-taskmanager test-upgrade-paymaster
.PHONY: fork-test-deploy-address-hub fork-test-deploy-shmonad fork-test-deploy-taskmanager fork-test-deploy-paymaster fork-test-deploy-sponsored-executor
.PHONY: fork-test-upgrade-address-hub fork-test-upgrade-shmonad fork-test-upgrade-taskmanager fork-test-upgrade-paymaster
.PHONY: request-tokens get-paymaster-info scenario_test_upgrade replay-tx generate-verification-json

# Default target
all: clean install build test

# Build and test targets
clean:
	forge clean

install:
	forge install

build:
	forge build

test:
	forge test -vvv

test-gas:
	forge test -vvv --gas-report

format:
	forge fmt

snapshot:
	forge snapshot

anvil:
	anvil

# Start anvil with fork of the specified network
fork-anvil: debug-network
	@if [ -z "$(RPC_URL)" ]; then echo "No RPC URL found for network $(NETWORK)"; exit 1; fi
	@echo "Starting anvil with fork of $(NETWORK) at block $(FORK_BLOCK)..."
	anvil --fork-url $(RPC_URL) $(FORK_BLOCK_FLAG)

size:
	forge build --sizes

update:
	forge update 

# Contract Verification JSON Generation
generate-verification-json:
	@if [ -z "$(CONTRACT_ADDRESS)" ]; then \
		echo "Error: CONTRACT_ADDRESS variable must be set."; \
		echo "Usage: make generate-verification-json CONTRACT_ADDRESS=<address> CONTRACT_PATH=<path:name> [CONSTRUCTOR_ARGS=<args>]"; \
		echo ""; \
		echo "Examples:"; \
		echo "  make generate-verification-json CONTRACT_ADDRESS=0x123... CONTRACT_PATH=src/MyContract.sol:MyContract"; \
		echo "  make generate-verification-json CONTRACT_ADDRESS=0x123... CONTRACT_PATH=src/MyContract.sol:MyContract CONSTRUCTOR_ARGS=0x456..."; \
		exit 1; \
	fi
	@if [ -z "$(CONTRACT_PATH)" ]; then \
		echo "Error: CONTRACT_PATH variable must be set."; \
		echo "Usage: make generate-verification-json CONTRACT_ADDRESS=<address> CONTRACT_PATH=<path:name> [CONSTRUCTOR_ARGS=<args>]"; \
		exit 1; \
	fi
	@echo "Generating verification JSON for contract on $(NETWORK)..."
	@if [ -n "$(CONSTRUCTOR_ARGS)" ]; then \
		./script/generate-etherscan-json.sh $(CONTRACT_ADDRESS) $(CONTRACT_PATH) $(CONSTRUCTOR_ARGS); \
	else \
		./script/generate-etherscan-json.sh $(CONTRACT_ADDRESS) $(CONTRACT_PATH); \
	fi