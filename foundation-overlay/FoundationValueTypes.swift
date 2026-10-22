//===--- FoundationValueTypes.swift - Agora's Foundation value types --------===//
//
// The Swift value types Darwin's Foundation overlay declares, bridged to the
// Objective-C classes Agora ships:
//
//   Data <-> NSData            Date <-> NSDate          URL <-> NSURL
//   UUID <-> NSUUID            IndexPath <-> NSIndexPath
//   DateComponents <-> NSDateComponents
//   DateInterval <-> NSDateInterval
//   Notification <-> NSNotification (and Notification.Name)
//   PersonNameComponents <-> NSPersonNameComponents
//   TimeZone <-> NSTimeZone    Locale <-> NSLocale      Calendar <-> NSCalendar
//   CharacterSet <-> NSCharacterSet
//   IndexSet <-> NSIndexSet    Decimal <-> NSDecimalNumber
//   AffineTransform <-> NSAffineTransform
//   NSAttributedString.Key <-> NSString
//
// Each type conforms to `_ObjectiveCBridgeable` (so `as`/`as?` and bridging at
// an imported boundary work) and carries the API surface a program actually
// calls. This is not yet every member Darwin's overlay has - the long tails
// (`Data`'s full collection API, `IndexSet`'s set algebra, `Decimal`'s
// arithmetic) are marked where they stop.
//
//===----------------------------------------------------------------------===//

// MARK: - Data

public struct Data: Equatable, Hashable {
  internal var _bytes: [UInt8]

  public init() { _bytes = [] }

  public init<S: Sequence>(_ elements: S) where S.Element == UInt8 {
    _bytes = Array(elements)
  }

  public init(repeating value: UInt8, count: Int) {
    _bytes = Array(repeating: value, count: count)
  }

  public init(_ data: NSData) {
    let count = data.length
    var bytes = [UInt8](repeating: 0, count: count)
    if count > 0 {
      bytes.withUnsafeMutableBytes { buffer in
        data.getBytes(buffer.baseAddress!, range: NSRange(location: 0, length: count))
      }
    }
    _bytes = bytes
  }

  public init?(base64Encoded string: String,
               options: NSDataBase64DecodingOptions = NSDataBase64DecodingDefault) {
    guard let data = NSData(base64EncodedString: string, options: options) else {
      return nil
    }
    self.init(data)
  }

  public var count: Int { return _bytes.count }
  public var isEmpty: Bool { return _bytes.isEmpty }

  public subscript(index: Int) -> UInt8 {
    get { return _bytes[index] }
    set { _bytes[index] = newValue }
  }

  public subscript(range: Range<Int>) -> Data {
    get { return Data(_bytes[range]) }
    set { _bytes.replaceSubrange(range, with: newValue._bytes) }
  }

  public mutating func append(_ byte: UInt8) { _bytes.append(byte) }
  public mutating func append<S: Sequence>(contentsOf bytes: S) where S.Element == UInt8 {
    _bytes.append(contentsOf: bytes)
  }
  public mutating func append(_ other: Data) { _bytes.append(contentsOf: other._bytes) }

  public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
    return try _bytes.withUnsafeBytes(body)
  }

  public mutating func withUnsafeMutableBytes<R>(
      _ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
    return try _bytes.withUnsafeMutableBytes(body)
  }

  public func base64EncodedString(options: NSDataBase64EncodingOptions = NSDataBase64EncodingDefault) -> String {
    return (self as NSData).base64EncodedString(with: options) as String
  }

  public var description: String {
    return "\(count) bytes"
  }
}

extension Data: RandomAccessCollection, MutableCollection {
  public typealias Index = Int
  public typealias Element = UInt8

  public var startIndex: Int { return 0 }
  public var endIndex: Int { return _bytes.count }
  public func index(after i: Int) -> Int { return i + 1 }
  public func index(before i: Int) -> Int { return i - 1 }
}

extension Data {
  public init(_ buffer: UnsafeRawBufferPointer) {
    _bytes = Array(buffer)
  }

  public init(bytes: UnsafeRawPointer, count: Int) {
    self.init(UnsafeRawBufferPointer(start: bytes, count: count))
  }

  public func subdata(in range: Range<Int>) -> Data {
    return Data(_bytes[range])
  }

  /// The bytes of `data` inside `range`, or nil.  `NSData` owns the search.
  public func range(of data: Data,
                    options: NSDataSearchOptions = NSDataSearchDefault,
                    in range: Range<Int>? = nil) -> Range<Int>? {
    let searched = range.map {
      NSRange(location: $0.lowerBound, length: $0.count)
    } ?? NSRange(location: 0, length: count)
    let found = (self as NSData).range(of: data as NSData,
                                       options: options,
                                       range: searched)
    guard found.location != NSNotFound else { return nil }
    return found.location..<(found.location + found.length)
  }

  public mutating func replaceSubrange<C: Collection>(
      _ subrange: Range<Int>, with newElements: C
  ) where C.Element == UInt8 {
    _bytes.replaceSubrange(subrange, with: newElements)
  }

  public mutating func insert(_ newElement: UInt8, at i: Int) {
    _bytes.insert(newElement, at: i)
  }

  @discardableResult
  public mutating func remove(at i: Int) -> UInt8 {
    return _bytes.remove(at: i)
  }

  public mutating func removeSubrange(_ range: Range<Int>) {
    _bytes.removeSubrange(range)
  }

  public mutating func removeAll(keepingCapacity: Bool = false) {
    _bytes.removeAll(keepingCapacity: keepingCapacity)
  }
}

extension Data: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSData

  public func _bridgeToObjectiveC() -> NSData {
    return _bytes.withUnsafeBufferPointer { buffer in
      NSData(bytes: buffer.baseAddress, length: buffer.count)
    }
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSData,
                                                result: inout Data?) {
    result = Data(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSData,
                                                       result: inout Data?) -> Bool {
    result = Data(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSData?) -> Data {
    guard let source else { return Data() }
    return Data(source)
  }
}

// MARK: - Date

public struct Date: Comparable, Hashable, CustomStringConvertible {
  /// Seconds since 1 January 2001 (Cocoa's reference date).
  public var timeIntervalSinceReferenceDate: Double

  public init(timeIntervalSinceReferenceDate: Double) {
    self.timeIntervalSinceReferenceDate = timeIntervalSinceReferenceDate
  }

  public init() {
    self = Date(timeIntervalSinceReferenceDate: NSDate.timeIntervalSinceReferenceDate)
  }

  /// The reference date's own interval, as a type property (Darwin has both this
  /// and the instance one above).
  public static var timeIntervalSinceReferenceDate: Double {
    return NSDate.timeIntervalSinceReferenceDate
  }

  public init(timeIntervalSince1970: Double) {
    self.init(timeIntervalSinceReferenceDate: timeIntervalSince1970 - 978307200.0)
  }

  public init(timeIntervalSinceNow: Double) {
    self.init(timeIntervalSinceReferenceDate: NSDate.timeIntervalSinceReferenceDate
                + timeIntervalSinceNow)
  }

  public var timeIntervalSince1970: Double {
    return timeIntervalSinceReferenceDate + 978307200.0
  }

  public var timeIntervalSinceNow: Double {
    return timeIntervalSinceReferenceDate - NSDate.timeIntervalSinceReferenceDate
  }

  public func timeIntervalSince(_ other: Date) -> Double {
    return timeIntervalSinceReferenceDate - other.timeIntervalSinceReferenceDate
  }

  public func addingTimeInterval(_ interval: Double) -> Date {
    return Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate + interval)
  }

  public static let distantPast = Date(timeIntervalSinceReferenceDate: -63114076800.0)
  public static let distantFuture = Date(timeIntervalSinceReferenceDate: 63113904000.0)

  public static func < (lhs: Date, rhs: Date) -> Bool {
    return lhs.timeIntervalSinceReferenceDate < rhs.timeIntervalSinceReferenceDate
  }

  public var description: String { return (self as NSDate).description }
}

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
    guard let source else { return Date(timeIntervalSinceReferenceDate: 0) }
    return Date(timeIntervalSinceReferenceDate: source.timeIntervalSinceReferenceDate)
  }
}

