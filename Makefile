# swift-testing has to be found by explicit search paths when only the Command Line
# Tools are installed (no full Xcode); with Xcode present — CI, for instance — the
# directory below does not exist and SwiftPM already knows where the framework is.
DEV_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
DEV_LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
ifneq ($(wildcard $(DEV_FRAMEWORKS)),)
TEST_FLAGS := -Xswiftc -F -Xswiftc $(DEV_FRAMEWORKS) \
              -Xlinker -F -Xlinker $(DEV_FRAMEWORKS) \
              -Xlinker -rpath -Xlinker $(DEV_FRAMEWORKS) \
              -Xlinker -rpath -Xlinker $(DEV_LIB)
else
TEST_FLAGS :=
endif

.PHONY: build release test app dmg install run clean

build:
	swift build

release:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

app:
	./Scripts/build-app.sh

dmg: app
	./Scripts/build-dmg.sh

# Replaces the copy in /Applications, which is the one the login item and the menu bar
# actually launch. Quits the running instance first: the bundle cannot be swapped under
# a live process. Nothing user-owned lives inside the bundle — the token is in the
# Keychain, history in Core Data, the in-flight deadline in UserDefaults — so the
# relaunch restores the session that was running.
install: app
	-osascript -e 'quit app "Focusdoro"' >/dev/null 2>&1
	@sleep 1
	rm -rf /Applications/Focusdoro.app
	cp -R build/Focusdoro.app /Applications/Focusdoro.app
	open /Applications/Focusdoro.app

run: app
	open ./build/Focusdoro.app

clean:
	rm -rf .build build
