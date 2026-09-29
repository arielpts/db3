SHELL := /bin/sh
.DEFAULT_GOAL := help

INSTALL_DIR ?= $(HOME)/Applications
PG_CONFIG ?= pg_config
export PG_CONFIG

APP_BUNDLE := $(CURDIR)/build/DerivedData/Build/Products/Release/db3.app
INSTALLED_APP := $(INSTALL_DIR)/db3.app

.PHONY: help configure install start dev _configure _install

help:
	@printf '%s\n' \
		'Usage: make <target>' \
		'' \
		'  help       Show this help (default)' \
		'  configure  Prepare pinned PostgreSQL dependencies and generate the Xcode project' \
		'  install    Build, verify, and install db3.app' \
		'  start      Open the installed app' \
		'  dev        Build, verify, and run the local app (restart if running)' \
		'' \
		'Options:' \
		'  INSTALL_DIR  App destination (default: ~/Applications)' \
		'  PG_CONFIG    PostgreSQL 17.9 pg_config executable (default: pg_config)' \
		'' \
		'Examples:' \
		'  make configure' \
		'  make install' \
		'  make start' \
		'  make dev' \
		'  make install INSTALL_DIR=/Applications'

configure:
	@python3 Scripts/with-build-lock.py $(MAKE) --no-print-directory _configure

install:
	@python3 Scripts/with-build-lock.py $(MAKE) --no-print-directory _install

dev:
	./Scripts/dev.sh

_configure:
	@xcodebuild -version
	@if [ ! -f Vendor/PostgreSQL/manifest.json ] || \
		[ ! -f Vendor/PostgreSQL/lib/libpq.5.dylib ] || \
		[ ! -e Vendor/PostgreSQL/lib/libpq.dylib ] || \
		[ ! -f Vendor/PostgreSQL/include/libpq-fe.h ] || \
		[ ! -f Vendor/PostgreSQL/include/postgres_ext.h ] || \
		[ ! -f Vendor/PostgreSQL/include/pg_config_ext.h ] || \
		[ ! -d Vendor/PostgreSQL/licenses ]; then \
		python3 Scripts/prepare-postgres.py; \
	fi
	python3 Scripts/generate-project.py

_install: _configure
	./Scripts/build.sh
	python3 Scripts/verify-bundle.py "$(APP_BUNDLE)"
	@set -eu; \
		mkdir -p "$(INSTALL_DIR)"; \
		staging_dir=$$(mktemp -d "$(INSTALL_DIR)/.db3-install.XXXXXX"); \
		trap 'rm -rf "$$staging_dir"' EXIT; \
		ditto "$(APP_BUNDLE)" "$$staging_dir/db3.app"; \
		python3 Scripts/verify-bundle.py "$$staging_dir/db3.app"; \
		rm -rf "$(INSTALLED_APP)"; \
		mv "$$staging_dir/db3.app" "$(INSTALLED_APP)"; \
		printf 'Installed: %s\n' "$(INSTALLED_APP)"

start:
	@if [ ! -x "$(INSTALLED_APP)/Contents/MacOS/db3" ]; then \
		printf 'db3 is not installed at %s. Run make install first (with the same INSTALL_DIR).\n' "$(INSTALLED_APP)" >&2; \
		exit 1; \
	fi
	open "$(INSTALLED_APP)"
