SIGN_ID ?= Apple Development
APP := build/Sanketa.app

.PHONY: test app run install verify

test:
	swift test

app:
	swift build -c release
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c release --show-bin-path)/Sanketa" $(APP)/Contents/MacOS/Sanketa
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	mkdir -p /tmp/sanketa-trash && mv $(APP)/Contents/Resources/Packs /tmp/sanketa-trash/Packs-$$$$ 2>/dev/null || true
	cp -R Resources/Packs $(APP)/Contents/Resources/Packs
	if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(APP)/Contents/Resources/; fi
	codesign --force --options runtime --timestamp=none --sign "$(SIGN_ID)" $(APP)

run:
	open $(APP)

install:
	mkdir -p ~/Applications
	cp -R $(APP) ~/Applications/

verify:
	codesign --verify --deep --strict --verbose=2 $(APP) && codesign -dvv $(APP)
