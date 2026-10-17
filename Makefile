APP = promptscope.app
BIN = $(shell swift build -c release --show-bin-path)/promptscope-app

all: $(APP)

.PHONY: release
release:
	swift build -c release

$(APP): release Resources/Info.plist
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/promptscope
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - --identifier com.ngosangns.promptscope $(APP)

install: $(APP)
	rsync -a --delete $(APP)/ /Applications/$(APP)/

clean:
	rm -rf $(APP) .build

.PHONY: all install clean test

test:
	swift test
