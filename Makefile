APP := build/Sanketa.app

.PHONY: test app run install verify remote-setup

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

run:
	open $(APP)

install:
	mkdir -p ~/Applications
	cp -R $(APP) ~/Applications/

verify:
	@python3 -c "import plistlib,sys,os; a=sys.argv[1]; p=plistlib.load(open(a+'/Contents/Info.plist','rb')); assert p['CFBundleIdentifier']=='dev.sanketa.Sanketa'; assert os.access(a+'/Contents/MacOS/Sanketa',os.X_OK); assert os.path.isdir(a+'/Contents/Resources/Packs'); print('bundle ok (unsigned by design)')" $(APP)

remote-setup:
	@if [ -z "$(HOST)" ]; then echo "usage: make remote-setup HOST=<ssh destination, e.g. me@gpubox>"; exit 2; fi
	scripts/remote-setup.sh "$(HOST)"
