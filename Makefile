# Cadence build entry points (docs/SPEC.md section 14.4).
# Every target works without admin rights. macOS-only steps print SKIP elsewhere.

SHELL        := /bin/bash
.SHELLFLAGS  := -eu -o pipefail -c
.DEFAULT_GOAL := build

SWIFT        ?= swift
PYTHON       ?= python3
UNAME        := $(shell uname -s)
CONFIG       ?= debug
BUILD_DIR    := build
DEMO_HOME    := $(abspath $(BUILD_DIR)/demo-home)
BUNDLE_PREFIX ?= in.ashwingopalsamy.cadence
# The sandbox denies a folder in build/, so `make run` keeps its dev home inside the app's own container, where the
# app may read and write (docs/SPEC.md section 14.4). The app creates the container on first launch; nothing here
# writes to it. A CLI seeding the dev home needs the same CADENCE_HOME.
DEV_HOME     := $(HOME)/Library/Containers/$(BUNDLE_PREFIX)/Data/Library/Application Support/Cadence-dev
PROOF_DIR    := Tests/Vectors/proofs

ifeq ($(UNAME),Darwin)
IS_MAC := 1
else
IS_MAC :=
endif

.PHONY: build test test-fast check symbols vectors proof-vectors guard guard-all guard-test ledger-stress hooks lint snapshots-check \
        app install uninstall run demo snapshots token-sheet spike sounds entitlements clean help

help:
	@echo "build test check app install uninstall run demo snapshots spike guard sounds clean"

build:
	$(SWIFT) build -c $(CONFIG)

# No networking in the cadence binary (docs/SPEC.md section 13.1).
symbols: build
	@bash tools/tests/check_symbols_test.sh
	@bash tools/check_symbols.sh "$$($(SWIFT) build -c $(CONFIG) --show-bin-path)/cadence"

test:
	$(SWIFT) test

# The pre-commit hook runs this: the core suite only, no app or snapshot work.
test-fast:
	$(SWIFT) test --filter CadenceCoreTests

# Regenerate the synthetic proof vectors (never needed unless the generator changes).
vectors:
	$(PYTHON) tools/make_vectors.py

# Valid vectors must pass and every tampered vector must fail, in Python and in Swift.
proof-vectors:
	@$(PYTHON) tools/make_vectors.py --check
	@for f in $(PROOF_DIR)/valid*.json; do \
		$(PYTHON) tools/verify_proof.py "$$f" >/dev/null || { echo "FAIL proof vector should pass: $$f"; exit 1; }; \
	done
	@for f in $(PROOF_DIR)/tampered*.json; do \
		if $(PYTHON) tools/verify_proof.py "$$f" >/dev/null; then echo "FAIL proof vector should fail: $$f"; exit 1; fi; \
	done
	@if [ -x "$$($(SWIFT) build -c $(CONFIG) --show-bin-path)/cadence" ] && \
	    "$$($(SWIFT) build -c $(CONFIG) --show-bin-path)/cadence" help verify >/dev/null 2>&1; then \
		bin="$$($(SWIFT) build -c $(CONFIG) --show-bin-path)/cadence"; \
		for f in $(PROOF_DIR)/valid*.json; do "$$bin" verify "$$f" >/dev/null || { echo "FAIL cadence verify should pass: $$f"; exit 1; }; done; \
		for f in $(PROOF_DIR)/tampered*.json; do if "$$bin" verify "$$f" >/dev/null; then echo "FAIL cadence verify should fail: $$f"; exit 1; fi; done; \
		echo "proof vectors: python and cadence verify agree"; \
	else \
		echo "proof vectors: python verifier agrees (cadence verify not built yet)"; \
	fi

guard:
	tools/guard.sh --staged
	tools/guard.sh --install-hooks

guard-all:
	tools/guard.sh --all

hooks:
	tools/guard.sh --install-hooks

# T1.5: concurrent writers through the CLI binary keep one valid chain.
ledger-stress: build
	CADENCE_BIN="$$($(SWIFT) build -c $(CONFIG) --show-bin-path)/cadence" bash tools/tests/ledger_stress.sh

# The guard's own fixture tests.
guard-test:
	bash tools/tests/guard_test.sh

# No en or em dashes in UI copy (docs/SPEC.md section 6.6). Wired fully in T3.19.
lint:
	@if [ -x tools/lint_copy.sh ]; then tools/lint_copy.sh; else echo "SKIP lint: tools/lint_copy.sh arrives with the String Catalog (T3.19)"; fi

# The one gate before every push (docs/SPEC.md section 14.6).
check: build symbols test ledger-stress app proof-vectors guard-test guard-all lint entitlements snapshots-check
	@echo "make check: all gates passed on $(UNAME)"

demo:
	@mkdir -p "$(DEMO_HOME)"
	@bin="$$($(SWIFT) build -c $(CONFIG) --show-bin-path)/cadence"; \
	if [ -x "$$bin" ] && "$$bin" help demo >/dev/null 2>&1; then CADENCE_HOME="$(DEMO_HOME)" "$$bin" demo seed; \
	else echo "SKIP demo: the ACME seed arrives in T1.20"; fi


ifeq ($(IS_MAC),1)

app:
	@BUNDLE_PREFIX=$(BUNDLE_PREFIX) scripts/bundle.sh


entitlements: app
	@tools/tests/check_entitlements_test.sh $(BUILD_DIR)/Cadence.app
	@tools/check_entitlements.sh $(BUILD_DIR)/Cadence.app


install: app
	@scripts/install.sh


uninstall:
	@scripts/uninstall.sh


run: app
	@echo "run: dev home is $(DEV_HOME)"
	@if [ -d $(BUILD_DIR)/Cadence.app ]; then CADENCE_HOME="$(DEV_HOME)" $(BUILD_DIR)/Cadence.app/Contents/MacOS/Cadence; \
	else echo "SKIP run: build the app first with make app (T3.2)"; fi


snapshots:
	@echo "SKIP snapshots: the snapshot suite arrives in T4.9"


snapshots-check:
	@echo "SKIP snapshots: the snapshot suite arrives in T4.9"

else

app:
	@echo "SKIP app: needs macOS"

entitlements:
	@echo "SKIP entitlements: needs macOS"

install:
	@echo "SKIP install: needs macOS"

uninstall:
	@echo "SKIP uninstall: needs macOS"

run:
	@echo "SKIP run: needs macOS"

snapshots:
	@echo "SKIP snapshots: needs macOS"

snapshots-check:
	@echo "SKIP snapshots-check: needs macOS"

endif

# Renders the design tokens in both themes (T3.3). Not part of make check: it opens a window.
token-sheet:
	@if [ -z "$(IS_MAC)" ]; then echo "SKIP token-sheet: needs macOS"; exit 0; fi; \
	$(SWIFT) build -c $(CONFIG) --product CadenceTokenSheet; \
	bin="$$($(SWIFT) build -c $(CONFIG) --show-bin-path)/CadenceTokenSheet"; \
	mkdir -p docs/snapshots; \
	"$$bin" light docs/snapshots/token-sheet-light.png; \
	"$$bin" dark docs/snapshots/token-sheet-dark.png

spike:
	bash tools/spike/run.sh

sounds:
	@if [ -z "$(IS_MAC)" ]; then echo "SKIP sounds: needs macOS"; exit 0; fi; \
	if [ -f tools/make_sounds.swift ]; then $(SWIFT) tools/make_sounds.swift App/Resources/Sounds; else echo "SKIP sounds: tools/make_sounds.swift arrives in T3.14"; fi

clean:
	rm -rf .build $(BUILD_DIR)
