SIGN_ID ?= Apple Development
RELEASE_ID ?= Developer ID Application
APP := build/Sanketa.app
INSTALL_DIR ?= $(HOME)/Applications
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
ZIP ?= dist/Sanketa-$(VERSION).zip
# notarytool credentials: a keychain profile on a Mac, or an App Store Connect API key in CI
ifneq ($(NOTARY_PROFILE),)
NOTARY_AUTH := --keychain-profile "$(NOTARY_PROFILE)"
else ifneq ($(NOTARY_KEY),)
NOTARY_AUTH := --key "$(NOTARY_KEY)" --key-id "$(NOTARY_KEY_ID)" --issuer "$(NOTARY_ISSUER_ID)"
endif

.PHONY: test bundle app release zip run install verify gatekeeper remote-setup

test:
	swift test

bundle:
	swift build -c release
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	# a fresh inode: overwriting an executable in place can get it killed at exec on its cached signature
	mkdir -p /tmp/sanketa-trash && mv $(APP)/Contents/MacOS/Sanketa /tmp/sanketa-trash/Sanketa-$$$$ 2>/dev/null || true
	cp "$$(swift build -c release --show-bin-path)/Sanketa" $(APP)/Contents/MacOS/Sanketa
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	mkdir -p /tmp/sanketa-trash && mv $(APP)/Contents/Resources/Packs /tmp/sanketa-trash/Packs-$$$$ 2>/dev/null || true
	cp -R Resources/Packs $(APP)/Contents/Resources/Packs
	if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(APP)/Contents/Resources/; fi

# SIGN_ID=- gives an ad-hoc signature, for CI only
app: bundle
	codesign --force --options runtime --timestamp=none --sign "$(SIGN_ID)" $(APP)

# Developer ID signature with a secure timestamp; notarized and stapled when NOTARY_PROFILE or NOTARY_KEY is set
release: bundle
	codesign --force --options runtime --timestamp --sign "$(RELEASE_ID)" $(APP)
	codesign --verify --strict --verbose=2 $(APP)
	$(MAKE) zip
ifneq ($(NOTARY_AUTH),)
	xcrun notarytool submit "$(ZIP)" $(NOTARY_AUTH) --wait
	xcrun stapler staple $(APP)
	$(MAKE) zip
else
	@echo "$(ZIP) has a Developer ID signature but no notarization. To notarize, run 'xcrun notarytool store-credentials sanketa-notary --apple-id <id> --team-id 7632NRC559' one time, then run 'make release NOTARY_PROFILE=sanketa-notary'."
endif

# an old zip goes to /tmp/sanketa-trash, because rm is not allowed here
zip:
	mkdir -p $(dir $(ZIP)) /tmp/sanketa-trash
	if [ -e "$(ZIP)" ]; then mv "$(ZIP)" /tmp/sanketa-trash/$(notdir $(ZIP))-$$$$; fi
	ditto -c -k --keepParent $(APP) "$(ZIP)"

run:
	open $(APP)

# move the old bundle aside, then copy a fresh one: cp -R over a signed bundle overwrites the executable in place
# and leaves stale Packs files that break the sealed-resource signature
install:
	mkdir -p $(INSTALL_DIR) /tmp/sanketa-trash
	if [ -e $(INSTALL_DIR)/Sanketa.app ]; then mv $(INSTALL_DIR)/Sanketa.app /tmp/sanketa-trash/Sanketa.app-$$$$; fi
	ditto $(APP) $(INSTALL_DIR)/Sanketa.app

verify:
	@python3 -c "import plistlib,sys,os; a=sys.argv[1]; p=plistlib.load(open(a+'/Contents/Info.plist','rb')); assert p['CFBundleIdentifier']=='dev.sanketa.Sanketa'; assert os.access(a+'/Contents/MacOS/Sanketa',os.X_OK); assert os.path.isdir(a+'/Contents/Resources/Packs'); print('bundle ok')" $(APP)
	codesign --verify --strict $(APP)
	@codesign -dvv $(APP) 2>&1 | grep Authority

# Gatekeeper's view: accepted only after notarization
gatekeeper:
	spctl -a -t exec -vv $(APP)

remote-setup:
	@if [ -z "$(HOST)" ]; then echo "usage: make remote-setup HOST=<ssh destination, e.g. me@gpubox>"; exit 2; fi
	scripts/remote-setup.sh "$(HOST)"
