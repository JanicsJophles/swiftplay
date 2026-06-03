# swiftplay — build & install
#
# The `swift` on many machines is a swiftly-managed toolchain whose frontend
# mismatches the macOS SDK and crashes the compiler. Pin to Xcode's toolchain.
SWIFT := env -u TOOLCHAINS xcrun --toolchain XcodeDefault swift

PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin

.PHONY: build release install uninstall test clean

## build a debug binary at .build/debug/swiftplay
build:
	$(SWIFT) build --product swiftplay

## build an optimized binary at .build/release/swiftplay
release:
	$(SWIFT) build -c release --product swiftplay

## build release + install `swiftplay` onto your PATH
## override the location with: make install PREFIX=$$HOME/.local
install: release
	@mkdir -p "$(BINDIR)"
	@install -m 0755 .build/release/swiftplay "$(BINDIR)/swiftplay"
	@echo "installed swiftplay -> $(BINDIR)/swiftplay"

uninstall:
	@rm -f "$(BINDIR)/swiftplay"
	@echo "removed $(BINDIR)/swiftplay"

## run the example suites (needs a Mac with Accessibility granted)
test: build
	.build/debug/swiftplay test --dir examples/rackmind-macos

clean:
	$(SWIFT) package clean
