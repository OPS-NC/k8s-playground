# Makefile — les quelques commandes locales de ce dépôt.
#
# Ce dépôt ne monte aucun cluster (c'est le rôle des labs Vagrant voisins) : il n'y a donc
# ici que la génération de la documentation et les validations qui tournent sans cluster.
#
#   make            la liste des cibles
#   make docs       régénère docs/index.html depuis tous les README (EN + miroirs FR)
#   make validate   tout valider (shell, YAML, doc) — sans cluster

SHELL   := /usr/bin/env bash
DOCS_OUT := docs/index.html

.DEFAULT_GOAL := help
.PHONY: help docs docs-open docs-check validate validate-shell validate-yaml validate-docs

help: ## Affiche cette aide
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1;36m%-16s\033[0m %s\n", $$1, $$2}'

# --- Documentation ----------------------------------------------------------
# `uv` installe les dépendances déclarées en PEP 723 dans build.py : rien à installer
# à la main, rien à versionner.
docs: ## Régénère docs/index.html depuis tous les README (EN + miroirs FR)
	@uv run docs/build.py

docs-open: docs ## Régénère puis ouvre la doc dans le navigateur
	@xdg-open $(DOCS_OUT) >/dev/null 2>&1 || open $(DOCS_OUT)

docs-check: ## Vérifie que chaque lien et chaque ancre interne résout (comme la CI)
	@uv run docs/build.py --strict --out /tmp/k8s-playground-doc.html >/dev/null
	@echo "✅ liens et ancres OK"

# --- Validations sans cluster -----------------------------------------------
validate-shell: ## Syntaxe de tous les scripts shell du dépôt
	@fail=0; for f in $$(find . -name '*.sh' -not -path './.git/*'); do \
	  bash -n "$$f" || { echo "❌ $$f"; fail=1; }; done; \
	  [ $$fail -eq 0 ] && echo "✅ syntaxe shell OK" || exit 1

validate-yaml: ## Analyse syntaxique de tous les manifestes YAML (kubectl, sans cluster)
	@fail=0; for f in $$(find . \( -name '*.yaml' -o -name '*.yml' \) -not -path './.git/*'); do \
	  out=$$(kubectl create --dry-run=client -f "$$f" -o name 2>&1 >/dev/null); \
	  case "$$out" in *"error parsing"*|*"error converting"*) echo "❌ $$f"; fail=1;; esac; \
	done; [ $$fail -eq 0 ] && echo "✅ YAML OK" || exit 1

validate-docs: docs-check ## Alias de docs-check (nom utilisé par la CI des labs)

validate: validate-shell validate-yaml validate-docs ## Tout valider (sans cluster)
	@echo "✅ Validation complète OK"
