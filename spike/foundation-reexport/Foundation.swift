// The `Foundation` module of P3, in its first shape.
//
// On Darwin `import Foundation` is one Swift module that re-exports
// FoundationEssentials (the value types, coders, formatting) and
// FoundationInternationalization (locale, calendars, formatters), and adds the
// bridging to the Objective-C classes. `swift-foundation`'s own test suites import
// `Foundation` and use the re-exported surface; building them against Agora's
// hand-written overlay does not work, because on this target `Foundation` is the
// overlay and FoundationEssentials has not arrived yet.
//
// This module is the first half of P3: re-export only, no bridging. It exists so
// the suite can run against FoundationEssentials' types. The second half — the
// bridging between those types and Agora's `NSData`/`NSDate`/`NSURL`/… — is what
// P3 adds next, and it is why this is a spike file and not `foundation-overlay/`
// yet.

@_exported import FoundationEssentials
@_exported import FoundationInternationalization

