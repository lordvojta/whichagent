# whichagent - build the three native helpers.
#
# No Xcode project and no signing: clang from the Command Line Tools is enough,
# which is why this ships as build-from-source. A downloaded, unsigned Mach-O
# binary trips Gatekeeper; one you compiled yourself does not.

CC      ?= clang
CFLAGS  ?= -O2 -fobjc-arc -Wall
BIN     := bin
SRC     := src

APPDIR  := $(BIN)/AgentNotify.app
APPBIN  := $(APPDIR)/Contents/MacOS/agentnotify

.PHONY: all clean install check sounds

all: $(BIN)/hitplay $(BIN)/agenthud $(BIN)/agentbar $(APPBIN)

$(BIN):
	@mkdir -p $(BIN)

# Low-latency audio. A warm AVAudioEngine held open by a daemon, rather than
# afplay per hit: afplay costs a fixed ~800ms of process startup every time.
$(BIN)/hitplay: $(SRC)/hitplay.m | $(BIN)
	$(CC) $(CFLAGS) -o $@ $< -framework Foundation -framework AVFoundation
	@echo "built hitplay"

# The on-screen banner stack. Draws its own windows, so it needs no
# notification permission at all, which is the only reason it works on a Mac
# where notification consent has been denied.
# QuartzCore is not optional: the slide-in easing uses CAMediaTimingFunction,
# which Cocoa does not pull in. Linking Cocoa alone builds cleanly right up
# until the linker, then fails on two undefined symbols.
$(BIN)/agenthud: $(SRC)/agenthud.m | $(BIN)
	$(CC) $(CFLAGS) -o $@ $< -framework Cocoa -framework QuartzCore
	@echo "built agenthud"

# The menu bar item. Accessory activation policy, so no Dock tile.
$(BIN)/agentbar: $(SRC)/agentbar.m | $(BIN)
	$(CC) $(CFLAGS) -o $@ $< -framework Cocoa
	@echo "built agentbar"

# Optional: real Notification Center banners. Needs a bundle, must be signed
# (ad-hoc is fine) and registered with LaunchServices or macOS ignores it.
$(APPBIN): $(SRC)/agentnotify.m | $(BIN)
	@mkdir -p $(APPDIR)/Contents/MacOS
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>CFBundleIdentifier</key><string>dev.whichagent.notify</string>' \
	  '  <key>CFBundleName</key><string>AgentNotify</string>' \
	  '  <key>CFBundleExecutable</key><string>agentnotify</string>' \
	  '  <key>CFBundlePackageType</key><string>APPL</string>' \
	  '  <key>LSUIElement</key><true/>' \
	  '</dict></plist>' > $(APPDIR)/Contents/Info.plist
	$(CC) $(CFLAGS) -o $@ $< -framework Cocoa -framework UserNotifications
	@codesign --force --deep --sign - $(APPDIR) >/dev/null 2>&1 || true
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
	  -f "$(PWD)/$(APPDIR)" >/dev/null 2>&1 || true
	@echo "built AgentNotify.app"

# Regenerate the chimes. Only needed to customise them; the repo ships the
# rendered wavs so a normal install needs no Python packages at all.
sounds:
	python3 sounds/generate-chime.py
	@echo "regenerated chimes (requires numpy)"

check: all
	@bash -n hooks/*.sh && echo "shell syntax ok"
	@python3 -m py_compile hooks/agent-icon.py && echo "python syntax ok"
	@node --check integrations/vscode/extension.js && echo "js syntax ok"
	@test -x $(BIN)/agenthud && test -x $(BIN)/hitplay && test -x $(BIN)/agentbar && echo "binaries present"
	@python3 -m py_compile whichagent && echo "cli syntax ok"

install: all
	./install.sh

clean:
	rm -rf $(BIN)
