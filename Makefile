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
# The snapshot suite in Tests/CadenceUITests/Snapshots (docs/SPEC.md section 14.4).
SNAPSHOT_SUITE := CadenceUITests.Snapshot
SNAPSHOT_DIR := docs/snapshots/suite
# The T3.5 CLI-to-model latency test, which runs alone: in the full run it waits behind other suites' work on the main
# actor, so its one-second budget measures them rather than the notification path.
LATENCY_SUITE := CadenceUITests.CLIWriteLatencyTests

ifeq ($(UNAME),Darwin)
IS_MAC := 1
else
IS_MAC :=
endif

.PHONY: build test test-fast check symbols vectors proof-vectors guard guard-all guard-test ledger-stress hooks lint lint-test snapshots-check latency \
        app install uninstall run demo snapshots token-sheet spike sounds sounds-test strings strings-check entitlements clean help

help:
	@echo "build test check app install uninstall run demo snapshots spike guard sounds strings clean"

build:
	$(SWIFT) build -c $(CONFIG)

# No networking in the cadence binary (docs/SPEC.md section 13.1).
symbols: build
	@bash tools/tests/check_symbols_test.sh
	@bash tools/check_symbols.sh "$$($(SWIFT) build -c $(CONFIG) --show-bin-path)/cadence"

# The snapshot suite and the latency test have their own targets in make check (snapshots-check, latency), so they do
# not run twice there. A plain `swift test` still runs them.
test:
	$(SWIFT) test --skip $(SNAPSHOT_SUITE) --skip $(LATENCY_SUITE)

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

# No en or em dashes and none of the banned words in UI copy (docs/SPEC.md section 6.6).
lint:
	@tools/lint_copy.sh

# The lint's own fixture tests (T3.19).
lint-test:
	@bash tools/tests/lint_copy_test.sh

# Regenerates App/Resources/Localizable.xcstrings from the code (docs/SPEC.md section 16). macOS with Xcode only;
# elsewhere tools/strings.sh prints SKIP.
strings:
	@SWIFT="$(SWIFT)" tools/strings.sh write

# The committed catalog is what the code extracts to, and the extractor's own fixture tests pass. Fails with "run make strings".
strings-check:
	@SWIFT="$(SWIFT)" bash tools/tests/strings_test.sh
	@SWIFT="$(SWIFT)" tools/strings.sh check

# The one gate before every push (docs/SPEC.md section 14.6).
check: build symbols test ledger-stress app proof-vectors guard-test guard-all lint-test lint strings-check sounds-test entitlements snapshots-check latency
	@echo "make check: all gates passed on $(UNAME)"

# The seed needs an empty store, so each run starts the demo home afresh; it holds only generated ACME data.
demo:
	@$(SWIFT) build -c $(CONFIG) --product cadence
	@rm -rf "$(DEMO_HOME)" && mkdir -p "$(DEMO_HOME)"
	@CADENCE_HOME="$(DEMO_HOME)" "$$($(SWIFT) build -c $(CONFIG) --show-bin-path)/cadence" demo seed


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


# Records every render of the suite as the new reference in docs/snapshots/suite: each surface in light and dark at 1x
# and 2x. Review the PNGs, then commit them.
snapshots:
	@rm -rf $(SNAPSHOT_DIR)
	@CADENCE_RECORD_SNAPSHOTS=1 $(SWIFT) test --filter $(SNAPSHOT_SUITE)
	@echo "snapshots: recorded $$(find $(SNAPSHOT_DIR) -name '*.png' | wc -l | tr -d ' ') references in $(SNAPSHOT_DIR)"


# Draws every surface again and compares it with its reference: the same size, and at most 0.5% of pixels differing by
# more than 8 of 255 in any channel. A failure writes the actual render and a diff image to a temporary folder and
# prints their paths; a missing reference fails with "Run make snapshots".
snapshots-check:
	@$(SWIFT) test --filter $(SNAPSHOT_SUITE)

latency:
	@$(SWIFT) test --filter $(LATENCY_SUITE)

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

latency:
	@echo "SKIP latency: needs macOS"

endif

# Renders every design sheet (tokens, mark, Tempo, panel, capture bar and later surfaces) in both themes.
# Not part of make check: it opens a window.
token-sheet:
	@if [ -z "$(IS_MAC)" ]; then echo "SKIP token-sheet: needs macOS"; exit 0; fi; \
	$(SWIFT) build -c $(CONFIG) --product CadenceTokenSheet; \
	bin="$$($(SWIFT) build -c $(CONFIG) --show-bin-path)/CadenceTokenSheet"; \
	mkdir -p docs/snapshots; \
	"$$bin" light docs/snapshots/token-sheet-light.png; \
	"$$bin" dark docs/snapshots/token-sheet-dark.png; \
	"$$bin" marks-light docs/snapshots/mark-states-light.png; \
	"$$bin" marks-dark docs/snapshots/mark-states-dark.png; \
	"$$bin" tempo-light docs/snapshots/tempo-poses-light.png; \
	"$$bin" tempo-dark docs/snapshots/tempo-poses-dark.png; \
	"$$bin" panels-light docs/snapshots/panel-states-light.png; \
	"$$bin" panels-dark docs/snapshots/panel-states-dark.png; \
	"$$bin" capture-light docs/snapshots/capture-bar-light.png; \
	"$$bin" capture-dark docs/snapshots/capture-bar-dark.png; \
	"$$bin" today-light docs/snapshots/today-states-light.png; \
	"$$bin" today-dark docs/snapshots/today-states-dark.png; \
	"$$bin" sheets-light docs/snapshots/sheets-light.png; \
	"$$bin" sheets-dark docs/snapshots/sheets-dark.png; \
	"$$bin" recaps-light docs/snapshots/recap-light.png; \
	"$$bin" recaps-dark docs/snapshots/recap-dark.png; \
	"$$bin" proof-light docs/snapshots/proof-light.png; \
	"$$bin" proof-dark docs/snapshots/proof-dark.png; \
	"$$bin" log-light docs/snapshots/log-inbox-light.png; \
	"$$bin" log-dark docs/snapshots/log-inbox-dark.png; \
	"$$bin" settings-light docs/snapshots/settings-light.png; \
	"$$bin" settings-dark docs/snapshots/settings-dark.png; \
	"$$bin" firstrun-light docs/snapshots/first-run-light.png; \
	"$$bin" firstrun-dark docs/snapshots/first-run-dark.png; \
	"$$bin" insights-light docs/snapshots/insights-light.png; \
	"$$bin" insights-dark docs/snapshots/insights-dark.png

spike:
	bash tools/spike/run.sh

# Regenerates App/Resources/Sounds/*.caf; the files are committed because they are build inputs (docs/SPEC.md section 5.6).
sounds:
	@if [ -z "$(IS_MAC)" ]; then echo "SKIP sounds: needs macOS"; exit 0; fi; \
	$(SWIFT) tools/make_sounds.swift App/Resources/Sounds

# T3.14: two renders are byte for byte the same, and the committed files are that render.
sounds-test:
	@SWIFT="$(SWIFT)" bash tools/tests/make_sounds_test.sh

clean:
	rm -rf .build $(BUILD_DIR)