// MARK: - URL

public struct URL: Hashable, CustomStringConvertible {
  internal var _url: NSURL

  public init?(string: String) {
    guard let url = NSURL(string: string) else { return nil }
    _url = url
  }

  public init(fileURLWithPath path: String) {
    _url = NSURL(fileURLWithPath: path)!
  }

  internal init(_ url: NSURL) { _url = url }

  public var absoluteString: String { return _url.absoluteString() }
  public var relativeString: String { return _url.relativeString() }
  public var scheme: String? { return _url.scheme() }
  public var host: String? { return _url.host() }
  public var port: Int? {
    guard let number = _url.port() else { return nil }
    return Int(number.intValue())
  }
  public var user: String? { return _url.user() }
  public var path: String { return _url.path() }
  public var query: String? { return _url.query() }
  public var fragment: String? { return _url.fragment() }
  public var isFileURL: Bool { return _url.isFileURL() }
  public var lastPathComponent: String? { return _url.lastPathComponent() }
  public var pathExtension: String? { return _url.pathExtension() }

  public func appendingPathComponent(_ component: String) -> URL {
    return URL(_url.appendingPathComponent(component))
  }

  public func appendingPathExtension(_ ext: String) -> URL? {
    guard let url = _url.appendingPathExtension(ext) else { return nil }
    return URL(url)
  }

  public func deletingPathExtension() -> URL {
    return URL(_url.deletingPathExtension())
  }

  public func deletingLastPathComponent() -> URL {
    return URL(_url.deletingLastPathComponent())
  }

  public var standardized: URL { return URL(_url.standardized()) }

  public var description: String { return absoluteString }
}

extension URL: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSURL

  public func _bridgeToObjectiveC() -> NSURL { return _url }

  public static func _forceBridgeFromObjectiveC(_ source: NSURL,
                                                result: inout URL?) {
    result = URL(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSURL,
                                                       result: inout URL?) -> Bool {
    result = URL(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSURL?) -> URL {
    guard let source else { return URL(fileURLWithPath: "") }
    return URL(source)
  }
}

// MARK: - UUID

public struct UUID: Hashable, CustomStringConvertible {
  public var uuid: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

  public static func == (lhs: UUID, rhs: UUID) -> Bool {
    return lhs.uuidString == rhs.uuidString
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(uuidString)
  }

  public init() {
    let object = NSUUID()
    var bytes = [UInt8](repeating: 0, count: 16)
    object.getBytes(&bytes)
    self.init(bytes: bytes)
  }

  internal init(bytes: [UInt8]) {
    uuid = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6],
            bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12],
            bytes[13], bytes[14], bytes[15])
  }

  public init?(uuidString string: String) {
    guard let object = NSUUID(uuidString: string) else { return nil }
    var bytes = [UInt8](repeating: 0, count: 16)
    object.getBytes(&bytes)
    self.init(bytes: bytes)
  }

  public var uuidString: String {
    var bytes = [UInt8](repeating: 0, count: 16)
    bytes[0] = uuid.0; bytes[1] = uuid.1; bytes[2] = uuid.2; bytes[3] = uuid.3
    bytes[4] = uuid.4; bytes[5] = uuid.5; bytes[6] = uuid.6; bytes[7] = uuid.7
    bytes[8] = uuid.8; bytes[9] = uuid.9; bytes[10] = uuid.10; bytes[11] = uuid.11
    bytes[12] = uuid.12; bytes[13] = uuid.13; bytes[14] = uuid.14; bytes[15] = uuid.15
    return NSUUID(uuidBytes: bytes).uuidString()
  }

  public var description: String { return uuidString }
}

extension UUID: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSUUID

  public func _bridgeToObjectiveC() -> NSUUID {
    var bytes = [UInt8](repeating: 0, count: 16)
    bytes[0] = uuid.0; bytes[1] = uuid.1; bytes[2] = uuid.2; bytes[3] = uuid.3
    bytes[4] = uuid.4; bytes[5] = uuid.5; bytes[6] = uuid.6; bytes[7] = uuid.7
    bytes[8] = uuid.8; bytes[9] = uuid.9; bytes[10] = uuid.10; bytes[11] = uuid.11
    bytes[12] = uuid.12; bytes[13] = uuid.13; bytes[14] = uuid.14; bytes[15] = uuid.15
    return NSUUID(uuidBytes: bytes)
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
    guard let source else { return UUID(bytes: [UInt8](repeating: 0, count: 16)) }
    var bytes = [UInt8](repeating: 0, count: 16)
    source.getBytes(&bytes)
    return UUID(bytes: bytes)
  }
}

// MARK: - IndexPath

public struct IndexPath: Comparable, Hashable {
  internal var _indices: [Int]

  public init() { _indices = [] }
  public init(index: Int) { _indices = [index] }
  public init(indexes: [Int]) { _indices = indexes }

  internal init(_ path: NSIndexPath) {
    var indices = [Int](repeating: 0, count: path.length)
    if path.length > 0 {
      indices.withUnsafeMutableBufferPointer { buffer in
        path.getIndexes(buffer.baseAddress!)
      }
    }
    _indices = indices
  }

  public var length: Int { return _indices.count }

  public func appending(_ index: Int) -> IndexPath {
    return IndexPath(indexes: _indices + [index])
  }

  public func appending(_ other: IndexPath) -> IndexPath {
    return IndexPath(indexes: _indices + other._indices)
  }

  public subscript(position: Int) -> Int { return _indices[position] }
  public var item: Int? { return _indices.last }
  public var row: Int? { return _indices.last }
  public var section: Int? { return _indices.count >= 2 ? _indices[_indices.count - 2] : nil }

  public static func < (lhs: IndexPath, rhs: IndexPath) -> Bool {
    let count = min(lhs.length, rhs.length)
    for i in 0..<count where lhs[i] != rhs[i] { return lhs[i] < rhs[i] }
    return lhs.length < rhs.length
  }
}

