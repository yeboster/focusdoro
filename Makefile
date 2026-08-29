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

.PHONY: build release test app run clean

build:
	swift build

release:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

app:
	./Scripts/build-app.sh

run: app
	open ./build/Focusdoro.app

clean:
	rm -rf .build build
