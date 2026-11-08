import Foundation

// What the tools show and print from 「この子のこと」, with no screen code, so
// CI can build it on a Mac and check the finished outputs (11/8: three output
// mistakes reached a TestFlight build). The store lookups live in CatCareView.

enum CatCareFormat {
    /// 「去勢済み」 for a male, 「避妊済み」 for a female, both words when the sex
    /// is not written; nil when it is not known (347: 「去勢・避妊 済み」 read oddly).
    static func neutered(_ value: CatCareTriState?, sex: CatCareSex?) -> String? {
        let word: String = switch sex ?? .unknown {
        case .male: "去勢"
        case .female: "避妊"
        case .unknown: "去勢・避妊"
        }
        switch value ?? .unknown {
        case .yes: return word + "済み"
        case .no: return word + "はまだ"
        case .unknown: return nil
        }
    }
    static func day(_ day: CatCareDay) -> String { "\(day.year)/\(day.month)/\(day.day)" }

    static func weight(_ grams: Int) -> String {
        grams >= 1000 ? String(format: "%.2fkg", Double(grams) / 1000) : "\(grams)g"
    }
}

// MARK: - What tools show from 「この子のこと」

/// Read-only lines a tool shows or exports. Empty items say so instead of
/// inventing anything; nothing here is a medical judgement.
enum CatCareSummary {
    /// What is shown or printed for others: rows that only say 「未記入」 or
    /// 「未確認」 are left out (347).
    static func shown(_ lines: [(String, String)]) -> [(String, String)] {
        lines.filter { !$0.1.hasPrefix("未記入") && !$0.1.hasPrefix("未確認") }
    }

    /// For 「病院で見せる」: what a vet usually asks first.
    static func veterinaryFields(_ record: CatCareRecord?, household: CatCareHousehold?) -> [(String, String)] {
        let empty = "未記入"
        func text(_ value: String?) -> String {
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? empty : trimmed
        }
        var fields: [(String, String)] = []
        let sex: String = switch record?.sex?.value ?? .unknown {
        case .male: "オス"
        case .female: "メス"
        case .unknown: "未記入"
        }
        let neutered: String = CatCareFormat.neutered(record?.neutered?.value, sex: record?.sex?.value) ?? "去勢・避妊 未記入"
        // Both unknown: one 「未記入」, not 「未記入・去勢・避妊 未記入」.
        let bothUnknown = (record?.sex?.value ?? .unknown) == .unknown && (record?.neutered?.value ?? .unknown) == .unknown
        fields.append(("性別", bothUnknown ? empty : sex + "・" + neutered))
        fields.append(("年齢", CatCareLostCat.age(record?.birthday?.value, today: CatCareDay(date: Date())) ?? empty))
        fields.append(("マイクロチップ", record?.microchipStatus == CatCareMicrochipStatus.none
                       ? "入っていない" : text(record?.microchip?.value)))
        fields.append(("持病", record?.conditionsStatus == CatCareConditionsStatus.none
                       ? "なし" : text(record?.conditions?.value)))
        let allergy: String = switch record?.allergy?.value.status ?? .unknown {
        case .none: "なし"
        case .recorded: text(record?.allergy?.value.text)
        case .unknown: "未確認"
        }
        fields.append(("アレルギー", allergy))
        let medications = (record?.activeMedications ?? []).map { medication in
            [medication.name, medication.dose, medication.schedule].filter { !$0.isEmpty }.joined(separator: "・")
        }
        fields.append(("飲んでいる薬", medications.isEmpty ? empty : medications.joined(separator: "\n")))
        let vaccinations = (record?.activeVaccinations ?? []).prefix(3).map {
            "\($0.kind)（\(CatCareFormat.day($0.givenOn))）" + ($0.proof != nil ? " 証明あり" : "")
        }
        fields.append(("ワクチン", vaccinations.isEmpty
                       ? (record?.vaccinationStatus == CatCareVaccinationStatus.none ? "受けていない" : empty)
                       : vaccinations.joined(separator: "\n")))
        fields.append(("体重の推移", weightTrend(record).map { $0.isEmpty ? empty : $0.joined(separator: "\n") } ?? empty))
        if let diet = record?.specialDiet?.value, !diet.isEmpty { fields.append(("療法食など", diet)) }
        let vet = record?.vetOverride?.value ?? household?.vet?.value
        if let vet, vet.vetStatus == CatCareVetStatus.none {
            fields.append(("かかりつけ病院", "まだない"))
        } else if let vet, !vet.isEmpty {
            fields.append(("かかりつけ病院", [vet.name, vet.phone].filter { !$0.isEmpty }.joined(separator: " ")))
        }
        return fields
    }

