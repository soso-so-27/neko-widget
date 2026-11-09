import Foundation

/// 写真のメモ（このiPhoneだけ）と、まどへ届けるひとこと（まどのみんなに届く）の
/// あいだの決まり。画面から切り離した純粋な関数だけを置き、CI で確かめる。
///
/// - メモ → ひとこと：勝手には入れない。「メモから入れる」を押したときだけ、
///   ひとことの上限（100文字・改行2つ）で切って欄に入れる。
/// - ひとこと → メモ：届けたあと、メモを持てるときだけ残す。すでにあるメモへの
///   追記は編集なので無料、新しいメモは Plus（`createPersonalMemo`）。同じ文が
///   もうメモにあれば足さない。500文字を超えるなら残さない（届けたことは失敗にしない）。
enum MemoCaptionBridge {
    /// 「メモから入れる」: the memo cut where the caption limits end, so the
    /// field never starts invalid. The person can still edit it before sending.
    static func captionDraft(fromMemo memo: String) -> String {
        var result = ""
        var characters = 0
        var lineBreaks = 0
        for character in unified(memo) {
            if characters == GroupPhotoCaption.maximumCharacters { break }
            if character == "\n" {
                if lineBreaks == GroupPhotoCaption.maximumLineBreaks { break }
                lineBreaks += 1
            }
            result.append(character)
            characters += 1
        }
        var draft = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Japanese text is far below the byte limit; stay valid regardless.
        while !draft.isEmpty, GroupPhotoCaption.validationMessage(for: draft) != nil {
            draft = String(draft.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return draft
    }

    /// The same line-break reading as `GroupPhotoCaption.normalized`.
    private static func unified(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether this person may keep words in this photo's memo: adding to a
    /// memo that exists is editing (free); a new memo needs Plus.
    static func canKeepMemo(hasExistingMemo: Bool, createDecision: MembershipAccessDecision) -> Bool {
        hasExistingMemo || createDecision == .allowed
    }

    enum Keeping: Equatable {
        /// Save this whole text as the photo's memo.
        case save(String)
        /// The memo already holds these exact words (e.g. 「メモから入れる」).
        case alreadyKept
        /// No ひとこと was sent.
        case nothingToKeep
        /// No memo yet, and a new memo needs Plus.
        case notAllowed
        /// The memo would pass its limit; it stays as it was.
        case tooLong
    }

    /// After a successful send. `existingMemo` is the memo's text, nil when the
    /// photo has no memo (a memo may exist with empty text, e.g. a weight only).
    static func keeping(caption: String, existingMemo: String?,
                        createDecision: MembershipAccessDecision,
                        maximumMemoCharacters: Int) -> Keeping {
        let words = unified(caption)
        guard !words.isEmpty else { return .nothingToKeep }
        guard canKeepMemo(hasExistingMemo: existingMemo != nil, createDecision: createDecision) else {
            return .notAllowed
        }
        let memo = (existingMemo ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !memo.isEmpty, unified(memo).contains(words) { return .alreadyKept }
        let combined = memo.isEmpty ? words : memo + "\n" + words
        guard combined.count <= maximumMemoCharacters else { return .tooLong }
        return .save(combined)
    }

    /// The ひとこと footer says 「この写真のメモにも残ります。」 only when the
    /// words will really stay: nothing typed yet counts as "will", once the
    /// person may keep memos for this photo.
    static func footerSaysKept(caption: String, existingMemo: String?,
                               createDecision: MembershipAccessDecision,
                               maximumMemoCharacters: Int) -> Bool {
        switch keeping(caption: caption, existingMemo: existingMemo,
                       createDecision: createDecision, maximumMemoCharacters: maximumMemoCharacters) {
        case .save, .alreadyKept: return true
        case .nothingToKeep: return canKeepMemo(hasExistingMemo: existingMemo != nil, createDecision: createDecision)
        case .notAllowed, .tooLong: return false
        }
    }

    /// A received photo copied to Photos is a new photo: its ひとこと stays
    /// as the memo only with Plus.
    static func keepsReceivedCaption(_ caption: String?, createDecision: MembershipAccessDecision) -> Bool {
        let words = (caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !words.isEmpty && createDecision == .allowed
    }
}
