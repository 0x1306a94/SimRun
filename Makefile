# SimRun — build everything into build/.
#   make            core components + test apps
#   make core       viewer, simns, injected dylibs, fake SimFramebuffer
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

CORE  := $(BIN)/viewer $(BIN)/simns $(LIB)/rshim.dylib $(LIB)/glue.dylib $(LIB)/scenes.dylib $(LIB)/hid.dylib $(LIB)/SimFramebuffer
TOOLS := $(BIN)/hostinput $(BIN)/rhost
TESTS := $(APPS)/Hello.app $(APPS)/SUI.app $(APPS)/HIDTest.app \
         $(TBIN)/catest $(TBIN)/catest_uikit $(TBIN)/nettest $(TBIN)/nwtest $(TBIN)/fakeframes

.PHONY: all core tools tests clean
all: core tools tests
core: $(CORE)
tools: $(TOOLS)
tests: $(TESTS)

$(BIN) $(LIB) $(APPS) $(TBIN):
	@mkdir -p $@

# ---------------------------------------------------------------- host (macOS)
$(BIN)/viewer: src/host/viewer/viewer.m src/host/gpuhost/gpuhost.m $(HDRS) | $(BIN)
	$(MACCC) src/host/viewer/viewer.m src/host/gpuhost/gpuhost.m -framework Cocoa -framework QuartzCore -framework IOSurface -framework Metal -o $@

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
	$(SIMCC) -dynamiclib $< -framework Foundation -framework IOSurface -framework CoreFoundation \
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

# ---------------------------------------------------------------- tests
$(APPS)/Hello.app: tests/apps/hello/main.m tests/apps/hello/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/hello/Info.plist $@/
	$(SIMCC) $< -framework UIKit -o $@/Hello
	@$(SIGN) $@ 2>/dev/null

$(APPS)/SUI.app: tests/apps/swiftui/SUI.swift tests/apps/swiftui/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/swiftui/Info.plist $@/
	$(SIMSWIFT) -parse-as-library $< -o $@/SUI
	@$(SIGN) $@ 2>/dev/null

$(APPS)/HIDTest.app: tests/apps/hidtest/main.m tests/apps/hidtest/Info.plist | $(APPS)
	@mkdir -p $@ && cp tests/apps/hidtest/Info.plist $@/
	$(SIMCC) $< -framework UIKit -o $@/HIDTest
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
$(TBIN)/fakeframes: tests/viewer/fakeframes.m $(HDRS) | $(TBIN)
	$(SIMCC) $< -framework Foundation -framework IOSurface -framework CoreGraphics -o $@
	@$(SIGN) $@ 2>/dev/null

clean:
	rm -rf $(BUILD)
