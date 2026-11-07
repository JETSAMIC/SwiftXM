# Contributing to SwiftXM

Thanks for the interest. SwiftXM is a focused library. The bar is "ships clean, doesn't regress, stays minimal." Patches that match that bar are welcome.

## Running the tests

```sh
swift test
```

The test target uses Swift Testing (the `import Testing` framework), not XCTest. Tests live in `Tests/SwiftXMTests/`. Add a test for any behavioral change, built from hand-constructed bytes (see `XMBuilder`) rather than binary fixtures.

Before opening a pull request, also check that the package builds cleanly:

```sh
swift build -c release -Xswiftc -warnings-as-errors
xcodebuild build -scheme SwiftXM -destination 'generic/platform=iOS' -quiet
```

## Commit style

Conventional commits in `action(noun): verb` form, lowercase, imperative mood:

```
feat(mixer): implement tremor (Txx) effect
fix(parser): handle truncated pattern data without crashing
docs(readme): clarify AVAudioEngine bridge example
test(parser): cover delta-decoded 16-bit samples
refactor(envelope): hoist point interpolation into a helper
```

Keep the subject under ~72 characters. Use the body for the *why*. Group related changes in one commit; split unrelated changes across commits.

## Pull requests

For anything non-trivial (new effect implementation, parser change, public API change), open an issue first so we can agree on shape and scope before you spend time on code. Typos, small doc fixes, and obvious bug fixes don't need an issue.

When opening a PR, ensure:

- `swift test` passes locally and the release build has zero warnings
- New public symbols have `///` doc comments
- No new dependencies (Foundation only, by design)
- The public API of `XMFile`, `XMMixer`, and `XMError` is unchanged unless explicitly discussed

## Code of conduct

Be kind. Disagree about code, not people. Maintainers reserve the right to close threads that go off the rails.
