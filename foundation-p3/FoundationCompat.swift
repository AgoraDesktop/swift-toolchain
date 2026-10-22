//===--- FoundationCompat.swift - spellings the overlay published ----------===//
//
// P3's compatibility shim.  The hand-written overlay published a few names that
// no ported module owns, and a program written against it names them; this file
// keeps them.  It is deliberately tiny — everything else the overlay published
// (`Data`, `Date`, `URL`, `UUID`, `IndexPath`, `TimeZone`, `Locale`, `Calendar`,
// `DateComponents`, `DateInterval`, `Decimal`, `IndexSet`, `CharacterSet`,
// `Notification`, `PersonNameComponents`, `AffineTransform`) now comes from
// FoundationEssentials or `FoundationKeptTypes.swift` with the same API.
//
// When a gate or a test names something this module does not have, the answer is
// one line here — not a new value type.

/// `NSDateFormatter` under the name Darwin's Foundation gives it.
///
/// FoundationEssentials and FoundationInternationalization ship the *styles*
/// (`Date.formatted(_:)`, `FormatStyle`) but not the class; Darwin's class is
/// `NSDateFormatter` and the overlay spelled the type alias `DateFormatter`, which
/// is the name formatter-taking code uses.
public typealias DateFormatter = NSDateFormatter

/// `Decimal("1.5")`: the unlabelled string initializer Darwin's `Decimal` has
/// (FoundationEssentials spells it `init?(string:locale:)`).
///
/// It is *not* failable — the spelling it replaces is `Decimal(_:)`, whose
/// contract is "a number or NaN", which is also what Agora's `NSDecimalNumber`
/// does with text it cannot parse.
extension Decimal {
  public init(_ value: String) {
    self = Decimal(string: value) ?? Decimal.nan
  }
}

/// `Data.range(of:options:in:)`: FoundationEssentials' `Data` has the collection
/// surface but not the *search*, which corelibs/Foundation supplies on Darwin.
/// The search is Agora's `NSData -rangeOfData:options:range:`, reached through the
/// bridge this module adopts, so there is one implementation of the predicate
/// rather than a second one here.
extension Data {
  public func range(of data: Data,
                    options: NSDataSearchOptions = NSDataSearchDefault,
                    in range: Range<Int>? = nil) -> Range<Int>? {
    let searchRange: NSRange
    if let range {
      searchRange = NSRange(location: range.lowerBound, length: range.count)
    } else {
      searchRange = NSRange(location: 0, length: count)
    }
    let found = (self as NSData).range(of: data as NSData,
                                      options: options,
                                      range: searchRange)
    if found.location == NSNotFound { return nil }
    return found.location..<(found.location + found.length)
  }
}

/// `Calendar(identifier: "gregorian")`: FoundationEssentials' `Calendar.Identifier`
/// is an enum without a literal form, while Darwin's takes one (and code written
/// against Darwin's spells it that way, including this toolchain's own gate).
/// The literal goes through the same CoreFoundation identifier table the
/// `NSCalendar` bridge uses, so `"gregorian"`, `"iso8601"`, `"roc"`, ... all work.
extension Calendar.Identifier: @retroactive ExpressibleByStringLiteral {
  public init(stringLiteral value: String) {
    self = Calendar.Identifier._fromCFIdentifier(value)
  }
}
