.PHONY: generate build test run install clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -configuration Release build SYMROOT=build

test: generate
	xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO

run: build
	open build/Release/ClaudeUsageBar.app

install: build
	rm -rf /Applications/ClaudeUsageBar.app
	cp -R build/Release/ClaudeUsageBar.app /Applications/
	@echo "Installed to /Applications/ClaudeUsageBar.app"

clean:
	rm -rf build DerivedData ClaudeUsageBar.xcodeproj
