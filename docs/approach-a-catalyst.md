# Approach A — re-tag a Simulator build as Mac Catalyst

The simpler alternative to SimRun. An arm64 iOS-Simulator binary differs from a Mac Catalyst binary mainly in its
`LC_BUILD_VERSION` platform (IOSSIMULATOR = 7 vs MACCATALYST = 6). Re-tagging it makes dyld bind it against macOS's
own iOS frameworks in `/System/iOSSupport`, which render through WindowServer like any Mac app. No recompilation.

    catalyst/sim2mac.sh Foo.app FooMac.app      # retags the executable + embedded frameworks, Mac bundle layout, ad-hoc signs
    open FooMac.app

What it does: copies resources into `Contents/Resources`, frameworks into `Contents/Frameworks`, sets
`CFBundleSupportedPlatforms = MacOSX`, runs `vtool -set-build-version maccatalyst 17.0 27.0 -replace` on every Mach-O,
adds an `@executable_path/../Frameworks` rpath, and signs ad hoc.

Trade-offs versus SimRun:
- The app runs on Catalyst UIKit (Mac idiom/look), not the Simulator's iOS UIKit.
- APIs present in the iOS SDK but unavailable on Catalyst cause missing-symbol crashes at launch.
- App extensions are skipped; entitlements are dropped.
- Tested with a UIKit app and a SwiftUI app (both built from `tests/apps`).
