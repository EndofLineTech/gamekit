SHELL := /bin/bash
DERIVED_DATA ?= .build/xcode
CONFIGURATION ?= Debug
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Gamekit.app

.PHONY: generate build core-test python-test test ui-test check run package

generate:
	xcodegen generate --spec project.yml

build: generate
	xcodebuild -project Gamekit.xcodeproj -scheme Gamekit -configuration $(CONFIGURATION) -destination 'platform=macOS,arch=arm64' -derivedDataPath "$(DERIVED_DATA)" build

core-test:
	swift test

python-test:
	python3 -m unittest discover -s tests -v

test: core-test python-test

ui-test: generate
	xcodebuild -project Gamekit.xcodeproj -scheme Gamekit -configuration $(CONFIGURATION) -destination 'platform=macOS,arch=arm64' -derivedDataPath "$(DERIVED_DATA)" test

check: test build

run: build
	open "$(APP)"

package:
	$(MAKE) build CONFIGURATION=Release
	mkdir -p .build/packages
	python3 tools/package_local.py --app "$(DERIVED_DATA)/Build/Products/Release/Gamekit.app" --output ".build/packages/Gamekit-$$(date -u +%Y%m%dT%H%M%SZ)"
