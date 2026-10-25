# the folder of this Makefile, for the mk/ files
override MK_DIR := $(dir $(lastword $(MAKEFILE_LIST)))mk/
SIGN_ID ?= Apple Development
RELEASE_ID ?= Developer ID Application
APP := build/Sanketa.app
XCODE_DATA := build/xcode
# the same zip with a name that does not change, so releases/latest/download/Sanketa.zip always works
STABLE_ZIP := dist/Sanketa.zip

.PHONY: test test-focus test-mlx build lint shots bundle app release zip publish run relaunch install verify gatekeeper remote-setup

# Values from the command line go to recipes only through the environment ("$$FILTER"), so the shell never parses
# them. Each value must also pass this check, which reads the raw text with $(value) and so never expands it.
override SAFE_CHARS := a b c d e f g h i j k l m n o p q r s t u v w x y z A B C D E F G H I J K L M N O P Q R S T U V W X Y Z \
	0 1 2 3 4 5 6 7 8 9 _ . / -
override empty :=
override space := $(empty) $(empty)
override tab := $(empty)	$(empty)
override define newline


endef
override strip_chars = $(if $2,$(call strip_chars,$(subst $(firstword $2),,$1),$(wordlist 2,$(words $2),$2)),$1)
override blanks_marked = $(subst $(space),!,$(subst $(tab),!,$(subst $(newline),!,$1)))
override check_var = $(if $(call strip_chars,$(call blanks_marked,$(value $1)),$2),$(error $1 has a character that is not safe. Use only letters, digits and _ . / -))
# a value that starts with - would be read as an option (ssh -oProxyCommand=…)
override check_dash = $(if $(filter -%,$(value $1)),$(error $1 must not start with -))
# identity names such as "Apple Development: Name (TEAM)": spaces are safe in them, tabs and new lines are not
override check_identity = $(if $(call strip_chars,$(subst $(space),,$(subst $(tab),!,$(subst $(newline),!,$(value $1)))),$(SAFE_CHARS) ( ) :),$(error $1 has a character that is not safe. Use only letters, digits, spaces and _ . / - ( ) :))

# VERSION is checked before the ZIP default below expands it
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
$(call check_var,VERSION,$(SAFE_CHARS))$(call check_dash,VERSION)
# defaults as plain text (:=), so the check below sees no $( ) in them
ifeq ($(origin INSTALL_DIR),undefined)
INSTALL_DIR := $(HOME)/Applications
endif
ifeq ($(origin ZIP),undefined)
ZIP := dist/Sanketa-$(VERSION).zip
endif
NOTES := dist/notes-$(VERSION).md
PACKS ?= Resources/Packs
$(foreach v,FILTER PACKS SHOTS INSTALL_DIR ZIP APP XCODE_DATA STABLE_ZIP NOTES,$(call check_var,$v,$(SAFE_CHARS))$(call check_dash,$v))
$(call check_var,HOST,$(SAFE_CHARS) @ :)$(call check_dash,HOST)
$(foreach v,SIGN_ID RELEASE_ID,$(call check_identity,$v))
export FILTER PACKS SHOTS HOST INSTALL_DIR ZIP SIGN_ID RELEASE_ID

# release and publish notarize and upload, so they refuse make -n, make -i and their other forms
include $(MK_DIR)no-dry-run.mk

# FILTER=<name> runs only the tests whose names match (letters, digits and _ . / - only)
test:
	swift test $(if $(value FILTER),--filter "$$FILTER")

# also the tests that show the panel, make a window key or start a helper app: they take the focus, so run them
# only when nobody uses the Mac
test-focus:
	SANKETA_FOCUS_TESTS=1 swift test $(if $(value FILTER),--filter "$$FILTER")

# the MLX tests that need the Metal shaders, which only xcodebuild compiles
test-mlx:
	xcodebuild test -scheme Sanketa-Package -destination 'platform=macOS,arch=arm64' -derivedDataPath $(XCODE_DATA) \
		-only-testing:SanketaMLXTests

build:
	swift build

# checks the bundled packs, or PACKS=<file or folder>
lint: build
	"$$(swift build --show-bin-path)/Sanketa" --lint-pack "$$PACKS"

# renders the panel scenarios to PNGs (off in make test); SHOTS=<folder> keeps them
shots:
	SANKETA_RENDER=1 $(if $(value SHOTS),SANKETA_SHOTS_OUT="$$SHOTS") swift test --filter RenderTests

