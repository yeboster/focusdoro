# Full Xcode is not installed on this machine (Command Line Tools only), so the
# swift-testing framework has to be found by explicit search paths.
DEV_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
DEV_LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
TEST_FLAGS := -Xswiftc -F -Xswiftc $(DEV_FRAMEWORKS) \
              -Xlinker -F -Xlinker $(DEV_FRAMEWORKS) \
              -Xlinker -rpath -Xlinker $(DEV_FRAMEWORKS) \
              -Xlinker -rpath -Xlinker $(DEV_LIB)

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
