#!make
include .bingo/Variables.mk

FILES_TO_FMT      ?= $(shell find . -name '*.go' -print)

# Ensure everything works even if GOPATH is not set, which is often the case.
# The `go env GOPATH` will work for all cases for Go 1.8+.
GOPATH      ?= $(shell go env GOPATH)
GOBIN       ?= $(firstword $(subst :, ,${GOPATH}))/bin
GOTEST_OPTS ?= --race -failfast -timeout 10m
GOPROXY     ?= https://proxy.golang.org

# Support gsed on OSX (installed via brew), falling back to sed. On Linux
# systems gsed won't be installed, so will use sed as expected.
SED     ?= $(shell which gsed 2>/dev/null || which sed)
GIT     ?= $(shell which git)

BIN_DIR ?= /tmp/bin
OS      ?= $(shell uname -s | tr '[A-Z]' '[a-z]')
ARCH    ?= $(shell uname -m)

SHELLCHECK ?= $(BIN_DIR)/shellcheck

define require_clean_work_tree
	@git update-index -q --ignore-submodules --refresh

	@if ! git diff-files --quiet --ignore-submodules --; then \
		echo >&2 "$1: you have unstaged changes."; \
		git diff-files --name-status -r --ignore-submodules -- >&2; \
		echo >&2 "Please commit or stash them."; \
		exit 1; \
	fi

	@if ! git diff-index --cached --quiet HEAD --ignore-submodules --; then \
		echo >&2 "$1: your index contains uncommitted changes."; \
		git diff-index --cached --name-status -r --ignore-submodules HEAD -- >&2; \
		echo >&2 "Please commit or stash them."; \
		exit 1; \
	fi

endef


.PHONY: deps
deps: ## Ensures fresh go.mod and go.sum.
	@go mod tidy
	@go mod verify

.PHONY: test
test: ## Run all project tests.
test: 
	go test $(GOTEST_OPTS) ./...

.PHONY: go-format
go-format: ## Formats Go code including imports.
go-format: $(GOIMPORTS)
	@echo ">> formatting go code"
	@SED_BIN="$(SED)" scripts/cleanup-white-noise.sh $(FILES_TO_FMT)
	@gofmt -s -w $(FILES_TO_FMT)
	@$(GOIMPORTS) -w $(FILES_TO_FMT)

.PHONY:format
format: ## Formats code including imports and cleans up white noise.
format: go-format
	@SED_BIN="$(SED)" scripts/cleanup-white-noise.sh $(FILES_TO_FMT)

.PHONY:lint
lint: ## Runs various static analysis against our code.
lint: go-lint shell-lint
	@echo ">> detecting white noise"
	@find . -type f \( -name "*.md" -o -name "*.go" \) | SED_BIN="$(SED)" xargs scripts/cleanup-white-noise.sh
	$(call require_clean_work_tree,'detected white noise, run make lint and commit changes')

# PROTIP:
# Add
#      --cpu-profile-path string   Path to CPU profile output file
#      --mem-profile-path string   Path to memory profile output file
# to debug big allocations during linting.
.PHONY: go-lint
go-lint: check-git deps $(GOLANGCI_LINT) $(FAILLINT) $(MISSPELL)
	$(call require_clean_work_tree,'detected not clean master before running lint, previous job changed something?')
	@echo ">> verifying modules being imported"
	@$(FAILLINT) -paths "errors=github.com/pkg/errors" ./...
	@$(FAILLINT) -paths "fmt.{Print,Printf,Println,Sprint}" -ignore-tests ./...
	@echo ">> linting all of the Go files GOGC=${GOGC}"
	@$(GOLANGCI_LINT) run
	@echo ">> detecting misspells"
	@find . -type f | grep -v pkg/contracts/ | grep -v tmp | grep -v go.sum | grep -vE '\./\..*' | xargs $(MISSPELL) -error
	$(call require_clean_work_tree,'detected files without copyright, run make lint and commit changes')


.PHONY:shell-lint
shell-lint: $(SHELLCHECK)
	@echo ">> linting all of the shell script files"
	@$(SHELLCHECK) --severity=error -o all -s bash $(shell find . -type f -name "*.sh" -not -path "*vendor*" -not -path "tmp/*" -not -path "*node_modules*")

.PHONY: update-go-deps
update-go-deps: ## Update all golang dependencies.
	@echo ">> updating Go dependencies"
	@for m in $$($(GO) list -mod=readonly -m -f '{{ if and (not .Indirect) (not .Main)}}{{.Path}}{{end}}' all); do \
		$(GO) get $$m; \
	done
	$(GO) mod tidy



.PHONY: check-git
check-git:
ifneq ($(GIT),)
	@test -x $(GIT) || (echo >&2 "No git executable binary found at $(GIT)."; exit 1)
else
	@echo >&2 "No git binary found."; exit 1
endif

.PHONY: build
build: ## Build the project.
build: check-git
build: export GIT_TAG=$(shell git describe --tags)
build: export GIT_HASH=$(shell git rev-parse --short HEAD)
build:
	@[ "${GIT_TAG}" ] || ( echo ">> GIT_TAG is not set"; exit 1 )
	@[ "${GIT_HASH}" ] || ( echo ">> GIT_HASH is not set"; exit 1 )
	go build -ldflags "-X main.GitTag=$(GIT_TAG) -X main.GitHash=$(GIT_HASH) -s -w" -o server ./cmd



.PHONY: generate-bindings
generate-bindings: 
	rm -rf tmp/ioTube
	git clone https://github.com/iotexproject/ioTube tmp/ioTube
	rm -rf pkg/contracts/*
	mkdir pkg/contracts/tokenCashier
	abigen --sol tmp/ioTube/contracts/iotube/TokenCashier.sol --pkg tokenCashier    --out pkg/contracts/tokenCashier/tokenCashier.go
	mkdir pkg/contracts/tokenSafe
	abigen --sol tmp/ioTube/contracts/iotube/TokenSafe.sol --pkg tokenSafe    --out pkg/contracts/tokenSafe/tokenSafe.go
	mkdir pkg/contracts/tokenList
	abigen --sol tmp/ioTube/contracts/iotube/TokenList.sol --pkg tokenList    --out pkg/contracts/tokenList/tokenList.go
	mkdir pkg/contracts/shadowTokenList
	abigen --sol tmp/ioTube/contracts/iotube/ShadowTokenListManager.sol --pkg shadowTokenList    --out pkg/contracts/shadowTokenList/shadowTokenList.go
	# ERC20 token binding ->
	abigen --abi pkg/contracts/erc20/erc20.abi --pkg erc20    --out pkg/contracts/erc20/erc20.go

##### NON-phony targets
$(BIN_DIR):
	@mkdir -p $(BIN_DIR)

$(SHELLCHECK): $(BIN_DIR)
	@echo "Downloading Shellcheck"
	curl -sNL "https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.$(OS).$(ARCH).tar.xz" | tar --strip-components=1 -xJf - -C $(BIN_DIR)
