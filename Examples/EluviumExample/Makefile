.PHONY: help lint lint-fix format check build build-clean test
.DEFAULT_GOAL := help

help:
	@echo "Project targets:"
	@echo "  make build        Compile (xcodebuild, pipefail, -quiet)"
	@echo "  make build-clean  Clean build (surfaces all warnings)"
	@echo "  make test         Run tests"
	@echo "  make lint         Run SwiftLint"
	@echo "  make lint-fix     Run SwiftLint --fix"
	@echo "  make format       Run SwiftFormat (modifies files)"
	@echo "  make check        Strict lint + format check (CI gate)"

lint:
	swiftlint

lint-fix:
	swiftlint --fix

format:
	swiftformat .

check:
	swiftlint --strict
	swiftformat --lint .

PROJECT = EluviumExample.xcodeproj

SCHEME = EluviumExample
IOS_VERSION ?= 26.2
DESTINATION = platform=iOS Simulator,name=iPhone 17,OS=$(IOS_VERSION)

build:
	set -o pipefail; xcodebuild build \
	  -project $(PROJECT) \
	  -scheme $(SCHEME) \
	  -destination '$(DESTINATION)' \
	  -skipPackagePluginValidation \
	  -quiet \
	  CODE_SIGNING_ALLOWED=NO

build-clean:
	set -o pipefail; xcodebuild clean build \
	  -project $(PROJECT) \
	  -scheme $(SCHEME) \
	  -destination '$(DESTINATION)' \
	  -skipPackagePluginValidation \
	  -quiet \
	  CODE_SIGNING_ALLOWED=NO

test:
	set -o pipefail; xcodebuild test \
	  -project $(PROJECT) \
	  -scheme $(SCHEME) \
	  -destination '$(DESTINATION)' \
	  -skipPackagePluginValidation \
	  -quiet \
	  CODE_SIGNING_ALLOWED=NO
