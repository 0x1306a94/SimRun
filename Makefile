# SimRun — build everything into build/.
#   make            core components + test apps
#   make core       SimRun.app (server + launcher, simns, injected dylibs, fake SimFramebuffer) and the simapp client
#   make tests      test apps and test programs
#   make clean

BUILD   := build
BIN     := $(BUILD)/bin
LIB     := $(BUILD)/lib
APPS    := $(BUILD)/apps
TBIN    := $(BUILD)/tests

SIMCC   := xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -fobjc-arc -Wno-deprecated-declarations -Iinclude
SIMSWIFT:= xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator
MACCC   := xcrun -sdk macosx clang -arch arm64 -fobjc-arc -Wno-deprecated-declarations -Iinclude
MACSWIFT:= env -u DYLD_ROOT_PATH xcrun -sdk macosx swiftc -O
SIGN    := codesign -s - -f
HDRS    := $(wildcard include/*.h)

APP   := $(BUILD)/SimRun.app
CORE  := $(APP) $(BIN)/simapp
PARTS := $(BIN)/simrund $(BIN)/simapp $(BIN)/simns $(LIB)/rshim.dylib $(LIB)/glue.dylib $(LIB)/scenes.dylib $(LIB)/hid.dylib $(LIB)/pboard.dylib $(LIB)/drag.dylib $(LIB)/SimFramebuffer
TOOLS := $(BIN)/hostinput $(BIN)/rhost
TESTS := $(APPS)/Hello.app $(APPS)/SUI.app $(APPS)/HIDTest.app $(APPS)/Glass.app $(APPS)/DragTest.app \
         $(TBIN)/catest $(TBIN)/catest_uikit $(TBIN)/nettest $(TBIN)/nwtest $(TBIN)/fakeframes $(TBIN)/pbtest

.PHONY: all core tools tests clean $(APP)
all: core tools tests
core: $(CORE)
tools: $(TOOLS)
tests: $(TESTS)

$(BIN) $(LIB) $(APPS) $(TBIN):
	@mkdir -p $@

# ---------------------------------------------------------------- host (macOS)
SIMRUND_SRC := $(wildcard src/host/simrund/*.m) src/host/gpuhost/gpuhost.m
$(BIN)/simrund: $(SIMRUND_SRC) $(wildcard src/host/simrund/*.h) $(HDRS) | $(BIN)
	$(MACCC) -Isrc/host/simrund $(SIMRUND_SRC) -framework Cocoa -framework QuartzCore -framework IOSurface -framework Metal \
	  -framework UniformTypeIdentifiers -o $@

# App icon: the Icon Composer document compiled into Assets.car (Liquid Glass icon) and AppIcon.icns (fallback).
ICON := $(BUILD)/icon
$(ICON)/Assets.car: resources/AppIcon.icon/icon.json resources/AppIcon.icon/Assets
	@mkdir -p $(ICON)
	xcrun actool resources/AppIcon.icon --compile $(ICON) --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
	  --output-partial-info-plist $(ICON)/partial.plist >/dev/null

# SimRun.app: the server/launcher executable, helpers (simns, simapp) and the sim-side libraries.
# Assembled in a staging bundle and swapped in with a rename, so a SimRun that is running from the old bundle keeps
# its (unlinked) files instead of having them overwritten underneath it.
$(APP): $(PARTS) $(LIB)/rshim.dylib $(LIB)/glue.dylib $(LIB)/scenes.dylib $(LIB)/hid.dylib $(LIB)/pboard.dylib $(LIB)/drag.dylib $(LIB)/SimFramebuffer resources/Info.plist $(ICON)/Assets.car
	@rm -rf $(BUILD)/.SimRun.app.new $(BUILD)/.SimRun.app.old
	@mkdir -p $(BUILD)/.SimRun.app.new/Contents/MacOS $(BUILD)/.SimRun.app.new/Contents/Helpers $(BUILD)/.SimRun.app.new/Contents/Resources/lib
	@cp resources/Info.plist $(BUILD)/.SimRun.app.new/Contents/Info.plist
	@cp $(ICON)/Assets.car $(ICON)/AppIcon.icns $(BUILD)/.SimRun.app.new/Contents/Resources/
	@cp $(BIN)/simrund $(BUILD)/.SimRun.app.new/Contents/MacOS/SimRun
	@cp $(BIN)/simns $(BIN)/simapp $(BUILD)/.SimRun.app.new/Contents/Helpers/
	@cp $(LIB)/rshim.dylib $(LIB)/glue.dylib $(LIB)/scenes.dylib $(LIB)/hid.dylib $(LIB)/pboard.dylib $(LIB)/drag.dylib $(LIB)/SimFramebuffer $(BUILD)/.SimRun.app.new/Contents/Resources/lib/
	@$(SIGN) --deep $(BUILD)/.SimRun.app.new 2>/dev/null
	@if [ -d $@ ]; then mv $@ $(BUILD)/.SimRun.app.old; fi
	@mv $(BUILD)/.SimRun.app.new $@ && rm -rf $(BUILD)/.SimRun.app.old
	@echo "built $@"

$(BIN)/simapp: src/host/simapp/simapp.c $(HDRS) | $(BIN)
	xcrun -sdk macosx clang -arch arm64 -Wall -Iinclude $< -framework CoreFoundation -o $@

$(BIN)/rhost: tools/rhost.m src/host/gpuhost/gpuhost.m $(HDRS) | $(BIN)
	$(MACCC) tools/rhost.m src/host/gpuhost/gpuhost.m -framework Foundation -framework Metal -framework IOSurface -framework CoreGraphics -framework ImageIO -o $@
	@$(SIGN) $@ 2>/dev/null

$(BIN)/hostinput: tools/hostinput.swift | $(BIN)
	$(MACSWIFT) $< -o $@

# ---------------------------------------------------------------- sim side
$(BIN)/simns: src/sim/simns/simns.c $(HDRS) | $(BIN)
	xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -Wall -Wno-deprecated-declarations -Iinclude $< -framework CoreFoundation -o $@
	@$(SIGN) $@ 2>/dev/null

$(LIB)/rshim.dylib: src/sim/rshim/rshim.m $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -o $@
	@$(SIGN) $@ 2>/dev/null

$(LIB)/SimFramebuffer: src/sim/simfb/simfb.m $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -framework IOSurface -framework CoreFoundation -framework CoreGraphics -framework Metal \
	  -install_name @rpath/SimFramebuffer.framework/SimFramebuffer -o $@
	@$(SIGN) $@ 2>/dev/null

$(LIB)/glue.dylib: src/sim/glue/glue.m $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -framework QuartzCore -framework CoreGraphics -o $@
	@$(SIGN) $@ 2>/dev/null

$(LIB)/scenes.dylib: src/sim/scenes/scenes.m $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -framework UIKit -Wl,-undefined,dynamic_lookup -Wl,-w -o $@
	@$(SIGN) $@ 2>/dev/null

$(LIB)/hid.dylib: src/sim/hid/hid.m $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -framework UIKit -framework IOKit -Wl,-undefined,dynamic_lookup -Wl,-w -o $@
	@$(SIGN) $@ 2>/dev/null

$(LIB)/pboard.dylib: src/sim/pboard/pboard.m $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -o $@
	@$(SIGN) $@ 2>/dev/null

$(LIB)/drag.dylib: src/sim/drag/drag.m $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -framework UIKit -framework CoreGraphics -o $@
	@$(SIGN) $@ 2>/dev/null

# ---------------------------------------------------------------- tests
$(APPS)/Hello.app: tests/apps/hello/main.m tests/apps/hello/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/hello/Info.plist $@/
	$(SIMCC) $< -framework UIKit -o $@/Hello
	@$(SIGN) $@ 2>/dev/null

$(APPS)/SUI.app: tests/apps/swiftui/SUI.swift tests/apps/swiftui/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/swiftui/Info.plist $@/
	$(SIMSWIFT) -parse-as-library $< -o $@/SUI
	@$(SIGN) $@ 2>/dev/null

$(APPS)/Glass.app: tests/apps/glass/Glass.swift tests/apps/glass/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/glass/Info.plist $@/
	xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator -parse-as-library $< -o $@/Glass
	@$(SIGN) $@ 2>/dev/null

$(APPS)/HIDTest.app: tests/apps/hidtest/main.m tests/apps/hidtest/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/hidtest/Info.plist $@/
	$(SIMCC) $< -framework UIKit -o $@/HIDTest
	@$(SIGN) $@ 2>/dev/null

$(APPS)/DragTest.app: tests/apps/dragtest/main.m tests/apps/dragtest/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/dragtest/Info.plist $@/
	$(SIMCC) $< -framework UIKit -framework CoreGraphics -o $@/DragTest
	@$(SIGN) $@ 2>/dev/null

CATEST_FW := -framework Foundation -framework QuartzCore -framework IOSurface -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers
$(TBIN)/catest: tests/render/catest.m $(HDRS) | $(TBIN)
	$(SIMCC) $< $(CATEST_FW) -o $@
	@$(SIGN) $@ 2>/dev/null
$(TBIN)/catest_uikit: tests/render/catest.m $(HDRS) | $(TBIN)
	$(SIMCC) -DCATEST_UIKIT=1 $< $(CATEST_FW) -framework UIKit -o $@
	@$(SIGN) $@ 2>/dev/null

$(TBIN)/nettest: tests/net/nettest.m | $(TBIN)
	$(SIMCC) $< -framework Foundation -o $@
	@$(SIGN) $@ 2>/dev/null
$(TBIN)/nwtest: tests/net/nwtest.m | $(TBIN)
	$(SIMCC) $< -framework Foundation -framework Network -o $@
	@$(SIGN) $@ 2>/dev/null
$(TBIN)/pbtest: tests/pboard/pbtest.m | $(TBIN)
	$(SIMCC) $< -framework UIKit -o $@
	@$(SIGN) $@ 2>/dev/null
$(TBIN)/fakeframes: tests/viewer/fakeframes.m $(HDRS) | $(TBIN)
	$(SIMCC) $< -framework Foundation -framework IOSurface -framework CoreGraphics -o $@
	@$(SIGN) $@ 2>/dev/null

clean:
	rm -rf $(BUILD)
