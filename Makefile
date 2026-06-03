# swiftplay — build & install
#
# The `swift` on many machines is a swiftly-managed toolchain whose frontend
# mismatches the macOS SDK and crashes the compiler. Pin to Xcode's toolchain.
SWIFT := env -u TOOLCHAINS xcrun --toolchain XcodeDefault swift

PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin

.PHONY: build release menubar install uninstall test clean

## build a debug binary at .build/debug/swiftplay
build:
	$(SWIFT) build --product swiftplay

## build an optimized binary at .build/release/swiftplay
release:
	$(SWIFT) build -c release --product swiftplay

## build + run the menu-bar control center (swiftplay-menubar)
menubar:
	$(SWIFT) build --product swiftplay-menubar
	.build/debug/swiftplay-menubar &

## build release + install both binaries onto your PATH
## override the location with: make install PREFIX=$$HOME/.local
install: release
	@$(SWIFT) build -c release --product swiftplay-menubar
	@mkdir -p "$(BINDIR)"
	@install -m 0755 .build/release/swiftplay "$(BINDIR)/swiftplay"
	@install -m 0755 .build/release/swiftplay-menubar "$(BINDIR)/swiftplay-menubar"
	@echo "installed swiftplay + swiftplay-menubar -> $(BINDIR)/"

uninstall:
	@rm -f "$(BINDIR)/swiftplay" "$(BINDIR)/swiftplay-menubar"
	@echo "removed swiftplay + swiftplay-menubar from $(BINDIR)"

## run the example suites (needs a Mac with Accessibility granted)
test: build
	.build/debug/swiftplay test --dir examples/rackmind-macos

clean:
	$(SWIFT) package clean
