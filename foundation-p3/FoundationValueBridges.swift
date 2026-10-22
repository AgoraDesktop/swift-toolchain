//===--- FoundationValueBridges.swift - value types <-> Agora's classes ----===//
//
// P3's bridging layer.  FoundationEssentials declares its value types with the
// Objective-C bridge points already in place (`_ObjectiveCBridgeable`,
// `ReferenceConvertible`), but only when it is built *as Apple's framework*:
// every one of those extensions in the FE sources is inside
// `#if FOUNDATION_FRAMEWORK`, because Apple's Foundation framework is the module
// that owns both halves.  On this target there is no framework build, so the
// conformance does not exist and `data as NSData` does not compile — and the
// bridge is what makes `import Foundation` worth anything, since Agora's
// Objective-C classes are the ones that store and pass these values around.
//
// This file therefore adopts the bridge protocols *retroactively* on
// FoundationEssentials' types, exactly as the old overlay did for its own
// hand-written types.  Each bridge is a value conversion, not a view: a copy, in
// both directions.  Darwin's `Data`/`String` bridges are zero-copy because
// CoreFoundation ships `__NSSwiftData`-style holders for the Swift storage; doing
// that here is a later step, and the `_ObjectiveCBridgeable` protocol does not
// distinguish the two, so call sites do not change when it lands.
//
// Bridges written: `Data`, `Date`, `URL`, `UUID`, `IndexPath`, `Decimal`,
// `TimeZone`, `Locale`, `Calendar`, `DateComponents`, `DateInterval` — every
// FoundationEssentials value type that has an Objective-C counterpart in Agora's
// Foundation.  All of them are value conversions (copies); the two that carry a
// note are `Decimal` (a decimal string, see the comment at its bridge) and
// `Calendar` (a CoreFoundation identifier table, see the end of this file).
//
//===----------------------------------------------------------------------===//

// MARK: - Data <-> NSData

extension Data: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSData

  public func _bridgeToObjectiveC() -> NSData {
    return withUnsafeBytes { buffer in
      NSData(bytes: buffer.baseAddress, length: buffer.count)
    }
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSData,
                                                result: inout Data?) {
    if !_conditionallyBridgeFromObjectiveC(source, result: &result) {
      fatalError("Unable to bridge NSData to Data")
    }
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSData,
                                                       result: inout Data?) -> Bool {
    result = _unconditionallyBridgeFromObjectiveC(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSData?) -> Data {
    guard let source, source.length > 0, let bytes = source.bytes else { return Data() }
    return Data(bytes: bytes, count: source.length)
  }
}

// MARK: - Date <-> NSDate

extension Date: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSDate

  public func _bridgeToObjectiveC() -> NSDate {
    return NSDate(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate)
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSDate,
                                                result: inout Date?) {
    result = Date(timeIntervalSinceReferenceDate: source.timeIntervalSinceReferenceDate)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSDate,
                                                       result: inout Date?) -> Bool {
    result = Date(timeIntervalSinceReferenceDate: source.timeIntervalSinceReferenceDate)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSDate?) -> Date {
    guard let source else {
      return Date(timeIntervalSinceReferenceDate: 0)
    }
    return Date(timeIntervalSinceReferenceDate: source.timeIntervalSinceReferenceDate)
  }
}

// MARK: - URL <-> NSURL

extension URL: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSURL

  public func _bridgeToObjectiveC() -> NSURL {
    // `absoluteString` round-trips through Agora's `-initWithString:`; a URL with
    // no string form cannot exist in FoundationEssentials, so the fallback is
    // only for the impossible branch of the initializer.
    return NSURL(string: absoluteString) ?? NSURL()
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSURL,
                                                result: inout URL?) {
    result = _unconditionallyBridgeFromObjectiveC(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSURL,
                                                       result: inout URL?) -> Bool {
    result = _unconditionallyBridgeFromObjectiveC(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSURL?) -> URL {
    if let source, let url = URL(string: source.absoluteString()) {
      return url
    }
    // No NSURL at all (or an unparseable one): the empty relative reference is
    // FoundationEssentials' identity URL.
    return URL(string: "") ?? URL(fileURLWithPath: "")
  }
}

// MARK: - UUID <-> NSUUID

extension UUID: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSUUID

  public func _bridgeToObjectiveC() -> NSUUID {
    let bytes: [UInt8] = [uuid.0, uuid.1, uuid.2, uuid.3,
                          uuid.4, uuid.5, uuid.6, uuid.7,
                          uuid.8, uuid.9, uuid.10, uuid.11,
                          uuid.12, uuid.13, uuid.14, uuid.15]
    return bytes.withUnsafeBufferPointer { buffer in
      NSUUID(uuidBytes: buffer.baseAddress!)
    }
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSUUID,
                                                result: inout UUID?) {
    result = _unconditionallyBridgeFromObjectiveC(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSUUID,
                                                       result: inout UUID?) -> Bool {
    result = _unconditionallyBridgeFromObjectiveC(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSUUID?) -> UUID {
    guard let source else { return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                               0, 0, 0, 0, 0, 0, 0, 0)) }
    var bytes = [UInt8](repeating: 0, count: 16)
    bytes.withUnsafeMutableBufferPointer { buffer in
      source.getBytes(buffer.baseAddress!)
    }
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                       bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11],
                       bytes[12], bytes[13], bytes[14], bytes[15]))
  }
}