extension IndexPath: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSIndexPath

  public func _bridgeToObjectiveC() -> NSIndexPath {
    if _indices.isEmpty { return NSIndexPath(index: 0) }
    return _indices.withUnsafeBufferPointer { buffer in
      NSIndexPath(indexes: buffer.baseAddress!, length: buffer.count)
    }
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSIndexPath,
                                                result: inout IndexPath?) {
    result = IndexPath(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSIndexPath,
                                                       result: inout IndexPath?) -> Bool {
    result = IndexPath(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSIndexPath?) -> IndexPath {
    guard let source else { return IndexPath() }
    return IndexPath(source)
  }
}

// MARK: - TimeZone, Locale, Calendar

public struct TimeZone: Hashable {
  internal var _zone: NSTimeZone

  public init(identifier: String) {
    _zone = NSTimeZone(name: identifier) ?? NSTimeZone.system()!
  }

  public init(secondsFromGMT seconds: Int) {
    _zone = NSTimeZone(forSecondsFromGMT: seconds) ?? NSTimeZone.system()!
  }

  internal init(_ zone: NSTimeZone) { _zone = zone }

  public static var current: TimeZone { return TimeZone(NSTimeZone.system()!) }
  public static var `default`: TimeZone { return current }

  public var identifier: String { return _zone.name() }
  public var secondsFromGMT: Int { return _zone.secondsFromGMT() }
  public func secondsFromGMT(for date: Date) -> Int {
    return _zone.secondsFromGMT(for: date as NSDate)
  }
  public var isDaylightSavingTime: Bool { return _zone.isDaylightSavingTime() }
}

extension TimeZone: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSTimeZone

  public func _bridgeToObjectiveC() -> NSTimeZone { return _zone }

  public static func _forceBridgeFromObjectiveC(_ source: NSTimeZone,
                                                result: inout TimeZone?) {
    result = TimeZone(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSTimeZone,
                                                       result: inout TimeZone?) -> Bool {
    result = TimeZone(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSTimeZone?) -> TimeZone {
    return TimeZone(source ?? NSTimeZone.system()!)
  }
}

public struct Locale: Hashable {
  internal var _locale: NSLocale

  public init(identifier: String) {
    _locale = NSLocale(localeIdentifier: identifier) ?? NSLocale.current()
  }

  internal init(_ locale: NSLocale) { _locale = locale }

  public static var current: Locale { return Locale(NSLocale.current()) }

  public var identifier: String { return _locale.localeIdentifier() }
  public var languageCode: String? {
    return _locale.object(forKey: NSLocaleLanguageCode) as? String
  }
  public var countryCode: String? {
    return _locale.object(forKey: NSLocaleCountryCode) as? String
  }
  public func displayName(forKey key: String, value: String) -> String? {
    return _locale.displayName(forKey: key, value: value)
  }
}

extension Locale: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSLocale

  public func _bridgeToObjectiveC() -> NSLocale { return _locale }

  public static func _forceBridgeFromObjectiveC(_ source: NSLocale,
                                                result: inout Locale?) {
    result = Locale(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSLocale,
                                                       result: inout Locale?) -> Bool {
    result = Locale(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSLocale?) -> Locale {
    return Locale(source ?? NSLocale.current())
  }
}

public struct Calendar: Hashable {
  internal var _calendar: NSCalendar

  public init(identifier: String) {
    _calendar = NSCalendar(calendarIdentifier: identifier) ?? NSCalendar.current()!
  }

  internal init(_ calendar: NSCalendar) { _calendar = calendar }

  public static var current: Calendar { return Calendar(NSCalendar.current()!) }

  public var identifier: String { return _calendar.calendarIdentifier() }
  public var timeZone: TimeZone {
    get { return TimeZone(_calendar.timeZone()) }
    set { _calendar.setTimeZone(newValue._zone) }
  }
  public var firstWeekday: Int {
    get { return _calendar.firstWeekday() }
    set { _calendar.setFirstWeekday(newValue) }
  }

  public func date(from components: DateComponents) -> Date? {
    guard let date = _calendar.date(from: components._components) else { return nil }
    return Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate)
  }

  public func dateComponents(_ components: Set<Calendar.Component>,
                             from date: Date) -> DateComponents {
    var unit: NSCalendarUnit = 0
    for component in components { unit |= component._unit }
    let result = _calendar.components(unit, from: date as NSDate)
    return DateComponents(result)
  }
}

extension Calendar: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSCalendar

  public func _bridgeToObjectiveC() -> NSCalendar { return _calendar }

  public static func _forceBridgeFromObjectiveC(_ source: NSCalendar,
                                                result: inout Calendar?) {
    result = Calendar(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSCalendar,
                                                       result: inout Calendar?) -> Bool {
    result = Calendar(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSCalendar?) -> Calendar {
    return Calendar(source ?? NSCalendar.current()!)
  }
}

extension Calendar {
  /// The calendar units Darwin names. An enum, not a struct of static values:
  /// the reference imports `.era` as an enum case, and a set of units is then an
  /// honest collection.
  public enum Component: Hashable {
    case era, year, month, day, hour, minute, second, weekday, weekOfYear

    internal var _unit: NSCalendarUnit {
      switch self {
      case .era: return NSCalendarUnit(NSCalendarUnitEra)
      case .year: return NSCalendarUnit(NSCalendarUnitYear)
      case .month: return NSCalendarUnit(NSCalendarUnitMonth)
      case .day: return NSCalendarUnit(NSCalendarUnitDay)
      case .hour: return NSCalendarUnit(NSCalendarUnitHour)
      case .minute: return NSCalendarUnit(NSCalendarUnitMinute)
      case .second: return NSCalendarUnit(NSCalendarUnitSecond)
      case .weekday: return NSCalendarUnit(NSCalendarUnitWeekday)
      case .weekOfYear: return NSCalendarUnit(NSCalendarUnitWeekOfYear)
      }
    }
  }
}

// MARK: - DateComponents

public struct DateComponents: Hashable {
  internal var _components: NSDateComponents

  public init() { _components = NSDateComponents() }
  internal init(_ components: NSDateComponents) { _components = components }

  public init(calendar: Calendar? = nil, timeZone: TimeZone? = nil,
              era: Int? = nil, year: Int? = nil, month: Int? = nil,
              day: Int? = nil, hour: Int? = nil, minute: Int? = nil,
              second: Int? = nil, nanosecond: Int? = nil,
              weekday: Int? = nil) {
    _components = NSDateComponents()
    self.calendar = calendar
    self.timeZone = timeZone
    if let era { self.era = era }
    if let year { self.year = year }
    if let month { self.month = month }
    if let day { self.day = day }
    if let hour { self.hour = hour }
    if let minute { self.minute = minute }
    if let second { self.second = second }
    if let nanosecond { self.nanosecond = nanosecond }
    if let weekday { self.weekday = weekday }
  }

  public var calendar: Calendar? {
    get { return _components.calendar().map(Calendar.init) }
    set { _components.setCalendar(newValue?._calendar) }
  }
  public var timeZone: TimeZone? {
    get { return _components.timeZone().map(TimeZone.init) }
    set { _components.setTimeZone(newValue?._zone) }
  }

  public var era: Int? {
    get { return _components.era() == NSIntegerMax ? nil : _components.era() }
    set { _components.setEra(newValue ?? NSIntegerMax) }
  }
  public var year: Int? {
    get { return _components.year() == NSIntegerMax ? nil : _components.year() }
    set { _components.setYear(newValue ?? NSIntegerMax) }
  }
  public var month: Int? {
    get { return _components.month() == NSIntegerMax ? nil : _components.month() }
    set { _components.setMonth(newValue ?? NSIntegerMax) }
  }
  public var day: Int? {
    get { return _components.day() == NSIntegerMax ? nil : _components.day() }
    set { _components.setDay(newValue ?? NSIntegerMax) }
  }
  public var hour: Int? {
    get { return _components.hour() == NSIntegerMax ? nil : _components.hour() }
    set { _components.setHour(newValue ?? NSIntegerMax) }
  }
  public var minute: Int? {
    get { return _components.minute() == NSIntegerMax ? nil : _components.minute() }
    set { _components.setMinute(newValue ?? NSIntegerMax) }
  }
  public var second: Int? {
    get { return _components.second() == NSIntegerMax ? nil : _components.second() }
    set { _components.setSecond(newValue ?? NSIntegerMax) }
  }
  public var nanosecond: Int? {
    get { return _components.nanosecond() == NSIntegerMax ? nil : _components.nanosecond() }
    set { _components.setNanosecond(newValue ?? NSIntegerMax) }
  }
  public var weekday: Int? {
    get { return _components.weekday() == NSIntegerMax ? nil : _components.weekday() }
    set { _components.setWeekday(newValue ?? NSIntegerMax) }
  }
}

extension DateComponents: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSDateComponents

  public func _bridgeToObjectiveC() -> NSDateComponents { return _components }

  public static func _forceBridgeFromObjectiveC(_ source: NSDateComponents,
                                                result: inout DateComponents?) {
    result = DateComponents(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSDateComponents,
                                                       result: inout DateComponents?) -> Bool {
    result = DateComponents(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSDateComponents?) -> DateComponents {
    return DateComponents(source ?? NSDateComponents())
  }
}

// MARK: - DateInterval

public struct DateInterval: Hashable {
  public var start: Date
  public var duration: Double

  public init(start: Date, duration: Double) {
    self.start = start
    self.duration = duration
  }

  public init(start: Date, end: Date) {
    self.start = start
    self.duration = end.timeIntervalSince(start)
  }

  internal init(_ interval: NSDateInterval) {
    start = Date(timeIntervalSinceReferenceDate: interval.startDate.timeIntervalSinceReferenceDate)
    duration = interval.duration
  }

  public var end: Date { return start.addingTimeInterval(duration) }
  public func contains(_ date: Date) -> Bool {
    let offset = date.timeIntervalSince(start)
    return offset >= 0 && offset <= duration
  }
}

extension DateInterval: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSDateInterval

  public func _bridgeToObjectiveC() -> NSDateInterval {
    return NSDateInterval(start: start as NSDate, duration: duration)
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSDateInterval,
                                                result: inout DateInterval?) {
    result = DateInterval(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSDateInterval,
                                                       result: inout DateInterval?) -> Bool {
    result = DateInterval(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSDateInterval?) -> DateInterval {
    guard let source else { return DateInterval(start: Date(timeIntervalSinceReferenceDate: 0), duration: 0) }
    return DateInterval(source)
  }
}

// MARK: - Notification

public struct Notification {
  public var name: Name
  public var object: Any?
  public var userInfo: [AnyHashable: Any]?

  public init(name: Name, object: Any? = nil, userInfo: [AnyHashable: Any]? = nil) {
    self.name = name
    self.object = object
    self.userInfo = userInfo
  }

  internal init(_ notification: NSNotification) {
    name = notification.name
    object = notification.object
    userInfo = notification.userInfo
  }
}

extension Notification {
  /// `NSNotificationName` is a `NS_TYPED_EXTENSIBLE_ENUM` in Agora's headers
  /// now, so the importer gives it the struct wrapper (and the automatic
  /// `_ObjectiveCBridgeable`) Darwin's Foundation uses; `Notification.Name` is
  /// the same type under the name Swift spells.
  public typealias Name = NSNotificationName
}

extension Notification: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSNotification

  public func _bridgeToObjectiveC() -> NSNotification {
    return NSNotification(name: name, object: object, userInfo: userInfo)
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSNotification,
                                                result: inout Notification?) {
    result = Notification(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSNotification,
                                                       result: inout Notification?) -> Bool {
    result = Notification(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNotification?) -> Notification {
    guard let source else { return Notification(name: Name(rawValue: "")) }
    return Notification(source)
  }
}


// MARK: - PersonNameComponents

public struct PersonNameComponents: Hashable {
  internal var _components: NSPersonNameComponents

  public init() { _components = NSPersonNameComponents() }
  internal init(_ components: NSPersonNameComponents) { _components = components }

  public var namePrefix: String? {
    get { return _components.namePrefix() }
    set { _components.setNamePrefix(newValue) }
  }
  public var givenName: String? {
    get { return _components.givenName() }
    set { _components.setGivenName(newValue) }
  }
  public var middleName: String? {
    get { return _components.middleName() }
    set { _components.setMiddleName(newValue) }
  }
  public var familyName: String? {
    get { return _components.familyName() }
    set { _components.setFamilyName(newValue) }
  }
  public var nameSuffix: String? {
    get { return _components.nameSuffix() }
    set { _components.setNameSuffix(newValue) }
  }
  public var nickname: String? {
    get { return _components.nickname() }
    set { _components.setNickname(newValue) }
  }
}

extension PersonNameComponents: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSPersonNameComponents

  public func _bridgeToObjectiveC() -> NSPersonNameComponents { return _components }

  public static func _forceBridgeFromObjectiveC(_ source: NSPersonNameComponents,
                                                result: inout PersonNameComponents?) {
    result = PersonNameComponents(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSPersonNameComponents,
                                                       result: inout PersonNameComponents?) -> Bool {
    result = PersonNameComponents(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSPersonNameComponents?) -> PersonNameComponents {
    return PersonNameComponents(source ?? NSPersonNameComponents())
  }
}

// MARK: - CharacterSet

public struct CharacterSet: Hashable {
  internal var _set: NSCharacterSet

  public init() { _set = NSCharacterSet(range: NSRange(location: 0, length: 0))! }
  public init(charactersIn string: String) {
    _set = NSCharacterSet(charactersIn: string)!
  }
  public init(range: Range<Int>) {
    _set = NSCharacterSet(range: NSRange(location: range.lowerBound, length: range.count))!
  }
  internal init(_ set: NSCharacterSet) { _set = set }

  public static var whitespaces: CharacterSet {
    return CharacterSet(NSCharacterSet.whitespace()!)
  }
  public static var whitespacesAndNewlines: CharacterSet {
    return CharacterSet(NSCharacterSet.whitespaceAndNewline()!)
  }
  public static var newlines: CharacterSet {
    return CharacterSet(NSCharacterSet.newline()!)
  }
  public static var decimalDigits: CharacterSet {
    return CharacterSet(NSCharacterSet.decimalDigit()!)
  }
  public static var letters: CharacterSet {
    return CharacterSet(NSCharacterSet.letter()!)
  }
  public static var alphanumerics: CharacterSet {
    return CharacterSet(NSCharacterSet.alphanumeric()!)
  }
  public static var punctuationCharacters: CharacterSet {
    return CharacterSet(NSCharacterSet.punctuation()!)
  }
  public static var controlCharacters: CharacterSet {
    return CharacterSet(NSCharacterSet.control()!)
  }
  public static var lowercaseLetters: CharacterSet {
    return CharacterSet(NSCharacterSet.lowercaseLetter()!)
  }
  public static var uppercaseLetters: CharacterSet {
    return CharacterSet(NSCharacterSet.uppercaseLetter()!)
  }
  public static var symbols: CharacterSet {
    return CharacterSet(NSCharacterSet.symbol()!)
  }
  public static var illegalCharacters: CharacterSet {
    return CharacterSet(NSCharacterSet.illegal()!)
  }
  public static var capitalizedLetters: CharacterSet {
    return CharacterSet(NSCharacterSet.capitalizedLetter()!)
  }
  public static var nonBaseCharacters: CharacterSet {
    return CharacterSet(NSCharacterSet.nonBase()!)
  }
  public static var decomposables: CharacterSet {
    return CharacterSet(NSCharacterSet.decomposable()!)
  }
  public static var urlUserAllowed: CharacterSet {
    return CharacterSet(NSCharacterSet.urlUserAllowed)
  }
  public static var urlPasswordAllowed: CharacterSet {
    return CharacterSet(NSCharacterSet.urlPasswordAllowed)
  }
  public static var urlHostAllowed: CharacterSet {
    return CharacterSet(NSCharacterSet.urlHostAllowed)
  }
  public static var urlPathAllowed: CharacterSet {
    return CharacterSet(NSCharacterSet.urlPathAllowed)
  }
  public static var urlQueryAllowed: CharacterSet {
    return CharacterSet(NSCharacterSet.urlQueryAllowed)
  }
  public static var urlFragmentAllowed: CharacterSet {
    return CharacterSet(NSCharacterSet.urlFragmentAllowed)
  }

  public func contains(_ member: Unicode.Scalar) -> Bool {
    return _set.longCharacterIsMember(UInt32(member.value))
  }

  public mutating func insert(charactersIn string: String) {
    let mutable = _set.mutableCopy() as! NSMutableCharacterSet
    mutable.addCharacters(in: string)
    _set = mutable
  }
}

extension CharacterSet: SetAlgebra {
  public func union(_ other: CharacterSet) -> CharacterSet {
    var result = self
    result.formUnion(other)
    return result
  }

  public func intersection(_ other: CharacterSet) -> CharacterSet {
    var result = self
    result.formIntersection(other)
    return result
  }

  public func symmetricDifference(_ other: CharacterSet) -> CharacterSet {
    var result = self
    result.formSymmetricDifference(other)
    return result
  }

  public func subtracting(_ other: CharacterSet) -> CharacterSet {
    var result = self
    result.subtract(other)
    return result
  }

  public mutating func formUnion(_ other: CharacterSet) {
    let mutable = _set.mutableCopy() as! NSMutableCharacterSet
    mutable.formUnion(with: other._set)
    _set = mutable
  }

  public mutating func formIntersection(_ other: CharacterSet) {
    let mutable = _set.mutableCopy() as! NSMutableCharacterSet
    mutable.formIntersection(with: other._set)
    _set = mutable
  }

  public mutating func formSymmetricDifference(_ other: CharacterSet) {
    let common = intersection(other)
    formUnion(other)
    subtract(common)
  }

  public mutating func subtract(_ other: CharacterSet) {
    let mutable = _set.mutableCopy() as! NSMutableCharacterSet
    mutable.formIntersection(with: other._set.inverted())
    _set = mutable
  }

  public mutating func insert(_ member: Unicode.Scalar)
      -> (inserted: Bool, memberAfterInsert: Unicode.Scalar) {
    let had = contains(member)
    if !had {
      let mutable = _set.mutableCopy() as! NSMutableCharacterSet
      mutable.addCharacters(in: String(member))
      _set = mutable
    }
    return (!had, member)
  }

  public mutating func remove(_ member: Unicode.Scalar) -> Unicode.Scalar? {
    guard contains(member) else { return nil }
    let mutable = _set.mutableCopy() as! NSMutableCharacterSet
    mutable.removeCharacters(in: String(member))
    _set = mutable
    return member
  }

  public mutating func update(with member: Unicode.Scalar) -> Unicode.Scalar? {
    let old = contains(member) ? member : nil
    if old == nil { _ = insert(member) }
    return old
  }
}

extension CharacterSet: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSCharacterSet

  public func _bridgeToObjectiveC() -> NSCharacterSet { return _set }

  public static func _forceBridgeFromObjectiveC(_ source: NSCharacterSet,
                                                result: inout CharacterSet?) {
    result = CharacterSet(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSCharacterSet,
                                                       result: inout CharacterSet?) -> Bool {
    result = CharacterSet(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSCharacterSet?) -> CharacterSet {
    return CharacterSet(source ?? NSCharacterSet(range: NSRange(location: 0, length: 0))!)
  }
}

// MARK: - IndexSet

public struct IndexSet: Hashable {
  internal var _set: NSIndexSet

  public init() { _set = NSIndexSet() }
  public init(integer value: Int) { _set = NSIndexSet(index: value) }
  public init(integersIn range: Range<Int>) {
    _set = NSIndexSet(indexesIn: NSRange(location: range.lowerBound, length: range.count))
  }
  internal init(_ set: NSIndexSet) { _set = set }

  public var count: Int { return _set.count }
  public var isEmpty: Bool { return _set.count == 0 }
  public var first: Int? { return _set.count == 0 ? nil : _set.firstIndex }
  public var last: Int? { return _set.count == 0 ? nil : _set.lastIndex }

  public func contains(_ value: Int) -> Bool { return _set.contains(value) }

  public mutating func insert(integersIn range: Range<Int>) {
    let mutable = _set.mutableCopy() as! NSMutableIndexSet
    mutable.add(in: NSRange(location: range.lowerBound, length: range.count))
    _set = mutable
  }
}

extension IndexSet: SetAlgebra {
  public func union(_ other: IndexSet) -> IndexSet {
    var result = self
    result.formUnion(other)
    return result
  }

  public func intersection(_ other: IndexSet) -> IndexSet {
    var result = self
    result.formIntersection(other)
    return result
  }

  public func symmetricDifference(_ other: IndexSet) -> IndexSet {
    var result = self
    result.formSymmetricDifference(other)
    return result
  }

  public func subtracting(_ other: IndexSet) -> IndexSet {
    var result = self
    result.subtract(other)
    return result
  }

  public mutating func formUnion(_ other: IndexSet) {
    let mutable = _set.mutableCopy() as! NSMutableIndexSet
    mutable.add(other._set)
    _set = mutable
  }

  public mutating func formIntersection(_ other: IndexSet) {
    let mutable = _set.mutableCopy() as! NSMutableIndexSet
    for index in self where !other._set.contains(index) {
      mutable.remove(index)
    }
    _set = mutable
  }

  public mutating func formSymmetricDifference(_ other: IndexSet) {
    let common = intersection(other)
    formUnion(other)
    subtract(common)
  }

  public mutating func subtract(_ other: IndexSet) {
    let mutable = _set.mutableCopy() as! NSMutableIndexSet
    mutable.remove(other._set)
    _set = mutable
  }

  @discardableResult
  public mutating func insert(_ member: Int) -> (inserted: Bool, memberAfterInsert: Int) {
    let had = _set.contains(member)
    if !had {
      let mutable = _set.mutableCopy() as! NSMutableIndexSet
      mutable.add(member)
      _set = mutable
    }
    return (!had, member)
  }

  public mutating func remove(_ member: Int) -> Int? {
    guard _set.contains(member) else { return nil }
    let mutable = _set.mutableCopy() as! NSMutableIndexSet
    mutable.remove(member)
    _set = mutable
    return member
  }

  public mutating func update(with member: Int) -> Int? {
    let old = _set.contains(member) ? member : nil
    if old == nil { _ = insert(member) }
    return old
  }
}

extension IndexSet {
  public init<S: Sequence>(_ sequence: S) where S.Element == Int {
    let mutable = NSMutableIndexSet()
    for index in sequence { mutable.add(index) }
    _set = mutable
  }

  public func count(in range: Range<Int>) -> Int {
    return _set.count(in: NSRange(location: range.lowerBound, length: range.count))
  }

  public func contains(integersIn range: Range<Int>) -> Bool {
    return _set.contains(in: NSRange(location: range.lowerBound, length: range.count))
  }

  public mutating func remove(integersIn range: Range<Int>) {
    let mutable = _set.mutableCopy() as! NSMutableIndexSet
    mutable.remove(in: NSRange(location: range.lowerBound, length: range.count))
    _set = mutable
  }
}

extension IndexSet: Sequence {
  public func makeIterator() -> AnyIterator<Int> {
    // Start at the first index, not at -1: `-indexGreaterThanIndex:` takes an
    // `NSUInteger`, so the -1 sentinel arrives as its unsigned bit pattern and
    // no index is greater than it (the iterator then yields nothing).
    var current: Int? = first
    let set = _set
    return AnyIterator {
      guard let index = current else { return nil }
      let next = set.indexGreaterThanIndex(index)
      current = next == NSNotFound ? nil : next
      return index
    }
  }
}

extension IndexSet: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSIndexSet

  public func _bridgeToObjectiveC() -> NSIndexSet { return _set }

  public static func _forceBridgeFromObjectiveC(_ source: NSIndexSet,
                                                result: inout IndexSet?) {
    result = IndexSet(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSIndexSet,
                                                       result: inout IndexSet?) -> Bool {
    result = IndexSet(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSIndexSet?) -> IndexSet {
    return IndexSet(source ?? NSIndexSet())
  }
}

// MARK: - Decimal

/// A base-10 number, bridged to `NSDecimalNumber`.
///
/// The storage is Agora's `NSDecimal` C struct; the arithmetic surface is
/// `Comparable` plus equality/hashing through `NSDecimalNumber`, which owns the
/// mantissa/exponent operations.
public struct Decimal: Hashable, Comparable, CustomStringConvertible {
  internal var _value: NSDecimal

  public init(_ value: Int) {
    self.init(NSDecimalNumber(string: String(value)))
  }

  public init(_ value: Double) {
    self.init(NSDecimalNumber(string: String(value)))
  }

  public init(_ value: String) {
    self.init(NSDecimalNumber(string: value))
  }

  public init(_ number: NSDecimalNumber) {
    _value = number.decimalValue()
  }

  public static func == (lhs: Decimal, rhs: Decimal) -> Bool {
    return NSDecimalNumber(decimal: lhs._value)
      .compare(NSDecimalNumber(decimal: rhs._value)) == ComparisonResult.orderedSame
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(description)
  }

  public static func < (lhs: Decimal, rhs: Decimal) -> Bool {
    return NSDecimalNumber(decimal: lhs._value)
      .compare(NSDecimalNumber(decimal: rhs._value)) == ComparisonResult.orderedAscending
  }

  public var exponent: Int { return Int(_value._exponent) }
  public var isNegative: Bool { return _value._isNegative != 0 }
  public var isNaN: Bool { return _value._isNaN != 0 }

  public var description: String {
    return NSDecimalNumber(decimal: _value).description as String
  }

  public var doubleValue: Double {
    return NSDecimalNumber(decimal: _value).doubleValue()
  }
}

extension Decimal: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSDecimalNumber

  public func _bridgeToObjectiveC() -> NSDecimalNumber {
    return NSDecimalNumber(decimal: _value)
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSDecimalNumber,
                                                result: inout Decimal?) {
    result = Decimal(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSDecimalNumber,
                                                       result: inout Decimal?) -> Bool {
    result = Decimal(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSDecimalNumber?) -> Decimal {
    return Decimal(source ?? NSDecimalNumber.zero())
  }
}

// MARK: - AffineTransform

public struct AffineTransform: Hashable {
  public var m11: Double, m12: Double, m21: Double, m22: Double
  public var tX: Double, tY: Double

  public init() { self.init(m11: 1, m12: 0, m21: 0, m22: 1, tX: 0, tY: 0) }

  public init(m11: Double, m12: Double, m21: Double, m22: Double,
              tX: Double, tY: Double) {
    self.m11 = m11; self.m12 = m12; self.m21 = m21; self.m22 = m22
    self.tX = tX; self.tY = tY
  }

  internal init(_ transform: NSAffineTransform) {
    let s = transform.transformStruct
    self.init(m11: s.m11, m12: s.m12, m21: s.m21, m22: s.m22, tX: s.tX, tY: s.tY)
  }

  public static let identity = AffineTransform()

  /// `self` followed by `other` - the same composition Cocoa's
  /// `-concatWithTransform:` performs (row-vector convention).
  public func concatenating(_ other: AffineTransform) -> AffineTransform {
    var result = AffineTransform()
    result.m11 = m11 * other.m11 + m12 * other.m21
    result.m12 = m11 * other.m12 + m12 * other.m22
    result.m21 = m21 * other.m11 + m22 * other.m21
    result.m22 = m21 * other.m12 + m22 * other.m22
    result.tX = tX * other.m11 + tY * other.m21 + other.tX
    result.tY = tX * other.m12 + tY * other.m22 + other.tY
    return result
  }

  internal var _struct: NSAffineTransformStruct {
    var s = NSAffineTransformStruct()
    s.m11 = m11; s.m12 = m12; s.m21 = m21; s.m22 = m22; s.tX = tX; s.tY = tY
    return s
  }
}

extension AffineTransform: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSAffineTransform

  public func _bridgeToObjectiveC() -> NSAffineTransform {
    let transform = NSAffineTransform()
    transform.transformStruct = _struct
    return transform
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSAffineTransform,
                                                result: inout AffineTransform?) {
    result = AffineTransform(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSAffineTransform,
                                                       result: inout AffineTransform?) -> Bool {
    result = AffineTransform(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSAffineTransform?) -> AffineTransform {
    guard let source else { return AffineTransform() }
    return AffineTransform(source)
  }
}

// MARK: - NSAttributedString.Key

extension NSAttributedString {
  public struct Key: RawRepresentable, Hashable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
  }
}

extension NSAttributedString.Key: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSString

  public func _bridgeToObjectiveC() -> NSString {
    return rawValue._bridgeToObjectiveC()
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSString,
                                                result: inout NSAttributedString.Key?) {
    result = NSAttributedString.Key(rawValue: String._unconditionallyBridgeFromObjectiveC(source))
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSString,
                                                       result: inout NSAttributedString.Key?) -> Bool {
    result = NSAttributedString.Key(rawValue: String._unconditionallyBridgeFromObjectiveC(source))
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSString?) -> NSAttributedString.Key {
    return NSAttributedString.Key(rawValue: String._unconditionallyBridgeFromObjectiveC(source))
  }
}

// MARK: - Date formatting and the value-type long tails

/// Darwin's Foundation defines `TimeInterval`; Agora's Clang module does not.
public typealias TimeInterval = Double

/// `NSDateFormatter` under the name Darwin's Foundation gives it.
public typealias DateFormatter = NSDateFormatter

extension Date {
  /// `Date.formatted()`: the `DateFormatter` styles, as Darwin spells them.
  public func formatted(
      date: NSDateFormatterStyle = NSDateFormatterMediumStyle,
      time: NSDateFormatterStyle = NSDateFormatterShortStyle
  ) -> String {
    let formatter = DateFormatter()
    formatter.setDateStyle(date)
    formatter.setTime(time)
    return formatter.string(from: self as NSDate) ?? ""
  }

  /// The ISO-8601 spelling (`yyyy-MM-dd'T'HH:mm:ssZ`), under the formatter's
  /// default locale.
  public func ISO8601Format() -> String {
    let formatter = DateFormatter()
    formatter.setDateFormat("yyyy-MM-dd'T'HH:mm:ssZ")
    formatter.setTimeZone(NSTimeZone(name: "UTC")!)
    return formatter.string(from: self as NSDate) ?? ""
  }
}

// MARK: - Decimal arithmetic

extension Decimal: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
  public init(integerLiteral value: Int) { self.init(value) }
  public init(floatLiteral value: Double) { self.init(value) }
}

extension Decimal {
  public static var zero: Decimal { return Decimal(0) }
  public static var one: Decimal { return Decimal(1) }
  public static var nan: Decimal { return Decimal(NSDecimalNumber.notA()) }

  public var isZero: Bool { return self == Decimal.zero }

  public var sign: FloatingPointSign { return isNegative ? FloatingPointSign.minus : FloatingPointSign.plus }
  public var magnitude: Decimal { return isNegative ? -self : self }

  public static prefix func - (operand: Decimal) -> Decimal {
    return Decimal(_decimalNumber(operand).multiplying(by: NSDecimalNumber(string: "-1")))
  }

  public static func + (lhs: Decimal, rhs: Decimal) -> Decimal {
    return Decimal(_decimalNumber(lhs).adding(_decimalNumber(rhs)))
  }
  public static func - (lhs: Decimal, rhs: Decimal) -> Decimal {
    return Decimal(_decimalNumber(lhs).subtracting(_decimalNumber(rhs)))
  }
  public static func * (lhs: Decimal, rhs: Decimal) -> Decimal {
    return Decimal(_decimalNumber(lhs).multiplying(by: _decimalNumber(rhs)))
  }
  public static func / (lhs: Decimal, rhs: Decimal) -> Decimal {
    return Decimal(_decimalNumber(lhs).dividing(by: _decimalNumber(rhs)))
  }

  public static func += (lhs: inout Decimal, rhs: Decimal) { lhs = lhs + rhs }
  public static func -= (lhs: inout Decimal, rhs: Decimal) { lhs = lhs - rhs }
  public static func *= (lhs: inout Decimal, rhs: Decimal) { lhs = lhs * rhs }
  public static func /= (lhs: inout Decimal, rhs: Decimal) { lhs = lhs / rhs }

}

private func _decimalNumber(_ value: Decimal) -> NSDecimalNumber {
  return NSDecimalNumber(decimal: value._value)
}

// MARK: - Calendar date arithmetic

extension Calendar {
  public func startOfDay(for date: Date) -> Date {
    let result = _calendar.startOfDay(for: date as NSDate) ?? (date as NSDate)
    return Date(timeIntervalSinceReferenceDate: result.timeIntervalSinceReferenceDate)
  }

  public func date(byAdding component: Component, value: Int, to date: Date) -> Date? {
    let result = _calendar.date(byAddingUnit: component._unit,
                                value: value,
                                to: date as NSDate,
                                options: NSCalendarOptionsNone)
    return Date(timeIntervalSinceReferenceDate: result.timeIntervalSinceReferenceDate)
  }

  public func date(byAdding components: DateComponents, to date: Date) -> Date? {
    let result = _calendar.date(byAdding: components._components,
                                to: date as NSDate,
                                options: NSCalendarOptionsNone)
    return Date(timeIntervalSinceReferenceDate: result.timeIntervalSinceReferenceDate)
  }

  public func dateComponents(_ components: Set<Component>,
                             from start: Date, to end: Date) -> DateComponents {
    var unit: NSCalendarUnit = 0
    for component in components { unit |= component._unit }
    let result = _calendar.components(unit,
                                      from: start as NSDate,
                                      to: end as NSDate,
                                      options: NSCalendarOptionsNone)
    return DateComponents(result)
  }

  public func dateComponents(in zone: TimeZone, from date: Date) -> DateComponents {
    return DateComponents(_calendar.components(in: zone._zone, from: date as NSDate))
  }

  public func component(_ component: Component, from date: Date) -> Int? {
    return _calendar.component(component._unit, from: date as NSDate)
      .map { Int($0.intValue()) }
  }

  public func range(of smaller: Component, in larger: Component,
                    for date: Date) -> Range<Int>? {
    let range = _calendar.range(ofUnit: smaller._unit,
                                inUnit: larger._unit,
                                for: date as NSDate)
    guard range.location != NSNotFound else { return nil }
    return range.location..<(range.location + range.length)
  }

  public func range(of smaller: Component,
                    start: inout Date, interval: inout TimeInterval,
                    for date: Date) -> Bool {
    var startDate: NSDate? = nil
    var length: TimeInterval = 0
    let found = _calendar.range(ofUnit: smaller._unit,
                                start: &startDate,
                                interval: &length,
                                for: date as NSDate)
    if found {
      start = Date(timeIntervalSinceReferenceDate:
                   startDate?.timeIntervalSinceReferenceDate ?? 0)
      interval = length
    }
    return found
  }

  public func dateInterval(of component: Component, for date: Date) -> DateInterval? {
    var start = date
    var interval: TimeInterval = 0
    guard range(of: component, start: &start, interval: &interval, for: date) else {
      return nil
    }
    return DateInterval(start: start, duration: interval)
  }

  public func isDate(_ date1: Date, equalTo date2: Date,
                     toGranularity component: Component) -> Bool {
    return compare(date1, to: date2, toGranularity: component) == ComparisonResult.orderedSame
  }

  public func compare(_ date1: Date, to date2: Date,
                      toGranularity component: Component) -> ComparisonResult {
    return _calendar.compare(date1 as NSDate, to: date2 as NSDate,
                             toUnitGranularity: component._unit)
  }

  public func isDate(_ date1: Date, inSameDayAs date2: Date) -> Bool {
    return _calendar.isDate(date1 as NSDate, inSameDayAs: date2 as NSDate)
  }

  public func isDateInToday(_ date: Date) -> Bool {
    return _calendar.isDate(inToday: date as NSDate)
  }

  public func isDateInYesterday(_ date: Date) -> Bool {
    return _calendar.isDate(inYesterday: date as NSDate)
  }

  public func isDateInTomorrow(_ date: Date) -> Bool {
    return _calendar.isDate(inTomorrow: date as NSDate)
  }

  public func isDateInWeekend(_ date: Date) -> Bool {
    return _calendar.isDate(inWeekend: date as NSDate)
  }
}

// MARK: - Description and comparison conformances

// Darwin's value types are `CustomStringConvertible` and
// `CustomDebugStringConvertible`; the C structs are `Equatable`/`Hashable` because
// on Darwin they are Swift structs rather than imported ones. This section
// supplies those conformances, so a program that hashes a `CGRect` or
// interpolates an `IndexPath` compiles as it does on Darwin.
//
// The debug form is the description form unless a type has something better:
// Darwin's adds internal detail, and these hand-written types are replaced by
// FoundationEssentials in P3 (SWIFT-FOUNDATION-PARITY-PLAN.md).

extension Data: CustomStringConvertible, CustomDebugStringConvertible {
  public var debugDescription: String { return description }
}

extension Date: CustomDebugStringConvertible {
  public var debugDescription: String { return description }
}

extension URL: CustomDebugStringConvertible {
  public var debugDescription: String { return description }
}

extension UUID: CustomDebugStringConvertible {
  public var debugDescription: String { return description }
}

extension Decimal: CustomDebugStringConvertible {
  public var debugDescription: String { return description }
}

extension IndexPath: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    if _indices.isEmpty { return "{length = 0, path = }" }
    return "{length = \(_indices.count), path = \(_indices.map(String.init).joined(separator: " - "))}"
  }
  public var debugDescription: String { return description }
}

extension TimeZone: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { return _zone.description }
  public var debugDescription: String { return description }
}

extension Locale: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { return _locale.description }
  public var debugDescription: String { return description }
}

extension Calendar: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { return _calendar.description }
  public var debugDescription: String { return description }
}

extension DateComponents: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { return _components.description }
  public var debugDescription: String { return description }
}

extension PersonNameComponents: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { return _components.description }
  public var debugDescription: String { return description }
}

extension CharacterSet: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { return _set.description }
  public var debugDescription: String { return description }
}

