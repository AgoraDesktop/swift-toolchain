//===--- FoundationOverlay.swift - Agora's Foundation overlay -------------===//
//
// The Swift half of Agora's Foundation: the value bridges the standard library
// deliberately leaves to the Foundation overlay.
//
// Built with `-module-name Foundation -import-underlying-module` against
// Agora's Clang module of the same name - the way Darwin's Foundation overlay
// is built - and installed next to the target stdlib, so `import Foundation`
// finds it with no extra flags.
//
// What is here:
//   * `String`, `Substring`, `Array`, `Dictionary`, `Set` <-> `NSString`,
//     `NSArray`, `NSDictionary`, `NSSet`, through the standard library's own
//     `_bridgeToObjectiveCImpl()`: those four types carry the *deferred*
//     wrappers (`__SwiftDeferredNSArray` and friends) and the
//     `_bridgeFromObjectiveCAdoptingNativeStorageOf()` entry points, so a
//     bridge is a view over the same storage in one direction and an adoption
//     in the other - no copy, as on Darwin;
//   * every fixed-width integer, `Float`, `Double`, `Bool` <-> `NSNumber`;
//   * `AnyHashable` <-> `NSObject` (what makes `[AnyHashable: Any]` - and so an
//     unparameterized `NSDictionary *` - representable in Objective-C);
//   * `Error` <-> `NSError`, including the `CustomNSError`, `LocalizedError`
//     and `RecoverableError` protocols the runtime consults, and the
//     `_BridgedStoredNSError` machinery imported `NS_ERROR_ENUM`s use;
//   * the Cocoa value-type surface: the collection classes iterate, `NSError`
//     takes a Swift dictionary of user info, and an `NSObject` is `Hashable`.
//
// The value types themselves (`Data`, `Date`, `URL`, `IndexPath`, ...) and
// their bridges are in FoundationValueTypes.swift.
//
// The bridges are also what lets the `swift_bridge` attributes in Agora's
// headers work (patch 0010): `NSString *` imports as `String`, `NSArray *` as
// `[Any]`, and `NSDictionary *`/`NSSet *` as `[AnyHashable: Any]`/`Set<AnyHashable>`
// now that `AnyHashable` bridges.
//
//===----------------------------------------------------------------------===//

// `BOOL`, `SEL` and `NSZone *` are the importer's `ObjectiveC.ObjCBool`,
// `ObjectiveC.Selector` and `ObjectiveC.NSZone`; re-export the module so
// `import Foundation` brings them into scope the way it does on Darwin.
@_exported import ObjectiveC

// MARK: - String

extension String: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSString

  public func _bridgeToObjectiveC() -> NSString {
    // The stdlib's zero-copy path: a `__StringStorage` that shares the code
    // units with the Swift string.  It answers `-length`,
    // `-characterAtIndex:`, `-getCharacters:range:`, `-UTF8String`,
    // `-lengthOfBytesUsingEncoding:` and `-compare:options:range:locale:`, so
    // the derived `NSString` doors in Agora's Foundation (`-substringFromIndex:`,
    // `-uppercaseString`, ...) work on the view too.
    return _bridgeToObjectiveCImpl() as! NSString
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSString,
                                                result: inout String?) {
    result = _unconditionallyBridgeFromObjectiveC(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSString,
                                                       result: inout String?) -> Bool {
    result = _string(from: source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSString?) -> String {
    guard let source else { return "" }
    return _string(from: source)
  }
}

private func _string(from source: NSString) -> String {
  let length = source.length
  if length == 0 { return "" }
  // UTF-16 through `-getCharacters:range:`: every NSString answers it, and a
  // `__StringStorage` view answers it from its own code units.  (`-UTF8String`
  // is not usable here: Swift's storage is not NUL-terminated.)
  var units = [unichar](repeating: 0, count: length)
  source.__getCharacters(&units, range: NSRange(location: 0, length: length))
  return String(decoding: units, as: UTF16.self)
}

extension Substring: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSString

  public func _bridgeToObjectiveC() -> NSString {
    return String(self)._bridgeToObjectiveC()
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSString,
                                                result: inout Substring?) {
    result = Substring(String._unconditionallyBridgeFromObjectiveC(source))
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSString,
                                                       result: inout Substring?) -> Bool {
    result = Substring(String._unconditionallyBridgeFromObjectiveC(source))
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSString?) -> Substring {
    return Substring(String._unconditionallyBridgeFromObjectiveC(source))
  }
}

