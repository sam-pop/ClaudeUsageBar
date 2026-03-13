.PHONY: generate build run install clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project ClaudeUsageBar.xcodeproj -scheme ClaudeUsageBar -configuration Release build SYMROOT=build

run: build
	open build/Release/ClaudeUsageBar.app

install: build
	cp -R build/Release/ClaudeUsageBar.app /Applications/ClaudeUsageBar.app
	@echo "Installed to /Applications/ClaudeUsageBar.app"

clean:
	rm -rf build DerivedData ClaudeUsageBar.xcodeproj