// MARK: - IndexPath <-> NSIndexPath

extension IndexPath: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSIndexPath

  public func _bridgeToObjectiveC() -> NSIndexPath {
    var indices = Array(self)
    // `+indexPathWithIndexes:length:` with a null array and length 0 is the
    // empty path; Agora's `-initWithIndex:` is the one-element form.
    if indices.isEmpty {
      return NSIndexPath(index: 0)
    }
    return indices.withUnsafeMutableBufferPointer { buffer in
      NSIndexPath(indexes: buffer.baseAddress!, length: buffer.count)
    }
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSIndexPath,
                                                result: inout IndexPath?) {
    result = _unconditionallyBridgeFromObjectiveC(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSIndexPath,
                                                       result: inout IndexPath?) -> Bool {
    result = _unconditionallyBridgeFromObjectiveC(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSIndexPath?) -> IndexPath {
    guard let source else { return IndexPath() }
    let count = source.length
    guard count > 0 else { return IndexPath() }
    var indices = [Int](repeating: 0, count: count)
    for position in 0..<count {
      indices[position] = source.index(atPosition: position)
    }
    return IndexPath(indexes: indices)
  }
}

// MARK: - Decimal <-> NSDecimalNumber

extension Decimal: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSDecimalNumber

  public func _bridgeToObjectiveC() -> NSDecimalNumber {
    return NSDecimalNumber(string: description)
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSDecimalNumber,
                                                result: inout Decimal?) {
    result = _unconditionallyBridgeFromObjectiveC(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSDecimalNumber,
                                                       result: inout Decimal?) -> Bool {
    result = _unconditionallyBridgeFromObjectiveC(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSDecimalNumber?) -> Decimal {
    guard let source else { return Decimal() }
    return Decimal(string: source.description) ?? Decimal()
  }
}

// `Decimal` crosses as a decimal *string*, and that is a decision worth stating.
//
// Apple's `NSDecimal` is a binary mantissa (`int32 exponent`, a length/flags word,
// `uint16 reserved`, `uint16 mantissa[8]`), and FoundationEssentials' `Decimal` is
// that struct — on Darwin the two are the same type, so Apple's bridge is a
// bitcast.  Agora's `NSDecimal` is *not* that layout: it is a decimal-digit
// representation (`int8 exponent`, `length`, flags, and 39 digits, least
// significant first), chosen so `NSDecimalAdd`-style arithmetic is digit
// arithmetic in this library.  Neither side exposes its components to Swift
// (`Decimal.storage` and `NSDecimal`'s fields are internal), and a bitcast between
// the two layouts would be silent corruption — the assertion in the first draft of
// this file caught exactly that.
//
// Both sides keep Apple's 38-significant-digit budget, and both print and parse
// those digits exactly, so the string is lossless for every value either type can
// hold.  What it costs is a decimal string per conversion.  A component-level
// bridge (or moving Agora's `NSDecimal` to Apple's layout) is the performance
// path, and the `_ObjectiveCBridgeable` protocol does not change if it lands.

// MARK: - TimeZone <-> NSTimeZone

extension TimeZone: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSTimeZone

  public func _bridgeToObjectiveC() -> NSTimeZone {
    // `NSTimeZone +timeZoneWithName:` answers nil for an unknown name; a
    // FoundationEssentials `TimeZone` cannot exist without one, so the GMT
    // fallback is the impossible branch.
    return NSTimeZone(name: identifier) ?? NSTimeZone(name: "GMT")!
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSTimeZone,
                                                result: inout TimeZone?) {
    result = _unconditionallyBridgeFromObjectiveC(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSTimeZone,
                                                       result: inout TimeZone?) -> Bool {
    result = _unconditionallyBridgeFromObjectiveC(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSTimeZone?) -> TimeZone {
    if let source, let zone = TimeZone(identifier: source.name()) {
      return zone
    }
    return TimeZone(identifier: "GMT")!
  }
}

// MARK: - Locale <-> NSLocale

extension Locale: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSLocale

  public func _bridgeToObjectiveC() -> NSLocale {
    // `+localeWithLocaleIdentifier:` is the failable door (an identifier the
    // library does not know answers nil); `-initWithLocaleIdentifier:` is not.
    return NSLocale(localeIdentifier: identifier)
      ?? NSLocale(localeIdentifier: "en_US_POSIX")
      ?? NSLocale.system()
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSLocale,
                                                result: inout Locale?) {
    result = _unconditionallyBridgeFromObjectiveC(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSLocale,
                                                       result: inout Locale?) -> Bool {
    result = _unconditionallyBridgeFromObjectiveC(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSLocale?) -> Locale {
    if let source {
      return Locale(identifier: source.localeIdentifier())
    }
    return Locale(identifier: "")
  }
}

// MARK: - Calendar <-> NSCalendar

extension Calendar: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSCalendar

  public func _bridgeToObjectiveC() -> NSCalendar {
    let calendar = NSCalendar(identifier: identifier._cfIdentifier) ?? NSCalendar(identifier: "gregorian")!
    calendar.setTimeZone(timeZone as NSTimeZone)
    if let locale {
      calendar.setLocale(locale as NSLocale)
    }
    calendar.setFirstWeekday(firstWeekday)
    calendar.setMinimumDaysInFirstWeek(minimumDaysInFirstWeek)
    return calendar
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSCalendar,
                                                result: inout Calendar?) {
    result = _unconditionallyBridgeFromObjectiveC(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSCalendar,
                                                       result: inout Calendar?) -> Bool {
    result = _unconditionallyBridgeFromObjectiveC(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSCalendar?) -> Calendar {
    guard let source else {
      return Calendar(identifier: .gregorian)
    }
    var calendar = Calendar(identifier: Calendar.Identifier._fromCFIdentifier(source.calendarIdentifier()))
    calendar.timeZone = source.timeZone() as TimeZone
    calendar.locale = source.locale() as Locale
    calendar.firstWeekday = source.firstWeekday()
    calendar.minimumDaysInFirstWeek = source.minimumDaysInFirstWeek()
    return calendar
  }
}

// MARK: - DateComponents <-> NSDateComponents

extension DateComponents: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSDateComponents

  public func _bridgeToObjectiveC() -> NSDateComponents {
    let components = NSDateComponents()
    // `NSDateComponents` uses `NSDateComponentUndefined` (NSIntegerMax) for "not
    // set"; FoundationEssentials models the same thing as `nil`.  A `nil` field
    // is therefore *not* written: `NSDateComponents` starts out undefined.
    if let calendar { components.setCalendar(calendar as NSCalendar) }
    if let timeZone { components.setTimeZone(timeZone as NSTimeZone) }
    if let era { components.setEra(era) }
    if let year { components.setYear(year) }
    if let month { components.setMonth(month) }
    if let day { components.setDay(day) }
    if let hour { components.setHour(hour) }
    if let minute { components.setMinute(minute) }
    if let second { components.setSecond(second) }
    if let nanosecond { components.setNanosecond(nanosecond) }
    if let weekday { components.setWeekday(weekday) }
    if let weekdayOrdinal { components.setWeekdayOrdinal(weekdayOrdinal) }
    if let quarter { components.setQuarter(quarter) }
    if let weekOfMonth { components.setWeekOfMonth(weekOfMonth) }
    if let weekOfYear { components.setWeekOfYear(weekOfYear) }
    if let yearForWeekOfYear { components.setYearForWeekOfYear(yearForWeekOfYear) }
    return components
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSDateComponents,
                                                result: inout DateComponents?) {
    result = _unconditionallyBridgeFromObjectiveC(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSDateComponents,
                                                       result: inout DateComponents?) -> Bool {
    result = _unconditionallyBridgeFromObjectiveC(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSDateComponents?) -> DateComponents {
    guard let source else { return DateComponents() }
    var components = DateComponents()
    // NSDateComponents answers `NSDateComponentUndefined` for a field that was
    // never set; FoundationEssentials spells that `nil`.
    let undefined = NSDateComponentUndefined
    if let calendar = source.calendar() { components.calendar = calendar as Calendar }
    if let timeZone = source.timeZone() { components.timeZone = timeZone as TimeZone }
    let era = source.era();           if era != undefined { components.era = era }
    let year = source.year();         if year != undefined { components.year = year }
    let month = source.month();       if month != undefined { components.month = month }
    let day = source.day();           if day != undefined { components.day = day }
    let hour = source.hour();         if hour != undefined { components.hour = hour }
    let minute = source.minute();     if minute != undefined { components.minute = minute }
    let second = source.second();     if second != undefined { components.second = second }
    let nanosecond = source.nanosecond()
    if nanosecond != undefined { components.nanosecond = nanosecond }
    let weekday = source.weekday();   if weekday != undefined { components.weekday = weekday }
    let weekdayOrdinal = source.weekdayOrdinal()
    if weekdayOrdinal != undefined { components.weekdayOrdinal = weekdayOrdinal }
    let quarter = source.quarter();   if quarter != undefined { components.quarter = quarter }
    let weekOfMonth = source.weekOfMonth()
    if weekOfMonth != undefined { components.weekOfMonth = weekOfMonth }
    let weekOfYear = source.weekOfYear()
    if weekOfYear != undefined { components.weekOfYear = weekOfYear }
    let yearForWeekOfYear = source.yearForWeekOfYear()
    if yearForWeekOfYear != undefined { components.yearForWeekOfYear = yearForWeekOfYear }
    return components
  }
}

// MARK: - DateInterval <-> NSDateInterval

extension DateInterval: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSDateInterval

  public func _bridgeToObjectiveC() -> NSDateInterval {
    return NSDateInterval(start: start as NSDate, duration: duration)
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSDateInterval,
                                                result: inout DateInterval?) {
    result = _unconditionallyBridgeFromObjectiveC(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSDateInterval,
                                                       result: inout DateInterval?) -> Bool {
    result = _unconditionallyBridgeFromObjectiveC(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSDateInterval?) -> DateInterval {
    guard let source else {
      let now = Date(timeIntervalSinceReferenceDate: 0)
      return DateInterval(start: now, duration: 0)
    }
    return DateInterval(start: source.startDate as Date, duration: source.duration)
  }
}

// MARK: - Calendar identifiers

/// FoundationEssentials' `Calendar.Identifier` is the Swift enum; CoreFoundation's
/// identifier is a string (`NSCalendarIdentifier` in Agora's `NSCalendar.h`), and
/// the two agree on their spellings.  FoundationEssentials keeps its own
/// conversion `package`-internal, and its SPI accessor (available because the
/// SPI is `@_spi(SwiftCorelibsFoundation)`) covers only one direction, so this
/// table is the bridge.
///
/// (Darwin has the same table, in CoreFoundation's `CFCalendar`; the names it
/// uses are the ones below, including `roc` for the Republic of China calendar
/// and `islamic-tbla` for the tabular one.)
extension Calendar.Identifier {
  var _cfIdentifier: String {
    switch self {
    case .gregorian: return "gregorian"
    case .buddhist: return "buddhist"
    case .chinese: return "chinese"
    case .coptic: return "coptic"
    case .ethiopicAmeteMihret: return "ethiopic"
    case .ethiopicAmeteAlem: return "ethiopic-amete-alem"
    case .hebrew: return "hebrew"
    case .iso8601: return "iso8601"
    case .indian: return "indian"
    case .islamic: return "islamic"
    case .islamicCivil: return "islamic-civil"
    case .japanese: return "japanese"
    case .persian: return "persian"
    case .republicOfChina: return "roc"
    case .islamicTabular: return "islamic-tbla"
    case .islamicUmmAlQura: return "islamic-umalqura"
    case .bangla: return "bangla"
    case .gujarati: return "gujarati"
    case .kannada: return "kannada"
    case .malayalam: return "malayalam"
    case .marathi: return "marathi"
    case .odia: return "odia"
    case .tamil: return "tamil"
    case .telugu: return "telugu"
    case .vikram: return "vikram"
    case .dangi: return "dangi"
    case .vietnamese: return "vietnamese"
    @unknown default: return "gregorian"
    }
  }

  static func _fromCFIdentifier(_ identifier: String) -> Self {
    switch identifier {
    case "gregorian": return .gregorian
    case "buddhist": return .buddhist
    case "chinese": return .chinese
    case "coptic": return .coptic
    case "ethiopic": return .ethiopicAmeteMihret
    case "ethiopic-amete-alem": return .ethiopicAmeteAlem
    case "hebrew": return .hebrew
    case "iso8601": return .iso8601
    case "indian": return .indian
    case "islamic": return .islamic
    case "islamic-civil": return .islamicCivil
    case "japanese": return .japanese
    case "persian": return .persian
    case "roc": return .republicOfChina
    case "islamic-tbla": return .islamicTabular
    case "islamic-umalqura": return .islamicUmmAlQura
    case "bangla": return .bangla
    case "gujarati": return .gujarati
    case "kannada": return .kannada
    case "malayalam": return .malayalam
    case "marathi": return .marathi
    case "odia": return .odia
    case "tamil": return .tamil
    case "telugu": return .telugu
    case "vikram": return .vikram
    case "dangi": return .dangi
    case "vietnamese": return .vietnamese
    default: return .gregorian
    }
  }
}
