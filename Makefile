# Makefile — the handful of local commands of this repository.
#
# This repository brings up no cluster (that is the neighbouring Vagrant labs' job): all it
# holds is documentation generation and the validations that run without a cluster.
#
#   make            the list of targets
#   make docs       regenerates docs/index.html from every README (EN + FR mirrors)
#   make validate   validate everything (shell, YAML, docs) — without a cluster

SHELL   := /usr/bin/env bash
DOCS_OUT := docs/index.html

.DEFAULT_GOAL := help
.PHONY: help docs docs-open docs-check validate validate-shell validate-yaml validate-docs

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1;36m%-16s\033[0m %s\n", $$1, $$2}'

# --- Documentation ----------------------------------------------------------
# `uv` installs the dependencies declared through PEP 723 in build.py: nothing to install by
# hand, nothing to version.
docs: ## Regenerate docs/index.html from every README (EN + FR mirrors)
	@uv run docs/build.py

docs-open: docs ## Regenerate then open the documentation in a browser
	@xdg-open $(DOCS_OUT) >/dev/null 2>&1 || open $(DOCS_OUT)

docs-check: ## Check that every internal link and anchor resolves (like CI does)
	@uv run docs/build.py --strict --out /tmp/k8s-playground-doc.html >/dev/null
	@echo "✅ links and anchors OK"

# --- Validations without a cluster ------------------------------------------
validate-shell: ## Syntax of every shell script in the repository
	@fail=0; for f in $$(find . -name '*.sh' -not -path './.git/*'); do \
	  bash -n "$$f" || { echo "❌ $$f"; fail=1; }; done; \
	  [ $$fail -eq 0 ] && echo "✅ shell syntax OK" || exit 1

validate-yaml: ## Parse every YAML manifest (kubectl, without a cluster)
	@fail=0; for f in $$(find . \( -name '*.yaml' -o -name '*.yml' \) -not -path './.git/*'); do \
	  out=$$(kubectl create --dry-run=client -f "$$f" -o name 2>&1 >/dev/null); \
	  case "$$out" in *"error parsing"*|*"error converting"*) echo "❌ $$f"; fail=1;; esac; \
	done; [ $$fail -eq 0 ] && echo "✅ YAML OK" || exit 1

validate-docs: docs-check ## Alias of docs-check (the name the labs' CI uses)

validate: validate-shell validate-yaml validate-docs ## Validate everything (without a cluster)
	@echo "✅ Full validation OK"
