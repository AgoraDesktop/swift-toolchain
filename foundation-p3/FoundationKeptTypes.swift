//===--- FoundationKeptTypes.swift - the value types FE does not provide ----===//
//
// P3 retires the overlay's hand-written value types in favour of
// FoundationEssentials'.  Five of them have no FoundationEssentials counterpart,
// so they stay here, moved from `foundation-overlay/FoundationValueTypes.swift`
// unchanged:
//
//   * `Notification`                 (swift-foundation does not ship it yet)
//   * `PersonNameComponents`
//   * `CharacterSet`
//   * `IndexSet`
//   * `AffineTransform`
//
// Their bridges to Agora's classes (`NSNotification`, `NSPersonNameComponents`,
// `NSCharacterSet`, `NSIndexSet`, `NSAffineTransform`) and their `SetAlgebra`
// conformances come with them.  Also here: the conformances that belong to the
// *Objective-C* classes and the C structs rather than to Swift value types
// (`NSDate`/`NSDateInterval`/`NSIndexPath`/`NSNumber`/`NSString` are `Comparable`,
// `CGPoint`/`CGSize`/`CGRect`/`OperatingSystemVersion` are `Equatable`/`Hashable`,
// and `NSAttributedString.Key` bridges), which no ported module supplies.
//
// What is deliberately *not* here: the overlay's long tails for the retired types
// (its `Date` formatting convenience, its `Decimal` literals, its `Calendar` date
// arithmetic, its description conformances for them).  FoundationEssentials and
// FoundationInternationalization own that surface now; the gates say if anything
// a program actually calls went missing, and `FoundationCompat.swift` is where a
// missing spelling would be added back.
//
//===----------------------------------------------------------------------===//

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


