//===--- Foundation.swift - the P3 `Foundation` module --------------------===//
//
// P3's `Foundation`: one Swift module that is what `import Foundation` means on
// this target, in the arrangement Darwin uses —
//
//   * `FoundationEssentials` supplies the value types (`Data`, `Date`, `URL`,
//     `UUID`, `IndexPath`, `TimeZone`, `Locale`, `Calendar`, `DateComponents`,
//     `DateInterval`, `Decimal`), the coders, and the file/process surface;
//   * `FoundationInternationalization` supplies locale-aware formatting over ICU;
//   * this module adds what a platform Foundation adds: the value bridges to the
//     Objective-C classes (`FoundationValueBridges.swift`), the standard-library
//     bridges the stdlib leaves to the overlay (`FoundationShim.swift`), the
//     error machinery, and the Cocoa-shaped conveniences.
//
// It is built like Darwin's overlay: `-module-name Foundation
// -import-underlying-module` against Agora's Clang module of the same name, so
// the Objective-C classes (`NSData`, `NSDate`, `NSURL`, `NSObject`, ...) are part
// of the same import.  What is *not* here any more is the hand-written value
// types (`foundation-overlay/FoundationValueTypes.swift`): those came from
// FoundationEssentials, and the overlay's copies are retired.
//
// Status: P3's first slice.  The five value types FoundationEssentials does not
// provide (`Notification`, `PersonNameComponents`, `CharacterSet`, `IndexSet`,
// `AffineTransform`) still come from the old overlay and are **not** yet in this
// module; neither are the five bridges not written yet (`TimeZone`, `Locale`,
// `Calendar`, `DateComponents`, `DateInterval`).  `build-foundation-p3.sh`'s
// probe says exactly which of the six written ones work.
//
//===----------------------------------------------------------------------===//

@_exported import FoundationEssentials
@_exported import FoundationInternationalization