extension IndexSet: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { return _set.description }
  public var debugDescription: String { return description }
}

extension DateInterval: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    return "\(start) to \(start.addingTimeInterval(duration))"
  }
  public var debugDescription: String { return description }
}

extension Notification: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    return "name = \(name), object = \(String(describing: object)), "
         + "userInfo = \(String(describing: userInfo))"
  }
  public var debugDescription: String { return description }
}

extension AffineTransform: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String {
    return "[\(m11), \(m12), \(tX); \(m21), \(m22), \(tY)]"
  }
  public var debugDescription: String { return description }
}

extension DateInterval: Comparable {
  public static func < (lhs: DateInterval, rhs: DateInterval) -> Bool {
    if lhs.start != rhs.start { return lhs.start < rhs.start }
    return lhs.duration < rhs.duration
  }
}

extension UUID: Comparable {
  public static func < (lhs: UUID, rhs: UUID) -> Bool {
    return lhs.uuidString < rhs.uuidString
  }
}

// The C structs: on Darwin these are Swift structs with synthesized equality, so
// the imported ones need the two members spelled out.
extension CGPoint: Equatable, Hashable {
  public static func == (lhs: CGPoint, rhs: CGPoint) -> Bool {
    return lhs.x == rhs.x && lhs.y == rhs.y
  }
  public func hash(into hasher: inout Hasher) {
    hasher.combine(x)
    hasher.combine(y)
  }
}

