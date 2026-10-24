SIGN_ID ?= Apple Development
APP := build/Sanketa.app
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: test app run install verify remote-setup

test:
	swift test

app:
	swift build -c release
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	# a fresh inode: overwriting an executable in place can get it killed at exec on its cached signature
	mkdir -p /tmp/sanketa-trash && mv $(APP)/Contents/MacOS/Sanketa /tmp/sanketa-trash/Sanketa-$$$$ 2>/dev/null || true
	cp "$$(swift build -c release --show-bin-path)/Sanketa" $(APP)/Contents/MacOS/Sanketa
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	mkdir -p /tmp/sanketa-trash && mv $(APP)/Contents/Resources/Packs /tmp/sanketa-trash/Packs-$$$$ 2>/dev/null || true
	cp -R Resources/Packs $(APP)/Contents/Resources/Packs
	mkdir -p /tmp/sanketa-trash && mv $(APP)/Contents/Resources/Brand /tmp/sanketa-trash/Brand-$$$$ 2>/dev/null || true
	cp -R Resources/Brand $(APP)/Contents/Resources/Brand
	if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(APP)/Contents/Resources/; fi
	codesign --force --options runtime --timestamp=none --sign "$(SIGN_ID)" $(APP)

run:
	open $(APP)

# move the old bundle aside, then copy a fresh one: cp -R over a signed bundle overwrites the executable in place
# and leaves stale Packs files that break the sealed-resource signature
install:
	mkdir -p $(INSTALL_DIR) /tmp/sanketa-trash
	if [ -e $(INSTALL_DIR)/Sanketa.app ]; then mv $(INSTALL_DIR)/Sanketa.app /tmp/sanketa-trash/Sanketa.app-$$$$; fi
	ditto $(APP) $(INSTALL_DIR)/Sanketa.app

verify:
	@python3 -c "import plistlib,sys,os; a=sys.argv[1]; p=plistlib.load(open(a+'/Contents/Info.plist','rb')); assert p['CFBundleIdentifier']=='dev.sanketa.Sanketa'; assert os.access(a+'/Contents/MacOS/Sanketa',os.X_OK); assert os.path.isdir(a+'/Contents/Resources/Packs'); assert os.path.isfile(a+'/Contents/Resources/Brand/sanketa-mark@2x.png'); print('bundle ok')" $(APP)
	codesign --verify --strict $(APP)
	@codesign -dvv $(APP) 2>&1 | grep Authority

remote-setup:
	@if [ -z "$(HOST)" ]; then echo "usage: make remote-setup HOST=<ssh destination, e.g. me@gpubox>"; exit 2; fi
	scripts/remote-setup.sh "$(HOST)"
