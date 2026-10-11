# SimRun — build everything into build/.
#   make            core components, tools and test programs
#   make core       SimRun.app (server + launcher, simns, injected dylibs, fake SimFramebuffer) and the simrun CLI
#   make test-apps  sample/test apps (build/apps)
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
CORE  := $(APP) $(BIN)/simrun
PARTS := $(BIN)/simrund $(BIN)/simrun $(BIN)/simns $(LIB)/rshim.dylib $(LIB)/glue.dylib $(LIB)/scenes.dylib $(LIB)/hid.dylib $(LIB)/pboard.dylib $(LIB)/drag.dylib $(LIB)/docpicker.dylib $(LIB)/keychain.dylib $(LIB)/webkit.dylib $(LIB)/mps.dylib $(LIB)/script.dylib $(LIB)/SimFramebuffer
TOOLS := $(BIN)/hostinput
TEST_APPS  := $(APPS)/Hello.app $(APPS)/SUI.app $(APPS)/HIDTest.app $(APPS)/Glass.app $(APPS)/DragTest.app $(APPS)/WebTest.app $(APPS)/BGDownload.app $(APPS)/PickerTest.app $(APPS)/Showcase.app
TEST_PROGS := $(TBIN)/nettest $(TBIN)/nwtest $(TBIN)/pbtest $(TBIN)/kctest $(TBIN)/loctest $(TBIN)/mpstest

.PHONY: all core tools test-apps test-programs tests clean $(APP)
all: core tools test-programs
core: $(CORE)
tools: $(TOOLS)
test-apps: $(TEST_APPS)
test-programs: $(TEST_PROGS)
tests: test-apps test-programs

$(BIN) $(LIB) $(APPS) $(TBIN):
	@mkdir -p $@

