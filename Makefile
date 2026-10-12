.PHONY: help lint lint-fix format check setup-hooks build test
.DEFAULT_GOAL := help

help:
	@echo "Project targets:"
	@echo "  make build        Build all targets (xcodebuild, iOS Simulator)"
	@echo "  make test         Run all tests (xcodebuild, iOS Simulator)"
	@echo "  make lint         Run SwiftLint"
	@echo "  make lint-fix     Run SwiftLint --fix"
	@echo "  make format       Run SwiftFormat (modifies files)"
	@echo "  make check        Strict lint + format check (CI gate)"
	@echo "  make setup-hooks  Install pre-commit hooks"

lint:
	swiftlint

lint-fix:
	swiftlint --fix

format:
	swiftformat .

# check lints the package trees only: Examples/EluviumExample has its own
# .swiftformat and is linted once by the recursive check. A root --exclude
# would not do, because SwiftFormat applies the outermost config's excludes
# even when run inside Examples, so the recursion would lint nothing.
check:
	swiftlint --strict
	swiftformat Sources Tests Package.swift --lint
	$(MAKE) -C Examples/EluviumExample check

setup-hooks:
	git config core.hooksPath Scripts/git-hooks
	@echo "Git hooks configured to Scripts/git-hooks/"

SCHEME = Eluvium-Package
IOS_VERSION ?= 26.2
DESTINATION = platform=iOS Simulator,name=iPhone 17,OS=$(IOS_VERSION)

build:
	set -o pipefail; xcodebuild build \
	  -scheme $(SCHEME) \
	  -destination '$(DESTINATION)' \
	  -skipPackagePluginValidation \
	  -quiet \
	  CODE_SIGNING_ALLOWED=NO

test:
	set -o pipefail; xcodebuild test \
	  -scheme $(SCHEME) \
	  -destination '$(DESTINATION)' \
	  -skipPackagePluginValidation \
	  -quiet \
	  CODE_SIGNING_ALLOWED=NO