    /// For 「預けるとき」: 「3歳・4.20kg（2026/10/20）」. Nil when neither is recorded.
    static func ageAndWeight(_ record: CatCareRecord?, today: CatCareDay? = CatCareDay(date: Date())) -> String? {
        var parts: [String] = []
        if let age = CatCareLostCat.age(record?.birthday?.value, today: today) { parts.append(age) }
        if let latest = record?.activeWeights.first {
            parts.append(CatCareFormat.weight(latest.grams) + "（\(CatCareFormat.day(latest.measuredOn))）")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    /// For 「預けるとき」 when health is shared: each medicine on its own line with
    /// dose and timing, and the allergy record. Only what the owner wrote.
    static func careHandoffHealthFields(_ record: CatCareRecord?) -> [(String, String)] {
        var fields: [(String, String)] = []
        let medicines = (record?.activeMedications ?? []).map { medicine in
            [medicine.name, medicine.dose, medicine.schedule, medicine.note]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "・")
        }.filter { !$0.isEmpty }
        if !medicines.isEmpty { fields.append(("飲んでいる薬（量・時間）", medicines.joined(separator: "\n"))) }
        switch record?.allergy?.value.status ?? .unknown {
        case .none: fields.append(("アレルギー", "なし"))
        case .recorded:
            let text = (record?.allergy?.value.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            fields.append(("アレルギー", text.isEmpty ? "あり（くわしくは飼い主に聞いてください）" : text))
        case .unknown: break
        }
        return fields
    }

    // MARK: One place for each fact

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 「この子のこと」's value; the tool's older entry only for a field never
    /// set here. A field the owner cleared stays empty.
    private static func pick(_ field: CatCareStamped<String>?, _ legacy: String?, empty: String) -> String {
        if let field { return nonEmpty(field.value) ?? empty }
        return nonEmpty(legacy) ?? empty
    }

    /// 「朝7時 腎臓ケア 20g」, one meal a line.
    static func mealsText(_ record: CatCareRecord?) -> String? {
        let lines = (record?.activeMeals ?? []).map { meal in
            [meal.time, meal.food, meal.amount].compactMap(nonEmpty).joined(separator: " ")
        }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 「キジトラ・しっぽが短い」.
    static func features(_ record: CatCareRecord?, legacy: String?) -> String? {
        if record?.coat != nil || record?.marks != nil {
            let parts = [record?.coat?.value, record?.marks?.value].compactMap(nonEmpty)
            return parts.isEmpty ? nil : parts.joined(separator: "・")
        }
        return nonEmpty(legacy)
    }

    /// For 「預けるとき」: everyday care, all from 「この子のこと」.
    /// 「未記入」 rows are shown in the app only; the handed memo leaves them out.
    static func careHandoffLines(_ record: CatCareRecord?, legacy cat: CareCat) -> [(String, String)] {
        let empty = "未記入（飼い主に聞いてください）"
        var lines: [(String, String)] = []
        // 11/8: an indoor cat must not be let out; said right under the first notes.
        if record?.indoorOnly?.value == .yes { lines.append(("暮らし", "外に出さない（室内飼い）")) }
        if let about = ageAndWeight(record) { lines.append(("年齢・体重", about)) }
        let neverHadMeals = record?.meals.isEmpty ?? true
        let food = mealsText(record) ?? (neverHadMeals ? nonEmpty(cat.reusableFood) : nil)
        lines.append(("ごはん", food ?? empty))
        if let diet = nonEmpty(record?.specialDiet?.value) { lines.append(("療法食など", diet)) }
        lines.append(("水", pick(record?.water, cat.water, empty: empty)))
        lines.append(("トイレ", pick(record?.litter, cat.toilet, empty: empty)))
        lines.append(("接し方・苦手なこと", pick(record?.temperament, cat.handling, empty: empty)))
        return lines
    }

    /// For 「預けるとき」 when health is shared: medicines, allergy and conditions.
    /// A note written in the tool before is shown until 「この子のこと」 has them.
    static func careHandoffHealthLines(_ record: CatCareRecord?, legacy cat: CareCat) -> [(String, String)] {
        var fields = careHandoffHealthFields(record)
        if let conditions = nonEmpty(record?.conditions?.value) { fields.append(("持病", conditions)) }
        if fields.isEmpty, cat.healthStatus != .unknown {
            fields.append(("薬・アレルギー", cat.healthText))
        }
        if fields.isEmpty { fields.append(("薬・アレルギー", "未記入（飼い主に聞いてください）")) }
        return fields
    }

    /// For 「避難に備える」: one cat's sheet. What is shown follows the toggles;
    /// everything per cat comes from 「この子のこと」.
    static func evacuationShareFields(_ record: CatCareRecord?, legacy cat: EvacuationCat,
                                      household: CatCareHousehold?, planContact: String,
                                      disclosure: EvacuationDisclosure) -> [(String, String)] {
        let empty = "未記入"
        var fields: [(String, String)] = [("見分ける特徴", features(record, legacy: cat.features) ?? empty)]
        fields.append(evacuationFields(record)[0])
        if disclosure.food {
            let neverHadMeals = record?.meals.isEmpty ?? true
            let food = [mealsText(record), nonEmpty(record?.specialDiet?.value)].compactMap { $0 }
            let text = food.isEmpty ? (neverHadMeals ? nonEmpty(cat.food) : nil) : food.joined(separator: "\n")
            fields.append(("いつものごはん", text ?? empty))
        }
        if disclosure.handling {
            fields.append(("接し方・苦手なこと", pick(record?.temperament, cat.handling, empty: empty)))
        }
        if disclosure.medical {
            var health: [(String, String)] = []
            if let conditions = nonEmpty(record?.conditions?.value) { health.append(("持病", conditions)) }
            health += careHandoffHealthFields(record)
            if health.isEmpty {
                // Older entry from this tool only when it says something.
                health.append(cat.medicalStatus == .unknown ? ("病歴・薬", empty) : ("病歴・薬", cat.medicalText))
            }
            fields += health
        }
        if disclosure.contact {
            fields.append(("飼い主の連絡先", pick(household?.ownerContact, planContact, empty: empty)))
        }
        if disclosure.catCare { fields += evacuationFields(record).dropFirst() }
        return fields
    }

    /// For 「避難に備える」: what a shelter asks to see.
    static func evacuationFields(_ record: CatCareRecord?,
                                 today: CatCareDay? = CatCareDay(date: Date())) -> [(String, String)] {
        let empty = "未記入"
        var about: [String] = []
        switch record?.sex?.value ?? .unknown {
        case .male: about.append("オス")
        case .female: about.append("メス")
        case .unknown: break
        }
        if let neutered = CatCareFormat.neutered(record?.neutered?.value, sex: record?.sex?.value) { about.append(neutered) }
        if let age = CatCareLostCat.age(record?.birthday?.value, today: today) { about.append(age) }
        if let latest = record?.activeWeights.first { about.append(CatCareFormat.weight(latest.grams)) }
        var fields: [(String, String)] = [("性別・年齢・体重", about.isEmpty ? empty : about.joined(separator: "・"))]
        let chip = (record?.microchip?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        fields.append(("マイクロチップ番号", chip.isEmpty
                       ? (record?.microchipStatus == CatCareMicrochipStatus.none ? "入っていない" : empty) : chip))
        let vaccinations = (record?.activeVaccinations ?? []).prefix(4).map { entry in
            var line = "\(entry.kind)（\(CatCareFormat.day(entry.givenOn))）"
            if let next = entry.nextDueOn { line += " 次回 \(CatCareFormat.day(next))" }
            if entry.proof != nil { line += " 証明あり" }
            return line
        }
        fields.append(("ワクチン", vaccinations.isEmpty
                       ? (record?.vaccinationStatus == CatCareVaccinationStatus.none ? "受けていない" : empty)
                       : vaccinations.joined(separator: "\n")))
        return fields
    }

    /// For 「迷子のとき」: what the police, the health center and shelters ask.
    /// Shown in the app for reporting; none of it goes on the flyer by itself.
    static func lostCatReportFields(_ record: CatCareRecord?,
                                    today: CatCareDay? = CatCareDay(date: Date())) -> [(String, String)] {
        let empty = "未記入"
        func text(_ value: String?) -> String {
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? empty : trimmed
        }
        var fields: [(String, String)] = []
        let sex: String = switch record?.sex?.value ?? .unknown {
        case .male: "オス"
        case .female: "メス"
        case .unknown: empty
        }
        let neutered: String = CatCareFormat.neutered(record?.neutered?.value, sex: record?.sex?.value).map { "・" + $0 } ?? ""
        fields.append(("性別", sex + neutered))
        fields.append(("年齢", CatCareLostCat.age(record?.birthday?.value, today: today) ?? empty))
        if let latest = record?.activeWeights.first {
            fields.append(("体重", CatCareFormat.weight(latest.grams) + "（\(CatCareFormat.day(latest.measuredOn))）"))
        }
        fields.append(("毛色", text(record?.coat?.value)))
        fields.append(("見分ける特徴", text(record?.marks?.value)))
        fields.append(("マイクロチップ番号", record?.microchipStatus == CatCareMicrochipStatus.none
                       ? "入っていない" : text(record?.microchip?.value)))
        let indoor: String = switch record?.indoorOnly?.value ?? .unknown {
        case .yes: "室内飼い（外に慣れていない）"
        case .no: "外にも出る"
        case .unknown: empty
        }
        fields.append(("暮らし", indoor))
        let medications = (record?.activeMedications ?? []).map(\.name).filter { !$0.isEmpty }
        if !medications.isEmpty { fields.append(("飲んでいる薬", medications.joined(separator: "・"))) }
        return fields
    }

    /// Newest first, with the change from the previous record:
    /// 「2026/10/20 4.20kg（前回から −0.10kg）」. Up to six lines.
    static func weightTrend(_ record: CatCareRecord?) -> [String]? {
        guard let weights = record?.activeWeights, !weights.isEmpty else { return nil }
        let recent = Array(weights.prefix(7))
        return recent.prefix(6).enumerated().map { index, entry in
            var line = CatCareFormat.day(entry.measuredOn) + " " + CatCareFormat.weight(entry.grams)
            if index + 1 < recent.count {
                let diff = entry.grams - recent[index + 1].grams
                let sign = diff > 0 ? "＋" : diff < 0 ? "−" : "±"
                line += "（前回から \(sign)\(String(format: "%.2f", Double(abs(diff)) / 1000))kg）"
            }
            return line
        }
    }
}

// MARK: - 見分ける写真 kept by the tools before 11/9

/// 迷子のとき's draft key: a profile ID, or 「guest-tool-」 and the shared tool
/// cat ID. Other guest keys (an unregistered cat) have no 「この子のこと」.
enum LostCatCatCareKey {
    static func parse(_ key: String) -> (catID: UUID?, profileID: UUID?)? {
        if let profileID = UUID(uuidString: key) { return (nil, profileID) }
        let prefix = "guest-tool-"
        if key.hasPrefix(prefix), let catID = UUID(uuidString: String(key.dropFirst(prefix.count))) {
            return (catID, nil)
        }
        return nil
    }
}

extension EvacuationCat {
    /// The tool's own older photo for a role. The usual photo stands in for
    /// the face; the photo with the owner never does.
    func legacyIdentifyingPhoto(_ role: CatCarePhotoRole) -> String? {
        role == .face ? photos["face"] ?? photos["reference"] : photos["body"]
    }
}

extension CatCareToolPhotos {
    static func lostCat(key: String, draft: LostCatDraft) -> Self? {
        guard let ids = LostCatCatCareKey.parse(key) else { return nil }
        return Self(tool: "LostCat", catID: ids.catID, profileID: ids.profileID,
                    face: draft.faceFileName, body: draft.bodyFileName)
    }

    static func evacuation(_ cat: EvacuationCat) -> Self {
        Self(tool: "Evacuation", catID: cat.toolCatID ?? cat.id, profileID: cat.profileID.flatMap(UUID.init(uuidString:)),
             face: cat.legacyIdentifyingPhoto(.face), body: cat.legacyIdentifyingPhoto(.body))
    }

    /// 預けるとき kept one photo, 「渡す写真」: it was the face photo.
    static func care(_ cat: CareCat) -> Self {
        Self(tool: "CareHandoff", catID: cat.toolCatID ?? cat.id, profileID: cat.profileID.flatMap(UUID.init(uuidString:)),
             face: cat.photoName, body: nil)
    }

    /// Every tool's older photos, in no particular order (the rule orders them).
    static func all(lost: [String: LostCatDraft], evacuation: EvacuationPlan, care: CareHandoffPlan) -> [Self] {
        lost.keys.sorted().compactMap { key in lost[key].flatMap { Self.lostCat(key: key, draft: $0) } }
            + evacuation.cats.map { Self.evacuation($0) } + care.cats.map { Self.care($0) }
    }
}
