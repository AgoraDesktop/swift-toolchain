// The P3 probe: `import Foundation` means FoundationEssentials +
// FoundationInternationalization + the bridges to Agora's Objective-C classes.
//
// Built and run by `swift-toolchain/scripts/build-foundation-p3.sh`, which fails
// if a bridge does not round-trip.  Every check is written the way a client
// writes it (`as`, `as?`), so a green run is a statement about the module, not
// about a private helper.

import Foundation

var problems: [String] = []
func expect(_ condition: Bool, _ what: String) {
  if !condition { problems.append(what) }
}

// MARK: - the value types are FoundationEssentials' ones

let greeting = "héllo 🌍"
let greetingData = Data(greeting.utf8)
expect(greetingData.count == 11, "Data from a UTF-8 string (11 UTF-8 bytes)")
expect(String(decoding: greetingData, as: UTF8.self) == greeting, "Data -> String")
expect(Data("abc".utf8).map { $0 } == [0x61, 0x62, 0x63], "Data is a collection")

let epoch = Date(timeIntervalSince1970: 0)
expect(epoch.timeIntervalSinceReferenceDate == -978307200.0, "Date reference epoch")

let url = URL(string: "https://example.com/a?b=c#frag")
expect(url?.host == "example.com", "URL host")
expect(url?.path == "/a", "URL path")

let uuid = UUID(uuidString: "12345678-1234-1234-1234-123456789012")
expect(uuid?.uuidString == "12345678-1234-1234-1234-123456789012", "UUID string form")

let indexPath = IndexPath(indexes: [1, 2, 3])
expect(indexPath.count == 3 && indexPath[2] == 3, "IndexPath elements")

let decimal = Decimal(string: "123.456")
expect(decimal != nil, "Decimal from a string")

// FoundationInternationalization is part of the same import.
expect(Locale(identifier: "en_US").identifier == "en_US", "Locale (FI)")
expect(TimeZone(identifier: "Europe/Berlin") != nil, "TimeZone (FI)")

// MARK: - Data <-> NSData

let nsData: NSData = greetingData as NSData
expect(nsData.length == 11, "Data -> NSData length")
expect((nsData as Data) == greetingData, "NSData -> Data")
expect((nsData as? Data) == greetingData, "NSData -> Data (as?)")

// MARK: - Date <-> NSDate

let nsDate: NSDate = epoch as NSDate
expect(nsDate.timeIntervalSinceReferenceDate == -978307200.0, "Date -> NSDate")
expect((nsDate as Date) == epoch, "NSDate -> Date")

// MARK: - URL <-> NSURL

let nsURL: NSURL = url! as NSURL
expect((nsURL.absoluteString() as String) == url!.absoluteString, "URL -> NSURL")
expect((nsURL as URL) == url!, "NSURL -> URL")

// MARK: - UUID <-> NSUUID

let nsUUID: NSUUID = uuid! as NSUUID
expect((nsUUID.uuidString() as String) == uuid!.uuidString, "UUID -> NSUUID")
expect((nsUUID as UUID) == uuid!, "NSUUID -> UUID")

// MARK: - IndexPath <-> NSIndexPath

let nsIndexPath: NSIndexPath = indexPath as NSIndexPath
expect(nsIndexPath.length == 3, "IndexPath -> NSIndexPath length")
expect(nsIndexPath.index(atPosition: 2) == 3, "IndexPath -> NSIndexPath element")
expect((nsIndexPath as IndexPath) == indexPath, "NSIndexPath -> IndexPath")

// MARK: - Decimal <-> NSDecimalNumber

let nsDecimal: NSDecimalNumber = decimal! as NSDecimalNumber
expect((nsDecimal.stringValue() as String) == "123.456", "Decimal -> NSDecimalNumber value")
expect((nsDecimal as Decimal) == decimal!, "NSDecimalNumber -> Decimal")

// MARK: - TimeZone <-> NSTimeZone

let timeZone = TimeZone(identifier: "Europe/Berlin")!
let nsTimeZone: NSTimeZone = timeZone as NSTimeZone
expect((nsTimeZone.name() as String) == timeZone.identifier, "TimeZone -> NSTimeZone")
expect((nsTimeZone as TimeZone) == timeZone, "NSTimeZone -> TimeZone")

// MARK: - Locale <-> NSLocale

let locale = Locale(identifier: "en_US")
let nsLocale: NSLocale = locale as NSLocale
expect((nsLocale.localeIdentifier() as String) == locale.identifier, "Locale -> NSLocale")
expect((nsLocale as Locale) == locale, "NSLocale -> Locale")

// MARK: - Calendar <-> NSCalendar

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/New_York")!
calendar.firstWeekday = 2
calendar.minimumDaysInFirstWeek = 4
let nsCalendar: NSCalendar = calendar as NSCalendar
expect((nsCalendar.calendarIdentifier() as String) == "gregorian", "Calendar -> NSCalendar")
expect(nsCalendar.firstWeekday() == 2, "Calendar firstWeekday crosses")
let calendarBack = nsCalendar as Calendar
expect(calendarBack.identifier == .gregorian, "NSCalendar -> Calendar identifier")
expect(calendarBack.firstWeekday == 2, "NSCalendar -> Calendar firstWeekday")
expect(calendarBack.timeZone.identifier == "America/New_York",
       "NSCalendar -> Calendar time zone")

// MARK: - DateComponents <-> NSDateComponents

var components = DateComponents()
components.year = 2024
components.month = 2
components.day = 29
components.calendar = calendar
components.timeZone = calendar.timeZone
let nsComponents: NSDateComponents = components as NSDateComponents
expect(nsComponents.year() == 2024 && nsComponents.month() == 2 && nsComponents.day() == 29,
       "DateComponents -> NSDateComponents fields")
expect(nsComponents.second() == NSDateComponentUndefined,
       "an unset DateComponents field stays undefined")
let componentsBack = nsComponents as DateComponents
expect(componentsBack.year == 2024 && componentsBack.month == 2 && componentsBack.day == 29,
       "NSDateComponents -> DateComponents fields")
expect(componentsBack.second == nil, "an undefined field comes back as nil")

// MARK: - DateInterval <-> NSDateInterval

let interval = DateInterval(start: Date(timeIntervalSince1970: 1000), duration: 3600)
let nsInterval: NSDateInterval = interval as NSDateInterval
expect(nsInterval.duration == 3600, "DateInterval -> NSDateInterval duration")
expect((nsInterval.startDate as Date) == interval.start, "DateInterval -> NSDateInterval start")
expect((nsInterval as DateInterval) == interval, "NSDateInterval -> DateInterval")

// MARK: - the stdlib bridges still come with the same import

let string: NSString = greeting as NSString
expect(string.length == 8 && (string as String) == greeting, "String <-> NSString (8 UTF-16 units)")
let array = [1, 2, 3] as NSArray
expect(array.count == 3 && (array as? [Int]) == [1, 2, 3], "Array <-> NSArray")
let dictionary = ["k": 1] as NSDictionary
expect((dictionary as? [String: Int]) == ["k": 1], "Dictionary <-> NSDictionary")
let number = 42 as NSNumber
expect((number as? Int) == 42, "Int <-> NSNumber")

// And an Objective-C object still behaves like one.
let object = NSObject()
expect(object.isKind(of: NSObject.self), "NSObject interop")

if problems.isEmpty {
  print("foundation p3: ok (\(problems.count) problems)")
} else {
  print("foundation p3: \(problems.count) failure(s): \(problems)")
  exit(1)
}