// MARK: - Array, Dictionary, Set

extension Array: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSArray

  public func _bridgeToObjectiveC() -> NSArray {
    // The stdlib's zero-copy path: `_ContiguousArrayStorage<Element>` when the
    // element type is bridged verbatim (a class), and a `__SwiftDeferredNSArray`
    // view over the buffer otherwise.  Both are registered GNUstep class
    // objects at layout 2, and their `-objectAtIndex:`/`-getObjects:range:`
    // overrides are reached by a typed Objective-C send.
    return _bridgeToObjectiveCImpl() as! NSArray
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSArray,
                                                result: inout Array?) {
    result = _unconditionallyBridgeFromObjectiveC(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSArray,
                                                       result: inout Array?) -> Bool {
    result = _unconditionallyBridgeFromObjectiveC(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSArray?) -> Array {
    guard let source else { return [] }
    // Adopt the storage when it is ours: a round trip through
    // `_bridgeToObjectiveC()` is then O(1) in both directions.
    if let adopted = Array._bridgeFromObjectiveCAdoptingNativeStorageOf(source) {
      return adopted
    }
    var array: [Element] = []
    let count = source.count
    array.reserveCapacity(count)
    for index in 0..<count {
      guard let element = source.object(at: index) as? Element else { continue }
      array.append(element)
    }
    return array
  }
}

extension Dictionary: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSDictionary

  public func _bridgeToObjectiveC() -> NSDictionary {
    // As on Darwin, the bridge is a view: `_bridgeToObjectiveCImpl()` hands
    // back the native storage (`__SwiftDeferredNSDictionary` at layout 2),
    // which is a registered GNUstep class object now that the class-object
    // test covers `@_swift_native_objc_runtime_base` classes.
    return _bridgeToObjectiveCImpl() as! NSDictionary
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSDictionary,
                                                result: inout Dictionary?) {
    result = _unconditionallyBridgeFromObjectiveC(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSDictionary,
                                                       result: inout Dictionary?) -> Bool {
    result = _unconditionallyBridgeFromObjectiveC(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSDictionary?) -> Dictionary {
    guard let source else { return [:] }
    if let adopted = Dictionary<Key, Value>._bridgeFromObjectiveCAdoptingNativeStorageOf(source) {
      return adopted
    }
    var dictionary: [Key: Value] = [:]
    for key in source.allKeys {
      guard let swiftKey = _bridgeKey(key, to: Key.self) else { continue }
      guard let swiftValue = source.object(forKey: key) as? Value else { continue }
      dictionary[swiftKey] = swiftValue
    }
    return dictionary
  }
}

/// Bridge one Objective-C key to `Key`.
///
/// For `AnyHashable` the *string* form is what a Swift dictionary is keyed by,
/// so an `NSString` key is normalized to `String`: otherwise `d["k"]` (which
/// converts the literal to `AnyHashable(String)`) would look for a different
/// hash than the `AnyHashable(NSString)` wrapping the object. This is what makes
/// a bridged `NSDictionary`'s entries findable by their Swift keys.
private func _bridgeKey<Key>(_ key: Any, to: Key.Type) -> Key? {
  if Key.self == AnyHashable.self {
    return _bridgeAnyHashable(key) as? Key
  }
  return key as? Key
}

private func _bridgeAnyHashable(_ value: Any) -> AnyHashable {
  if let string = value as? NSString {
    return AnyHashable(String._unconditionallyBridgeFromObjectiveC(string))
  }
  // Keys of an NSDictionary are objects; `NSObject: Hashable` covers the rest.
  if let object = value as? NSObject { return AnyHashable(object) }
  return AnyHashable(0)
}

extension Set: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSSet

  public func _bridgeToObjectiveC() -> NSSet {
    // See Dictionary above: the bridge is the stdlib's native-storage view.
    return _bridgeToObjectiveCImpl() as! NSSet
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSSet,
                                                result: inout Set?) {
    result = _unconditionallyBridgeFromObjectiveC(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSSet,
                                                       result: inout Set?) -> Bool {
    result = _unconditionallyBridgeFromObjectiveC(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSSet?) -> Set {
    guard let source else { return [] }
    if let adopted = Set<Element>._bridgeFromObjectiveCAdoptingNativeStorageOf(source) {
      return adopted
    }
    var set: Set<Element> = []
    for object in source.allObjects {
      guard let element = _bridgeKey(object, to: Element.self) else { continue }
      set.insert(element)
    }
    return set
  }
}

// MARK: - Numbers

extension Int: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSNumber

  public func _bridgeToObjectiveC() -> NSNumber { return NSNumber(integer: self) }

  public static func _forceBridgeFromObjectiveC(_ source: NSNumber,
                                                result: inout Int?) {
    result = source.integerValue()
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber,
                                                       result: inout Int?) -> Bool {
    result = source.integerValue()
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Int {
    guard let source else { return 0 }
    return source.integerValue()
  }
}

extension Int8: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSNumber

  public func _bridgeToObjectiveC() -> NSNumber { return NSNumber(char: self) }

  public static func _forceBridgeFromObjectiveC(_ source: NSNumber,
                                                result: inout Int8?) {
    result = source.charValue()
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber,
                                                       result: inout Int8?) -> Bool {
    result = source.charValue()
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Int8 {
    guard let source else { return 0 }
    return source.charValue()
  }
}

extension Int16: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSNumber

  public func _bridgeToObjectiveC() -> NSNumber { return NSNumber(short: self) }

  public static func _forceBridgeFromObjectiveC(_ source: NSNumber,
                                                result: inout Int16?) {
    result = source.shortValue()
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber,
                                                       result: inout Int16?) -> Bool {
    result = source.shortValue()
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Int16 {
    guard let source else { return 0 }
    return source.shortValue()
  }
}

extension Int32: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSNumber

  public func _bridgeToObjectiveC() -> NSNumber { return NSNumber(int: self) }

  public static func _forceBridgeFromObjectiveC(_ source: NSNumber,
                                                result: inout Int32?) {
    result = source.intValue()
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber,
                                                       result: inout Int32?) -> Bool {
    result = source.intValue()
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Int32 {
    guard let source else { return 0 }
    return source.intValue()
  }
}

extension Int64: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSNumber

  public func _bridgeToObjectiveC() -> NSNumber { return NSNumber(longLong: self) }

  public static func _forceBridgeFromObjectiveC(_ source: NSNumber,
                                                result: inout Int64?) {
    result = source.longLongValue()
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber,
                                                       result: inout Int64?) -> Bool {
    result = source.longLongValue()
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Int64 {
    guard let source else { return 0 }
    return source.longLongValue()
  }
}

extension UInt: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSNumber

  public func _bridgeToObjectiveC() -> NSNumber { return NSNumber(unsignedInteger: self) }

  public static func _forceBridgeFromObjectiveC(_ source: NSNumber,
                                                result: inout UInt?) {
    result = source.unsignedIntegerValue()
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber,
                                                       result: inout UInt?) -> Bool {
    result = source.unsignedIntegerValue()
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> UInt {
    guard let source else { return 0 }
    return source.unsignedIntegerValue()
  }
}

extension UInt8: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSNumber

  public func _bridgeToObjectiveC() -> NSNumber { return NSNumber(unsignedChar: self) }

  public static func _forceBridgeFromObjectiveC(_ source: NSNumber,
                                                result: inout UInt8?) {
    result = source.unsignedCharValue()
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber,
                                                       result: inout UInt8?) -> Bool {
    result = source.unsignedCharValue()
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> UInt8 {
    guard let source else { return 0 }
    return source.unsignedCharValue()
  }
}

extension UInt16: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSNumber

  public func _bridgeToObjectiveC() -> NSNumber { return NSNumber(unsignedShort: self) }

  public static func _forceBridgeFromObjectiveC(_ source: NSNumber,
                                                result: inout UInt16?) {
    result = source.unsignedShortValue()
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber,
                                                       result: inout UInt16?) -> Bool {
    result = source.unsignedShortValue()
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> UInt16 {
    guard let source else { return 0 }
    return source.unsignedShortValue()
  }
}

extension UInt32: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSNumber

  public func _bridgeToObjectiveC() -> NSNumber { return NSNumber(unsignedInt: self) }

  public static func _forceBridgeFromObjectiveC(_ source: NSNumber,
                                                result: inout UInt32?) {
    result = source.unsignedIntValue()
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber,
                                                       result: inout UInt32?) -> Bool {
    result = source.unsignedIntValue()
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> UInt32 {
    guard let source else { return 0 }
    return source.unsignedIntValue()
  }
}

extension UInt64: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSNumber

  public func _bridgeToObjectiveC() -> NSNumber { return NSNumber(unsignedLongLong: self) }

  public static func _forceBridgeFromObjectiveC(_ source: NSNumber,
                                                result: inout UInt64?) {
    result = source.unsignedLongLongValue()
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber,
                                                       result: inout UInt64?) -> Bool {
    result = source.unsignedLongLongValue()
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> UInt64 {
    guard let source else { return 0 }
    return source.unsignedLongLongValue()
  }
}

extension Float: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSNumber

  public func _bridgeToObjectiveC() -> NSNumber { return NSNumber(float: self) }

  public static func _forceBridgeFromObjectiveC(_ source: NSNumber,
                                                result: inout Float?) {
    result = source.floatValue()
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber,
                                                       result: inout Float?) -> Bool {
    result = source.floatValue()
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Float {
    guard let source else { return 0 }
    return source.floatValue()
  }
}

extension Double: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSNumber

  public func _bridgeToObjectiveC() -> NSNumber { return NSNumber(double: self) }

  public static func _forceBridgeFromObjectiveC(_ source: NSNumber,
                                                result: inout Double?) {
    result = source.doubleValue()
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber,
                                                       result: inout Double?) -> Bool {
    result = source.doubleValue()
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Double {
    guard let source else { return 0 }
    return source.doubleValue()
  }
}

extension Bool: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSNumber

  public func _bridgeToObjectiveC() -> NSNumber { return NSNumber(bool: self) }

  public static func _forceBridgeFromObjectiveC(_ source: NSNumber,
                                                result: inout Bool?) {
    result = source.boolValue()
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber,
                                                       result: inout Bool?) -> Bool {
    result = source.boolValue()
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Bool {
    guard let source else { return false }
    return source.boolValue()
  }
}

// MARK: - Cocoa-shaped API surface

// The Darwin Foundation overlay re-declares the parts of Foundation that Swift
// should spell with its own types.  The `swift_bridge` attributes cover the
// signatures the importer can rewrite (`NSString *` -> `String`, `NSArray *` ->
// `[Any]`, `NSDictionary *` -> `[AnyHashable: Any]`); what is left is additive,
// on top of the Objective-C API:
//
//   * the collection classes iterate (`NSArray`, `NSDictionary`, `NSSet`,
//     `NSOrderedSet` are `Sequence`, as on Darwin);
//   * `NSError` takes Swift values in its designated initializer;
//   * an `NSObject` is `Hashable`, so `AnyHashable` can hold one.
extension NSArray: Sequence {
  public func makeIterator() -> AnyIterator<Any> {
    var index = 0
    return AnyIterator {
      guard index < self.count else { return nil }
      defer { index += 1 }
      return self.object(at: index)
    }
  }
}

extension NSDictionary: Sequence {
  public func makeIterator() -> AnyIterator<(key: Any, value: Any)> {
    let keys = self.allKeys
    var index = 0
    return AnyIterator {
      guard index < keys.count else { return nil }
      let key = keys[index]
      index += 1
      guard let value = self.object(forKey: key) else { return nil }
      return (key, value)
    }
  }
}

extension NSSet: Sequence {
  public func makeIterator() -> AnyIterator<Any> {
    let objects = self.allObjects
    var index = 0
    return AnyIterator {
      guard index < objects.count else { return nil }
      defer { index += 1 }
      return objects[index]
    }
  }
}

extension NSOrderedSet: Sequence {
  public func makeIterator() -> AnyIterator<Any> {
    var index = 0
    return AnyIterator {
      guard index < self.count else { return nil }
      defer { index += 1 }
      return self.object(at: index)
    }
  }
}

// The imported `initWithDomain:code:userInfo:` takes the domain as a Swift
// `String` (`swift_bridge` on NSString) and the user info as `[AnyHashable: Any]?`
// (the bridge above). These overloads keep the Swift spellings (`[String: Any]`)
// from before the collection bridge landed; `NSError(domain:code:)` exists so a
// `nil` userInfo is never ambiguous.
extension NSError {
  public convenience init?(domain: String, code: Int,
                           userInfo: [String: Any]) {
    var info: [AnyHashable: Any] = [:]
    for (key, value) in userInfo { info[AnyHashable(key)] = value }
    self.init(domain: domain, code: code, userInfo: info)
  }

  public convenience init?(domain: String, code: Int) {
    self.init(domain: domain, code: code, userInfo: nil)
  }
}

// MARK: - Hashable objects and AnyHashable

// `AnyHashable` cannot wrap an Objective-C object without `NSObject: Hashable`,
// and on Darwin that conformance comes from the `ObjectiveC` overlay. Without it
// a bridged `[AnyHashable: Any]` silently drops its entries (`key as?
// AnyHashable` fails).
extension NSObject: Equatable, Hashable {
  public static func == (lhs: NSObject, rhs: NSObject) -> Bool {
    return lhs.isEqual(rhs)
  }

  public func hash(into hasher: inout Hasher) {
    // `hash` alone is ambiguous here (it also names this method); the
    // NSObject *class* still declares its getter as a method.
    let value: Int = self.hash()
    hasher.combine(value)
  }
}

// `AnyHashable` bridges to `NSObject` (the `ObjectiveC` overlay's conformance on
// Darwin). This is also what makes `[AnyHashable: Any]` - the imported shape of
// an unparameterized `NSDictionary *` - and `Set<AnyHashable>` representable in
// Objective-C, and therefore what lets the `swift_bridge` attribute on those
// classes take effect.
extension AnyHashable: _ObjectiveCBridgeable {
  public typealias _ObjectiveCType = NSObject

  public func _bridgeToObjectiveC() -> NSObject {
    let base = self.base
    // An object is its own bridge; everything else goes through the stdlib's
    // boxer (NSString/NSNumber for the bridged types, `__SwiftValue` otherwise).
    if let object = base as? NSObject { return object }
    return unsafeBitCast(_bridgeAnythingToObjectiveC(base), to: NSObject.self)
  }

  public static func _forceBridgeFromObjectiveC(_ source: NSObject,
                                                result: inout AnyHashable?) {
    result = _unconditionallyBridgeFromObjectiveC(source)
  }

  @discardableResult
  public static func _conditionallyBridgeFromObjectiveC(_ source: NSObject,
                                                       result: inout AnyHashable?) -> Bool {
    result = _unconditionallyBridgeFromObjectiveC(source)
    return true
  }

  public static func _unconditionallyBridgeFromObjectiveC(_ source: NSObject?) -> AnyHashable {
    guard let source else { return AnyHashable(0) }
    // A string key comes back as a `String`, so `dictionary["k"]` (which
    // converts the literal to `AnyHashable(String)`) finds the entry an
    // `NSDictionary` carried. Everything else wraps the object, which is what
    // `NSObject: Hashable` is for.
    if let string = source as? NSString {
      return AnyHashable(String._unconditionallyBridgeFromObjectiveC(string))
    }
    return AnyHashable(source)
  }
}

// MARK: - Error <-> NSError

// SILGen looks these two up *by name* in the loaded Foundation module when
// Swift's `Error` meets Objective-C's `NSError` (the GET_BRIDGING_FN table in
// SILGen.cpp), which is also what `error as NSError` lowers to.
//
// The stdlib's runtime builds an NSError-shaped box; at this layout the box is
// the runtime's `__SwiftNativeNSError`, whose domain/code/userInfo slots are
// NSError's, so the reinterpretation is the layout-level identity Darwin's
// overlay gets from its `SwiftNativeNSError` subclass.
extension NSError: Error {}

public // COMPILER_INTRINSIC
func _convertErrorToNSError(_ error: Error) -> NSError {
  return unsafeBitCast(_bridgeErrorToNSError(error), to: NSError.self)
}

public // COMPILER_INTRINSIC
func _convertNSErrorToError(_ error: NSError) -> Error {
  return error
}

/// An error type customizes how it becomes an `NSError`.
public protocol CustomNSError: Error {
  static var errorDomain: String { get }
  var errorCode: Int { get }
  var errorUserInfo: [String: Any] { get }
}

public extension CustomNSError {
  static var errorDomain: String { return _typeName(self, qualified: true) }
  // The stdlib's default (an enum's raw value, else 1).  Not
  // `(self as Error)._code`: that witness is overridden below to return
  // `errorCode`, so going through it would recurse forever.
  var errorCode: Int { return _getDefaultErrorCode(self) }
  var errorUserInfo: [String: Any] { return [:] }
}

public extension Error where Self: CustomNSError {
  var _domain: String { return Self.errorDomain }
  var _code: Int { return errorCode }
}

/// An error type carries the user-facing strings of the `NSError` it becomes.
public protocol LocalizedError: Error {
  var errorDescription: String? { get }
  var failureReason: String? { get }
  var recoverySuggestion: String? { get }
  var helpAnchor: String? { get }
}

public extension LocalizedError {
  var errorDescription: String? { return nil }
  var failureReason: String? { return nil }
  var recoverySuggestion: String? { return nil }
  var helpAnchor: String? { return nil }
}

/// An error that may be recoverable by presenting options to the user.
/// (Darwin's Foundation declares this; without it an `NS_ERROR_ENUM`-style
/// error cannot offer recovery.)
public protocol RecoverableError: Error {
  var recoveryOptions: [String] { get }

  func attemptRecovery(optionIndex recoveryOptionIndex: Int,
                       resultHandler handler: @escaping (_ recovered: Bool) -> Void)

  func attemptRecovery(optionIndex recoveryOptionIndex: Int) -> Bool
}

public extension RecoverableError {
  func attemptRecovery(optionIndex recoveryOptionIndex: Int,
                       resultHandler handler: @escaping (_ recovered: Bool) -> Void) {
    handler(attemptRecovery(optionIndex: recoveryOptionIndex))
  }
}

/// An error code that can be carried by `_BridgedStoredNSError`.
public protocol _ErrorCodeProtocol: RawRepresentable, Hashable
  where RawValue: FixedWidthInteger {}

/// An error type that bridges to `NSError` through `_ObjectiveCBridgeableError`:
/// the shape an imported `NS_ERROR_ENUM` takes.
public protocol _ObjectiveCBridgeableError: Error {
  init?(_bridgedNSError: NSError)
}

/// The machinery behind imported `NS_ERROR_ENUM`s.
public protocol _BridgedStoredNSError:
    _ObjectiveCBridgeableError, CustomNSError, Hashable,
    CustomStringConvertible {
  associatedtype Code: _ErrorCodeProtocol

  static var _nsErrorDomain: String { get }

  var code: Code { get }
  var _nsError: NSError { get }

  init(_nsError error: NSError)
}

public extension _BridgedStoredNSError {
  var description: String { return _nsError.description() }

  init?(_bridgedNSError error: NSError) {
    if (error.domain as String) != Self._nsErrorDomain { return nil }
    self.init(_nsError: error)
  }

  static var errorDomain: String { return _nsErrorDomain }

  var errorCode: Int { return _nsError.code }

  var errorUserInfo: [String: Any] {
    var result: [String: Any] = [:]
    for (key, value) in _nsError.userInfo ?? [:] {
      if let key = key as? String { result[key] = value }
    }
    return result
  }

  var code: Code {
    return Code(rawValue: Code.RawValue(_nsError.code))!
  }

  init(_ code: Code, userInfo: [String: Any] = [:]) {
    var info: [AnyHashable: Any] = [:]
    for (key, value) in userInfo { info[AnyHashable(key)] = value }
    self.init(_nsError: NSError(domain: Self._nsErrorDomain,
                                code: Int(code.rawValue),
                                userInfo: info)!)
  }

  var userInfo: [String: Any] { return errorUserInfo }

  func hash(into hasher: inout Hasher) {
    hasher.combine(_nsError.domain)
    hasher.combine(_nsError.code)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    return lhs._nsError.isEqual(rhs._nsError)
  }
}

/// Called by the runtime (`dlsym`, mangled `Foundation._getErrorDefaultUserInfo`)
/// to fill in an NSError's userInfo from the error value.  Returning nil lets
/// the runtime keep its empty dictionary.
public func _getErrorDefaultUserInfo<T: Error>(_ error: T) -> AnyObject? {
  var result: [String: Any] = [:]

  if let custom = error as? CustomNSError {
    result = custom.errorUserInfo
  }

  if let localized = error as? LocalizedError {
    // The key constants are NSString; the dictionary is [String: Any].
    if let description = localized.errorDescription {
      result[NSLocalizedDescriptionKey as String] = description
    }
    if let reason = localized.failureReason {
      result[NSLocalizedFailureReasonErrorKey as String] = reason
    }
    if let suggestion = localized.recoverySuggestion {
      result[NSLocalizedRecoverySuggestionErrorKey as String] = suggestion
    }
    if let anchor = localized.helpAnchor {
      result[NSHelpAnchorErrorKey as String] = anchor
    }
  }

  if result.isEmpty { return nil }
  return _bridgeAnythingToObjectiveC(result)
}
