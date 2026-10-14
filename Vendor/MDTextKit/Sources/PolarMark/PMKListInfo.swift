import Foundation

/// `PMKListInfo` (PolarMark). Stored as the value of the `PMKListItem`
/// attribute. Decompiled semantics:
///   listType:   1 = unordered, 2 = ordered, 3 = blockquote
///   listSubType: 4 = "1." delimiter, 5 = "1)" delimiter, 6 = callout
///   taskType:   0 = not a task, 1 = open, 2 = completed
///   listLevel:  0-based nesting level
///   itemIndex:  index of the item inside its list
public final class PMKListInfo: NSObject, NSCopying, NSSecureCoding {
    public static var supportsSecureCoding: Bool { true }

    public var listType: Int
    public var listSubType: Int
    public var taskType: Int
    public var listLevel: Int
    public var itemIndex: Int
    public var orderedListItemNumber: Int = 0
    public var relativeListLevel: Int = 0

    public static let unorderedType = 1
    public static let orderedType = 2
    public static let blockquoteType = 3

    public init(listType: Int, subType: Int, taskType: Int, level: Int, itemIndex: Int) {
        self.listType = listType
        self.listSubType = subType
        self.taskType = taskType
        self.listLevel = level
        self.itemIndex = itemIndex
    }

    public static func listInfo(listType: Int, subType: Int, taskType: Int, level: Int, itemIndex: Int) -> PMKListInfo {
        PMKListInfo(listType: listType, subType: subType, taskType: taskType, level: level, itemIndex: itemIndex)
    }

    public required init?(coder: NSCoder) {
        listType = coder.decodeInteger(forKey: "listType")
        listSubType = coder.decodeInteger(forKey: "listSubType")
        taskType = coder.decodeInteger(forKey: "taskType")
        listLevel = coder.decodeInteger(forKey: "listLevel")
        itemIndex = coder.decodeInteger(forKey: "itemIndex")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(listType, forKey: "listType")
        coder.encode(listSubType, forKey: "listSubType")
        coder.encode(taskType, forKey: "taskType")
        coder.encode(listLevel, forKey: "listLevel")
        coder.encode(itemIndex, forKey: "itemIndex")
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        PMKListInfo(listType: listType, subType: listSubType, taskType: taskType, level: listLevel, itemIndex: itemIndex)
    }

    public var isOrderedList: Bool { listType == 2 }
    public var isUnorderedList: Bool { listType == 1 }
    public var isTaskList: Bool { taskType != 0 }
    public var isBlockQuote: Bool { listType == 3 }
    public var isCallout: Bool { listSubType == 6 }
    /// Callout kind (key into MDBlockQuoteTextStyler.calloutColors); 0 until callouts are parsed.
    public var calloutType: Int = 0

    /// "." for subtype 4, ")" for subtype 5.
    public var orderedListItemNumberDelimiter: String? {
        if listSubType == 4 { return "." }
        if listSubType == 5 { return ")" }
        return nil
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? PMKListInfo else { return false }
        return o.listType == listType && o.listSubType == listSubType && o.taskType == taskType && o.listLevel == listLevel && o.itemIndex == itemIndex
    }

    public override var hash: Int { listType &* 31 &+ listLevel &* 7 &+ itemIndex &* 3 &+ taskType }

    public override var description: String {
        "<PMKListInfo type=\(listType) sub=\(listSubType) task=\(taskType) level=\(listLevel) index=\(itemIndex)>"
    }
}