# xcodebuild, not swift build: only xcodebuild compiles the MLX Metal shaders (mlx-swift_Cmlx.bundle/default.metallib).
# Coverage off and stripped, because the package scheme turns coverage on and keeps symbols.
bundle:
	xcodebuild -scheme Sanketa -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath $(XCODE_DATA) \
		CLANG_COVERAGE_MAPPING=NO DEAD_CODE_STRIPPING=YES DEPLOYMENT_POSTPROCESSING=YES \
		STRIP_INSTALLED_PRODUCT=YES build
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	# a fresh inode: overwriting an executable in place can get it killed at exec on its cached signature
	mkdir -p /tmp/sanketa-trash && mv $(APP)/Contents/MacOS/Sanketa /tmp/sanketa-trash/Sanketa-$$$$ 2>/dev/null || true
	cp $(XCODE_DATA)/Build/Products/Release/Sanketa $(APP)/Contents/MacOS/Sanketa
	# the package resource bundles, with the MLX metallib; old ones move aside so no stale file breaks the seal
	for b in $(APP)/Contents/Resources/*.bundle; do if [ -e "$$b" ]; then mv "$$b" "/tmp/sanketa-trash/$$(basename "$$b")-$$$$"; fi; done
	cp -R $(XCODE_DATA)/Build/Products/Release/*.bundle $(APP)/Contents/Resources/
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	mkdir -p /tmp/sanketa-trash && mv $(APP)/Contents/Resources/Packs /tmp/sanketa-trash/Packs-$$$$ 2>/dev/null || true
	cp -R Resources/Packs $(APP)/Contents/Resources/Packs
	mkdir -p /tmp/sanketa-trash && mv $(APP)/Contents/Resources/Brand /tmp/sanketa-trash/Brand-$$$$ 2>/dev/null || true
	cp -R Resources/Brand $(APP)/Contents/Resources/Brand
	if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(APP)/Contents/Resources/; fi

# SIGN_ID=- gives an ad-hoc signature, for CI only
app: bundle
	codesign --force --options runtime --timestamp=none --sign "$$SIGN_ID" $(APP)

# release (notarized, stapled and checked) and publish (GitHub release), with ZIP_APP
include $(MK_DIR)release.mk

zip:
	$(ZIP_APP)

run:
	open $(APP)

# asks the running Sanketa to quit, then opens the fresh build
relaunch:
	$(APP)/Contents/MacOS/Sanketa --quit-running
	open $(APP)

# move the old bundle aside, then copy a fresh one: cp -R over a signed bundle overwrites the executable in place
# and leaves stale Packs files that break the sealed-resource signature
install:
	mkdir -p "$$INSTALL_DIR" /tmp/sanketa-trash
	if [ -e "$$INSTALL_DIR/Sanketa.app" ]; then mv "$$INSTALL_DIR/Sanketa.app" /tmp/sanketa-trash/Sanketa.app-$$$$; fi
	ditto $(APP) "$$INSTALL_DIR/Sanketa.app"

verify:
	@python3 -c "import plistlib,sys,os; a=sys.argv[1]; p=plistlib.load(open(a+'/Contents/Info.plist','rb')); assert p['CFBundleIdentifier']=='dev.sanketa.Sanketa'; assert os.access(a+'/Contents/MacOS/Sanketa',os.X_OK); assert os.path.isdir(a+'/Contents/Resources/Packs'); assert os.path.isfile(a+'/Contents/Resources/Brand/sanketa-mark@2x.png'); print('bundle ok')" $(APP)
	@find $(APP)/Contents/Resources -name '*.metallib' | grep -q . || { echo "no .metallib in $(APP)"; exit 1; }
	# loads the metallib and runs a small sum on the GPU, so it needs a Mac with a Metal GPU
	$(APP)/Contents/MacOS/Sanketa --mlx-check
	codesign --verify --strict $(APP)
	@codesign -dvv $(APP) 2>&1 | grep Authority

# Gatekeeper's view: accepted only after notarization
gatekeeper:
	spctl -a -t exec -vv $(APP)

remote-setup:
	@if [ -z "$$HOST" ]; then echo "usage: make remote-setup HOST=<ssh destination, e.g. me@gpubox>"; exit 2; fi
	scripts/remote-setup.sh "$$HOST"
