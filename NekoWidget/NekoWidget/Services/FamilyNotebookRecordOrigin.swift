import Foundation

/// The display and the inverse of the family projection are saved atomically.
/// Only the personal projection goes into a portable backup.
enum FamilyNotebookRecordOrigin {
    typealias Object = [String: Any]
    static let tools: Set<String> = ["CatCare", "CareHandoff", "VeterinaryVisits"]
    private static let origin = "_familyNotebookPersonalV1"
    private static var invalid: CocoaError { CocoaError(.fileReadCorruptFile) }

    static func recording(_ data: Data, over previous: Data?, tool: String, family: Bool) throws -> Data {
        let display = try decode(data)
        let personal: Object
        if let previous {
            var before = try decode(previous)
            let stored = try personalObject(before, tool: tool)
            if family { personal = stored }
            else {
                before.removeValue(forKey: origin)
                guard let updated = edit(before, stored, display) as? Object else { throw invalid }
                personal = updated
            }
        } else if family {
            var empty = display
            empty[tool == "VeterinaryVisits" ? "visits" : "cats"] = [Object]()
            personal = empty
        } else { return data }
        var result = display
        if let undo = difference(display, personal) { result[origin] = undo }
        else if family { result[origin] = Object() }
        return try encode(result)
    }

    /// Projection deliberately permits incomplete objects. A tool materializes
    /// these with neutral defaults or its detached attachment type, not with
    /// any missing value from the family display.
    static func personalObject(_ data: Data, tool: String) throws -> Object {
        try personalObject(decode(data), tool: tool)
    }
    static func encode(_ object: Object) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func decode(_ data: Data) throws -> Object {
        guard let object = try JSONSerialization.jsonObject(with: data) as? Object else { throw invalid }
        return object
    }
    private static func personalObject(_ data: Object, tool: String) throws -> Object {
        var display = data
        guard let raw = display.removeValue(forKey: origin) else { return legacy(display, tool: tool) }
        guard let patch = raw as? Object, let result = try apply(patch, to: display) as? Object else { throw invalid }
        return result
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil || b == nil { return a == nil && b == nil }
        return (a as? NSObject)?.isEqual(b) == true
    }
    private struct Rows {
        let order: [String]
        let items: [String: Object]
        init?(_ value: Any?) {
            guard let array = value as? [Object] else { return nil }
            var order: [String] = [], items: [String: Object] = [:]
            for row in array {
                guard let id = (row["id"] ?? row["catID"]) as? String, UUID(uuidString: id) != nil,
                      items.updateValue(row, forKey: id) == nil else { return nil }
                order.append(id)
            }
            self.order = order; self.items = items
        }
    }

    private static func difference(_ display: Any?, _ personal: Any?) -> Object? {
        if same(display, personal) { return nil }
        guard let personal else { return ["remove": true] }
        if let a = display as? Object, let b = personal as? Object {
            var fields: Object = [:]
            for key in Set(a.keys).union(b.keys) { fields[key] = difference(a[key], b[key]) }
            return ["fields": fields]
        }
        if let a = Rows(display), let b = Rows(personal) {
            var rows: Object = [:]
            for id in Set(a.order).union(b.order) { rows[id] = difference(a.items[id], b.items[id]) }
            var change: Object = ["rows": rows]
            if a.order.filter({ b.items[$0] != nil }) != b.order { change["order"] = b.order }
            return change
        }
        return ["value": personal]
    }
    private static func apply(_ patch: Object, to display: Any?) throws -> Any? {
        if patch.isEmpty { return display }
        if patch.count == 1, let value = patch["value"] { return value }
        if patch.count == 1, patch["remove"] as? Bool == true { return nil }
        if patch.count == 1, let fields = patch["fields"] as? [String: Object], var value = display as? Object {
            for (key, change) in fields { value[key] = try apply(change, to: value[key]) }
            return value
        }
        if let changes = patch["rows"] as? [String: Object], let base = Rows(display),
           patch.count == (patch["order"] == nil ? 1 : 2) {
            var values = base.items
            for (id, change) in changes {
                let value = try apply(change, to: values[id])
                guard value == nil || value is Object else { throw invalid }
                values[id] = value as? Object
            }
            let order = patch["order"] as? [String] ?? base.order.filter { values[$0] != nil }
            guard order.count == values.count, Set(order) == Set(values.keys) else { throw invalid }
            return order.compactMap { values[$0] }
        }
        throw invalid
    }

    /// Preserve untouched private values, even if a family edit has since
    /// overwritten them in the display. Don't promote unchanged family fields
    /// when a form saves its enclosing object.
    private static func edit(_ before: Any?, _ personal: Any?, _ after: Any?) -> Any? {
        if same(before, after) { return personal }
        guard let after else { return nil }
        if let a = before as? Object, let b = after as? Object {
            let clocks = ["updatedAt", "revision", "editedAt", "editedBy"]
            var result = personal as? Object ?? [:]
            for key in Set(a.keys).union(b.keys) where !clocks.contains(key) {
                result[key] = edit(a[key], result[key], b[key])
            }
            if personal == nil, result.isEmpty { return nil }
            // Keep only the structural IDs necessary to associate a personal
            // edit. Dates, names and unchanged sibling values remain masked.
            for key in ["id", "catID", "toolCatID"] where result[key] == nil { result[key] = b[key] }
            for key in clocks where !same(a[key], b[key]) { result[key] = b[key] }
            return result
        }
        if let a = Rows(before), let b = Rows(after) {
            let p = Rows(personal)
            let order = b.order + (p?.order.filter { a.items[$0] == nil && b.items[$0] == nil } ?? [])
            let result = order.compactMap { edit(a.items[$0], p?.items[$0], b.items[$0]) as? Object }
            return personal == nil && result.isEmpty ? nil : result
        }
        return after
    }

    /// Only unambiguously whole-field family stamps are stripped from an
    /// older file. Mixed rows and compound stamps keep the owner's copy.
    private static func legacy(_ value: Object, tool: String) -> Object {
        guard tool == "CatCare", let cats = value["cats"] as? [Object] else { return value }
        func family(_ value: Any?) -> Bool {
            ((value as? Object)?["editedBy"] as? String)?.hasPrefix("family:") == true
        }
        let fields = ["name", "sex", "neutered", "birthday", "coat", "marks", "microchip", "indoorOnly",
                      "conditions", "specialDiet", "water", "litter", "temperament"]
        var result = value
        result["cats"] = cats.map { input -> Object in
            var cat = input
            for field in fields where family(cat[field]) { cat.removeValue(forKey: field) }
            return cat
        }
        return result
    }
}
