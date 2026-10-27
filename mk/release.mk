# release and publish. The Makefile includes this after it sets APP, VERSION, ZIP, STABLE_ZIP and NOTES and checks
# them. A test makefile includes it with harmless commands in place of the ones below.

# release and publish use the version in Info.plist, and publish uploads the zip with its standard name
ifneq (,$(filter release publish,$(MAKECMDGOALS)))
ifneq (file,$(origin VERSION))
$(error release and publish use the version in Resources/Info.plist. Do not set VERSION)
endif
endif
ifneq (,$(filter publish,$(MAKECMDGOALS)))
ifneq (file,$(origin ZIP))
$(error publish uses its own zip name. Do not set ZIP)
endif
endif

# the commands; override, so that a value from the command line cannot replace them
override CODESIGN := codesign
override NOTARIZE := scripts/notarize.sh
override STAPLE := xcrun stapler staple
# fails for an app that has no stapled notarization ticket or that Gatekeeper does not accept
override CHECK_NOTARIZED = xcrun stapler validate $(APP) && spctl --assess --type execute -vv $(APP)
override GH := gh

# zips the app to $ZIP; an old zip goes to /tmp/sanketa-trash, because rm is not allowed here
override ZIP_APP = mkdir -p "$$(dirname "$$ZIP")" /tmp/sanketa-trash && \
	{ if [ -e "$$ZIP" ]; then mv "$$ZIP" "/tmp/sanketa-trash/$$(basename "$$ZIP")-$$$$"; fi; } && \
	ditto -c -k --keepParent $(APP) "$$ZIP"

# Developer ID signature with a secure timestamp, notarized and stapled. Without notary credentials release stops;
# make app and make zip give a local build that is not notarized.
release: bundle
	$(CODESIGN) --force --options runtime --timestamp --sign "$$RELEASE_ID" $(APP)
	$(CODESIGN) --verify --strict --verbose=2 $(APP)
	$(ZIP_APP)
	@$(NOTARIZE) "$$ZIP"; s=$$?; \
	if [ $$s -eq 3 ]; then echo "release stops: scripts/notarize.sh found no notary credentials, so $$ZIP is not notarized. Write ~/.config/sanketa/notary.json with key_id, issuer_id and key_path, or run 'xcrun notarytool store-credentials sanketa-notary --apple-id <id> --team-id 7632NRC559' and then 'make release NOTARY_PROFILE=sanketa-notary'." >&2; fi; \
	exit $$s
	$(STAPLE) $(APP)
	$(CHECK_NOTARIZED)
	$(ZIP_APP)

# makes the GitHub release v$(VERSION) on main with the notarized zip, and the same zip as Sanketa.zip for the
# download link. The check runs first, so the notes say "notarized" only for an app that has the ticket.
# stops before the build and the notarization when the release of this version is on GitHub already
unpublished:
	if $(GH) release view v$(VERSION) >/dev/null 2>&1; then echo "v$(VERSION) is published already. For a new release, change CFBundleShortVersionString in Resources/Info.plist." >&2; exit 1; fi

publish: unpublished release
	$(CHECK_NOTARIZED)
	printf '%s\n\n%s\n\n%s\n\n%s\n' "Sanketa $(VERSION) for macOS 26 on Apple Silicon. The app has a Developer ID signature, and Apple notarized it." \
		"To install it, unzip the file and move Sanketa.app to Applications. Then open it and allow Accessibility." \
		"Sanketa-$(VERSION).zip and Sanketa.zip are the same file. Sanketa.zip has a name that does not change, so the download link in the README always gets the latest release." \
		"Sanketa needs only the Accessibility permission. It does not monitor input. It uses the network only if you turn on OpenAI search, download the on-device model or set up the vault." > $(NOTES)
	mkdir -p /tmp/sanketa-trash
	if [ -e $(STABLE_ZIP) ]; then mv $(STABLE_ZIP) /tmp/sanketa-trash/Sanketa.zip-$$$$; fi
	cp "$$ZIP" $(STABLE_ZIP)
	$(GH) release create v$(VERSION) "$$ZIP" $(STABLE_ZIP) --target main --title "Sanketa $(VERSION)" --notes-file $(NOTES)