# ---------------------------------------------------------------- host (macOS)
SIMRUND_SRC := $(wildcard src/host/simrund/*.m) src/host/gpuhost/gpuhost.m
$(BIN)/simrund: $(SIMRUND_SRC) $(wildcard src/host/simrund/*.h) $(HDRS) | $(BIN)
	$(MACCC) -Isrc/host/simrund $(SIMRUND_SRC) -framework Cocoa -framework QuartzCore -framework IOSurface -framework Metal \
	  -framework UniformTypeIdentifiers -framework ImageIO -o $@

# App icon: the Icon Composer document compiled into Assets.car (Liquid Glass icon) and AppIcon.icns (fallback).
ICON := $(BUILD)/icon
$(ICON)/Assets.car: resources/AppIcon.icon/icon.json resources/AppIcon.icon/Assets
	@mkdir -p $(ICON)
	xcrun actool resources/AppIcon.icon --compile $(ICON) --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
	  --output-partial-info-plist $(ICON)/partial.plist >/dev/null

# SimRun.app: the server/launcher executable, helpers (simns, simrun), the sim-side libraries and the agent skill.
# Assembled in a staging bundle and swapped in with a rename, so a SimRun that is running from the old bundle keeps
# its (unlinked) files instead of having them overwritten underneath it.
SKILL_FILES := $(shell find skills -type f ! -name .DS_Store)
$(APP): $(SKILL_FILES) $(PARTS) $(LIB)/rshim.dylib $(LIB)/glue.dylib $(LIB)/scenes.dylib $(LIB)/hid.dylib $(LIB)/pboard.dylib $(LIB)/drag.dylib $(LIB)/docpicker.dylib $(LIB)/keychain.dylib $(LIB)/webkit.dylib $(LIB)/mps.dylib $(LIB)/script.dylib $(LIB)/SimFramebuffer resources/Info.plist $(ICON)/Assets.car
	@rm -rf $(BUILD)/.SimRun.app.new $(BUILD)/.SimRun.app.old
	@mkdir -p $(BUILD)/.SimRun.app.new/Contents/MacOS $(BUILD)/.SimRun.app.new/Contents/Helpers $(BUILD)/.SimRun.app.new/Contents/Resources/lib
	@cp resources/Info.plist $(BUILD)/.SimRun.app.new/Contents/Info.plist
	@cp $(ICON)/Assets.car $(ICON)/AppIcon.icns $(BUILD)/.SimRun.app.new/Contents/Resources/
	@cp $(BIN)/simrund $(BUILD)/.SimRun.app.new/Contents/MacOS/SimRun
	@cp $(BIN)/simns $(BIN)/simrun $(BUILD)/.SimRun.app.new/Contents/Helpers/
	@cp $(LIB)/rshim.dylib $(LIB)/glue.dylib $(LIB)/scenes.dylib $(LIB)/hid.dylib $(LIB)/pboard.dylib $(LIB)/drag.dylib $(LIB)/docpicker.dylib $(LIB)/keychain.dylib $(LIB)/webkit.dylib $(LIB)/mps.dylib $(LIB)/script.dylib $(LIB)/SimFramebuffer $(BUILD)/.SimRun.app.new/Contents/Resources/lib/
	@rsync -a --exclude .DS_Store skills $(BUILD)/.SimRun.app.new/Contents/Resources/
	@$(SIGN) --deep $(BUILD)/.SimRun.app.new 2>/dev/null
	@if [ -d $@ ]; then mv $@ $(BUILD)/.SimRun.app.old; fi
	@mv $(BUILD)/.SimRun.app.new $@ && rm -rf $(BUILD)/.SimRun.app.old
	@echo "built $@"

$(BIN)/simrun: src/host/simrun/simrun.m $(HDRS) | $(BIN)
	$(MACCC) -Wall $< -framework Foundation -o $@

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

# script.dylib: the native parts, and the JS modules (js/*.js) embedded as C arrays (xxd -i: core.js -> core_js[])
SCRIPT_SRC := $(wildcard src/sim/script/*.m)
SCRIPT_JS  := $(wildcard src/sim/script/js/*.js)
$(BUILD)/gen/script_js.h: $(SCRIPT_JS)
	@mkdir -p $(@D)
	@(cd src/sim/script/js && for f in *.js; do xxd -i $$f; done) > $@.tmp && mv $@.tmp $@
$(LIB)/script.dylib: $(SCRIPT_SRC) src/sim/script/script.h $(BUILD)/gen/script_js.h $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib -I$(BUILD)/gen $(SCRIPT_SRC) -framework Foundation -framework UIKit -framework CoreGraphics -o $@
	@$(SIGN) $@ 2>/dev/null

$(LIB)/pboard.dylib: src/sim/pboard/pboard.m $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -o $@
	@$(SIGN) $@ 2>/dev/null

$(LIB)/drag.dylib: src/sim/drag/drag.m $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -framework UIKit -framework CoreGraphics -o $@
	@$(SIGN) $@ 2>/dev/null

$(LIB)/docpicker.dylib: src/sim/docpicker/docpicker.m $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -framework UIKit -framework UniformTypeIdentifiers -o $@
	@$(SIGN) $@ 2>/dev/null

$(LIB)/keychain.dylib: src/sim/keychain/keychain.m $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -framework Security -o $@
	@$(SIGN) $@ 2>/dev/null

$(LIB)/webkit.dylib: src/sim/webkit/webkit.m $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -framework UIKit -o $@
	@$(SIGN) $@ 2>/dev/null

$(LIB)/mps.dylib: src/sim/mps/mps.m $(HDRS) | $(LIB)
	$(SIMCC) -dynamiclib $< -framework Foundation -framework Metal -o $@
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

$(APPS)/WebTest.app: tests/apps/webtest/main.m tests/apps/webtest/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/webtest/Info.plist $@/
	$(SIMCC) $< -framework UIKit -framework WebKit -framework QuartzCore -o $@/WebTest
	@$(SIGN) $@ 2>/dev/null

$(APPS)/PickerTest.app: tests/apps/pickertest/main.m tests/apps/pickertest/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/pickertest/Info.plist $@/
	$(SIMCC) $< -framework UIKit -framework UniformTypeIdentifiers -o $@/PickerTest
	@$(SIGN) $@ 2>/dev/null

# BGDownload: a background URLSession download. Like Xcode's simulator builds, its entitlements (application-identifier,
# which nsurlsessiond takes the client's bundle ID from on iOS 26 and earlier) go in __TEXT,__entitlements.
$(APPS)/BGDownload.app: tests/apps/bgdownload/main.m tests/apps/bgdownload/Info.plist tests/apps/bgdownload/Entitlements.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/bgdownload/Info.plist $@/
	$(SIMCC) $< -framework UIKit -Wl,-sectcreate,__TEXT,__entitlements,tests/apps/bgdownload/Entitlements.plist -o $@/BGDownload
	@$(SIGN) $@ 2>/dev/null

# Showcase: a SwiftUI tour of what works under SimRun, with its own Icon Composer icon compiled into Assets.car.
SHOWCASE_SRC := $(wildcard tests/apps/showcase/*.swift)
SHOWCASE_ICON := tests/apps/showcase/AppIcon.icon/icon.json $(wildcard tests/apps/showcase/AppIcon.icon/Assets/*)
$(APPS)/Showcase.app: $(SHOWCASE_SRC) $(SHOWCASE_ICON) tests/apps/showcase/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/showcase/Info.plist $@/
	xcrun actool tests/apps/showcase/AppIcon.icon --compile $@ --platform iphonesimulator --minimum-deployment-target 26.0 \
	  --app-icon AppIcon --output-partial-info-plist $(BUILD)/showcase-icon.plist >/dev/null
	xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios26.0-simulator -parse-as-library -O $(SHOWCASE_SRC) -o $@/Showcase
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
$(TBIN)/kctest: tests/keychain/kctest.m | $(TBIN)
	$(SIMCC) $< -framework Foundation -framework Security -o $@
	@$(SIGN) $@ 2>/dev/null
$(TBIN)/loctest: tests/locale/loctest.m | $(TBIN)
	$(SIMCC) $< -framework Foundation -o $@
	@$(SIGN) $@ 2>/dev/null
$(TBIN)/mpstest: tests/mps/mpstest.m | $(TBIN)
	$(SIMCC) $< -framework Foundation -framework Metal -framework MetalPerformanceShaders -framework MetalPerformanceShadersGraph -o $@
	@$(SIGN) $@ 2>/dev/null

clean:
	rm -rf $(BUILD)
