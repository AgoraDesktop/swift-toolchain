//===--- ObjectiveC.swift - Agora's ObjectiveC module ---------------------===//
//
// The Swift half of <objc/>: the three types the Clang importer looks up *by
// name* in a module called `ObjectiveC`, and the two helpers SILGen calls when
// it bridges `Bool` at an Objective-C boundary.
//
//   Clang type   Swift type            looked up in
//   ----------   --------------------  ------------------------------------
//   `BOOL`       `ObjectiveC.ObjCBool`  ClangImporter's BOOL special case
//   `SEL`        `ObjectiveC.Selector`  MappedTypes.def ("SEL")
//   `NSZone *`   `ObjectiveC.NSZone`    KnownFoundationEntity::NSZone
//
// On Darwin this module is an overlay over the `ObjectiveC` *Clang* module
// (`objc/objc.h` and friends). Agora's libobjc2 headers are not a Clang module,
// so this file declares the two C entry points it needs with `@_silgen_name`
// instead: `sel_registerName` interns a selector and `sel_isEqual`/`sel_getName`
// read it back. Both are libobjc2 exports.
//
// Why the module matters beyond `SEL`: without `ObjCBool` the importer cannot
// interpret `BOOL` (Agora's `objc/runtime.h` makes it `unsigned char`), so every
// Cocoa `BOOL` imported as `UInt8` and no `Bool` ever reached a bridge. With it,
// `BOOL` imports as `ObjCBool` and, in any position that can bridge, as `Bool` -
// the same two-step Darwin uses.
//
// `NSObject: Hashable` and `AnyHashable: _ObjectiveCBridgeable` are *not* here:
// `NSObject` is declared by Agora's Foundation headers, so those two
// conformances live in the Foundation overlay (importing Foundation from here
// would be a cycle).
//
//===----------------------------------------------------------------------===//

/// Objective-C's `BOOL`.
///
/// Agora's `BOOL` is `unsigned char` (objc/runtime.h), so the storage is one
/// byte and any non-zero value is true - the same shape Darwin uses on x86_64,
/// where `BOOL` is `signed char`. `Bool` and `ObjCBool` are distinct types on
/// purpose: `ObjCBool` is what an *unbridged* `BOOL` is, and the importer hands
/// out `Bool` wherever it can bridge losslessly.
public struct ObjCBool: ExpressibleByBooleanLiteral, Equatable, Hashable,
                        CustomStringConvertible, CustomDebugStringConvertible,
                        Sendable {
  private var value: UInt8

  public init(_ value: Bool) {
    self.value = value ? 1 : 0
  }

  /// The raw byte, for code that must preserve a `BOOL` that is neither 0 nor 1.
  public init(_ value: UInt8) {
    self.value = value
  }

  /// Allow use in a Boolean context.
  public var boolValue: Bool {
    return value != 0
  }

  public init(booleanLiteral value: Bool) {
    self.init(value)
  }

  public var description: String {
    return boolValue ? "true" : "false"
  }

  public var debugDescription: String {
    return description
  }
}

/// The bridging functions SILGen calls when a `Bool` meets a `BOOL` slot.
/// (`emitBridgeBoolToObjCBool` / `emitBridgeForeignBoolToBool` in
/// SILGenBridging.cpp look these up in this module by name.)
public func _convertBoolToObjCBool(_ x: Bool) -> ObjCBool {
  return ObjCBool(x)
}

public func _convertObjCBoolToBool(_ x: ObjCBool) -> Bool {
  return x.boolValue
}

private func _selRegisterName(_ name: UnsafePointer<CChar>) -> OpaquePointer {
  return _agora_sel_registerName(name)
}

private func _selGetName(_ sel: OpaquePointer) -> UnsafePointer<CChar> {
  return _agora_sel_getName(sel)
}

private func _selIsEqual(_ lhs: OpaquePointer, _ rhs: OpaquePointer) -> Bool {
  return _agora_sel_isEqual(lhs, rhs) != 0
}

// libobjc2's C entry points. `sel_isEqual` returns `BOOL`, i.e. one byte.
// (`sel_getUid` rather than `sel_registerName`: the latter's name is reserved
// for the Swift runtime, and both intern a selector.)
@_silgen_name("sel_getUid")
private func _agora_sel_registerName(_ name: UnsafePointer<CChar>) -> OpaquePointer

@_silgen_name("sel_getName")
private func _agora_sel_getName(_ sel: OpaquePointer) -> UnsafePointer<CChar>

@_silgen_name("sel_isEqual")
private func _agora_sel_isEqual(_ lhs: OpaquePointer,
                                _ rhs: OpaquePointer) -> UInt8

/// An Objective-C selector (`SEL`), and the type `#selector(...)` produces.
///
/// A selector is an interned name pointer; `Selector` is a one-word struct over
/// it, so it is `Equatable`/`Hashable` by `sel_isEqual` and carries the name for
/// `description`. The string-literal entry point is what the compiler lowers a
/// selector literal to.
public struct Selector: ExpressibleByStringLiteral, Equatable, Hashable,
                        CustomStringConvertible {
  private var ptr: OpaquePointer

  public init(_ value: String) {
    self.init(stringLiteral: value)
  }

  public init(stringLiteral value: String) {
    self.ptr = value.withCString { _selRegisterName($0) }
  }

  public init(unicodeScalarLiteral value: String) {
    self.init(stringLiteral: value)
  }

  public init(extendedGraphemeClusterLiteral value: String) {
    self.init(stringLiteral: value)
  }

  /// The selector's name, as `sel_getName` reports it.
  public var name: String {
    return String(cString: _selGetName(ptr))
  }

  public static func == (lhs: Selector, rhs: Selector) -> Bool {
    return _selIsEqual(lhs.ptr, rhs.ptr)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ptr)
  }

  public var description: String {
    return name
  }
}

/// `NSZone` (the Swift spelling the importer gives `NSZone *`). Agora removed
/// the zone APIs (a 32-bit concept it does not have), so this exists for the
/// type's sake and never names a real zone; `NSZone *` parameters default to
/// `nil`.
public struct NSZone {
  public var pointer: OpaquePointer
}