extension CGSize: Equatable, Hashable {
  public static func == (lhs: CGSize, rhs: CGSize) -> Bool {
    return lhs.width == rhs.width && lhs.height == rhs.height
  }
  public func hash(into hasher: inout Hasher) {
    hasher.combine(width)
    hasher.combine(height)
  }
}

extension CGRect: Equatable, Hashable {
  public static func == (lhs: CGRect, rhs: CGRect) -> Bool {
    return lhs.origin == rhs.origin && lhs.size == rhs.size
  }
  public func hash(into hasher: inout Hasher) {
    hasher.combine(origin)
    hasher.combine(size)
  }
}

extension OperatingSystemVersion: Equatable, Hashable {
  public static func == (lhs: OperatingSystemVersion, rhs: OperatingSystemVersion) -> Bool {
    return lhs.majorVersion == rhs.majorVersion
        && lhs.minorVersion == rhs.minorVersion
        && lhs.patchVersion == rhs.patchVersion
  }
  public func hash(into hasher: inout Hasher) {
    hasher.combine(majorVersion)
    hasher.combine(minorVersion)
    hasher.combine(patchVersion)
  }
}

extension Notification: Equatable, Hashable {
  public static func == (lhs: Notification, rhs: Notification) -> Bool {
    if lhs.name != rhs.name { return false }
    if (lhs.object as AnyObject?) !== (rhs.object as AnyObject?) { return false }
    return ((lhs.userInfo ?? [:]) as NSDictionary).isEqual(rhs.userInfo ?? [:])
  }
  public func hash(into hasher: inout Hasher) {
    hasher.combine(name)
  }
}

// `Comparable`, forwarding to the `-compare:` each class already implements. The
// protocol is declared on the class, not on `NSObject`: only these have an order.
extension NSDate: Comparable {
  public static func < (lhs: NSDate, rhs: NSDate) -> Bool {
    return lhs.compare(rhs) == ComparisonResult.orderedAscending
  }
}

extension NSDateInterval: Comparable {
  public static func < (lhs: NSDateInterval, rhs: NSDateInterval) -> Bool {
    return lhs.compare(rhs) == ComparisonResult.orderedAscending
  }
}

extension NSIndexPath: Comparable {
  public static func < (lhs: NSIndexPath, rhs: NSIndexPath) -> Bool {
    return lhs.compare(rhs) == ComparisonResult.orderedAscending
  }
}

extension NSNumber: Comparable {
  public static func < (lhs: NSNumber, rhs: NSNumber) -> Bool {
    return lhs.compare(rhs) == ComparisonResult.orderedAscending
  }
}

extension NSString: Comparable {
  public static func < (lhs: NSString, rhs: NSString) -> Bool {
    return lhs.compare(rhs as String) == ComparisonResult.orderedAscending
  }
}

