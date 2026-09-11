ifeq (,$(DEVELOPER_DIR))
ifneq (,$(wildcard /Applications/Xcode.app/Contents/Developer))
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif
endif

PROJECT := Codenotch.xcodeproj
SCHEME  := Codenotch
DEST    := platform=macOS,arch=arm64
SAFE_APP := build/safe/Codenotch.app

.PHONY: gen build test test-ci run clean safe-signing-test safe-typecheck safe-build safe-verify

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug CODE_SIGNING_ALLOWED=NO build

test: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug CODE_SIGNING_ALLOWED=NO test

test-ci: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug test \
		CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

safe-typecheck:
	Scripts/build-safe-local.sh --typecheck

safe-signing-test:
	Scripts/test-safe-signing-selection.sh

safe-build: safe-typecheck safe-signing-test
	Scripts/build-safe-local.sh

safe-verify: safe-build
	Scripts/verify-safe-local.sh

run: safe-verify
	open "$(SAFE_APP)"

clean:
	rm -rf build DerivedData "$(PROJECT)"
