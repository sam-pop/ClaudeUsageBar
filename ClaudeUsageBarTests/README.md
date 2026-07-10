# ClaudeUsageBarTests

Unhosted (`bundle.unit-test`, no `TEST_HOST`) test bundle. It compiles the app's
sources directly, excluding `ClaudeUsageBarApp.swift` (the `@main` entry point).

Run with `make test`.

## Hard constraint: never instantiate `UsageViewModel` in tests

`UsageViewModel.init()` calls `UNUserNotificationCenter.current().requestAuthorization`
and kicks off a live network fetch. In an unhosted bundle (no host app, no bundle
identity for the notification center) `UNUserNotificationCenter` **crashes** the test
process, and the network call is nondeterministic.

Test the pure logic units under `ClaudeUsageBar/Logic/` and the model/service
helpers instead — never the view model. If a behavior only lives in `UsageViewModel`,
extract it into a pure unit first, then test that.
