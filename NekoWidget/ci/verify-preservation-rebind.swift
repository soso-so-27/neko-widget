@main struct Check {
    enum Stop: Error { case fence }
    static func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
    static func seed(active: Bool = true, sameOrigin: Bool = false) throws -> (URL, [String:Data], [String:Data], URL, Data) {
        AppRecordDataset.support=FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-rebind-"+UUID().uuidString)
        let c=AppRecordDataset.control, id=UUID()
        let old=AppRecordDataset.Pointer(version:1,datasetID:id,owner:"old-owner",origin:"https://staging.invalid",manifests:["CatCare/state.json"])
        let raw=try JSONEncoder().encode(old)
        let root=AppRecordDataset.datasets.appendingPathComponent(id.uuidString, isDirectory: true)
        let data=Data("{\"retained\":\"cat and notes\"}".utf8)
        try AppRecordRebinding.write(data,to:root.appendingPathComponent("CatCare/state.json"))
        try AppRecordRebinding.write(raw,to:root.appendingPathComponent("dataset.json"))
        var previous=["binding.json":Data("{\"owner\":\"old-owner\",\"origin\":\"https://staging.invalid\"}".utf8)]
        if active { previous["active.json"]=raw; previous["owner.json"]=raw }
        let newOrigin = sameOrigin ? "https://staging.invalid" : "https://production.invalid"
        var next=["binding.json":Data(("{\"owner\":\"new-owner\",\"origin\":\"" + newOrigin + "\"}").utf8),
                  "owner.json":try JSONEncoder().encode(AppRecordDataset.Pointer(version:1,datasetID:id,owner:"new-owner",origin:newOrigin))]
        if active { next["active.json"]=try JSONEncoder().encode(AppRecordDataset.Pointer(version:1,datasetID:id,owner:"new-owner",origin:newOrigin,manifests:old.manifests,sourceReceipt:raw)) }
        for(n,d) in previous {try AppRecordRebinding.write(d,to:c.appendingPathComponent(n))}
        return(c,previous,next,root,data)
    }
    static func main() throws {
        let intent = AppRecordSaveIntent(), ticket = intent.ticket()
        var published = false
        let fence = intent.fence(ticket, { try $0() })
        intent.invalidate()
        do { try fence { published = true }; preconditionFailure("paused restore published") }
        catch is CancellationError {}
        check(!published, "pause wins over a late restore/authentication publication")
        let nextFence = intent.fence(intent.ticket(), { try $0() })
        try nextFence { published = true }
        check(published, "a later explicit start has a fresh intent")
        do {
            let(c,old,next,root,data)=try seed(sameOrigin:true)
            defer {try? FileManager.default.removeItem(at:AppRecordDataset.support)}
            try AppRecordRebinding.begin(at:c,previous:old,next:next,fence:{})
            try AppRecordDataset.requireScope(owner:"new-owner",origin:"https://staging.invalid")
            check(try Data(contentsOf:root.appendingPathComponent("CatCare/state.json"))==data,"account switch retains local bytes")
            let marker=try JSONDecoder().decode(AppRecordRebinding.Marker.self,from:Data(contentsOf:c.appendingPathComponent("rebind.json")))
            check(try Data(contentsOf:c.appendingPathComponent("previous-settings/"+marker.id.uuidString+"/binding.json"))==old["binding.json"],"same-origin switch retains old binding")
        }
        for mask in 0..<8 {
            let (c,old,next,root,data)=try seed()
            defer {try? FileManager.default.removeItem(at:AppRecordDataset.support)}
            try AppRecordDataset.requireScope(owner:"old-owner",origin:"https://staging.invalid")
            check(try AppRecordDataset.root()==root,"original receipt valid")
            try AppRecordRebinding.begin(at:c,previous:old,next:next,fence:{})
            let markerURL=c.appendingPathComponent("rebind.json")
            var marker=try JSONDecoder().decode(AppRecordRebinding.Marker.self,from:Data(contentsOf:markerURL))
            let saved=c.appendingPathComponent("previous-settings/"+marker.id.uuidString)
            let names=AppRecordRebinding.names.sorted()
            for(i,name) in names.enumerated(){try AppRecordRebinding.write((mask & (1<<i)) == 0 ? old[name]! : next[name]!,to:c.appendingPathComponent(name))}
            marker.pending=true
            try AppRecordRebinding.write(JSONEncoder().encode(marker),to:markerURL)
            // Simulated restart: reading the root resumes the actual transaction.
            check(try AppRecordDataset.root()==root,"same root after interrupted publication")
            try AppRecordDataset.requireScope(owner:"new-owner",origin:"https://production.invalid")
            do {try AppRecordDataset.requireScope(owner:"old-owner",origin:"https://staging.invalid");preconditionFailure("old owner must fail")}
            catch ManagedPreservationError.staleSession {}
            for name in names {
                check(try Data(contentsOf:c.appendingPathComponent(name))==next[name],"complete new settings")
                check(try Data(contentsOf:saved.appendingPathComponent(name))==old[name],"exact retained old settings")
            }
            check(try Data(contentsOf:root.appendingPathComponent("CatCare/state.json"))==data,"record bytes unchanged")
            check(try Data(contentsOf:root.appendingPathComponent("dataset.json"))==old["active.json"],"dataset receipt unchanged")
        }
        for active in [false,true] {
            let(c,old,next,_,_)=try seed(active:active)
            defer {try? FileManager.default.removeItem(at:AppRecordDataset.support)}
            do {try AppRecordRebinding.begin(at:c,previous:old,next:next,fence:{throw Stop.fence});preconditionFailure("expired fence")}
            catch Stop.fence {}
            for name in AppRecordRebinding.names {check(try AppRecordRebinding.bytes(c.appendingPathComponent(name))==old[name],"fence failure must retain all settings")}
            try AppRecordRebinding.begin(at:c,previous:old,next:next,fence:{})
            try AppRecordDataset.requireScope(owner:"new-owner",origin:"https://production.invalid")
            var marker=try JSONDecoder().decode(AppRecordRebinding.Marker.self,from:Data(contentsOf:c.appendingPathComponent("rebind.json")))
            marker.pending=true
            try AppRecordRebinding.write(JSONEncoder().encode(marker),to:c.appendingPathComponent("rebind.json"))
            try AppRecordRebinding.write(Data("unexpected".utf8),to:c.appendingPathComponent("binding.json"))
            do {try AppRecordRebinding.recover(at:c);preconditionFailure("unknown metadata must not be overwritten")}
            catch AppRecordBindingError.rebinding {}
            check(try Data(contentsOf:c.appendingPathComponent("binding.json"))==Data("unexpected".utf8),"unknown bytes retained")
        }
        // 11/20: only the explicit start repairs settings this build cannot use.
        do {
            let current = "app-records-automatic-v1", decodes: (Data) -> Bool = { _ in true }
            func json(_ text: String) -> Data { Data(text.utf8) }
            check(AppRecordUnusableBinding.classify(json("{\"version\":2,\"consent\":\"app-records-automatic-v1\"}"), currentConsent: current, decodes: decodes) == .newerFormat, "a newer format is refused")
            check(AppRecordUnusableBinding.classify(json("{\"version\":2}"), currentConsent: current, decodes: { _ in false }) == .newerFormat, "a newer format that does not decode is still refused")
            check(AppRecordUnusableBinding.classify(json("{\"version\":1,\"consent\":\"app-records-automatic-v2\"}"), currentConsent: current, decodes: decodes) == .newerConsent, "a newer consent is refused")
            check(AppRecordUnusableBinding.classify(json("{\"version\":1,\"consent\":\"other-terms\"}"), currentConsent: current, decodes: decodes) == .newerConsent, "an unplaceable consent is refused")
            check(AppRecordUnusableBinding.classify(json("not json"), currentConsent: current, decodes: decodes) == .unreadable, "corrupt bytes are unreadable")
            check(AppRecordUnusableBinding.classify(json("{\"version\":true,\"consent\":\"app-records-automatic-v1\"}"), currentConsent: current, decodes: decodes) == .unreadable, "a boolean version is not a version")
            check(AppRecordUnusableBinding.classify(json("{\"version\":1,\"consent\":\"app-records-automatic-v1\"}"), currentConsent: current, decodes: { _ in false }) == .unreadable, "today's consent that does not decode is unreadable")
            check(AppRecordUnusableBinding.classify(json("{\"version\":1,\"consent\":\"app-records-automatic-v1\"}"), currentConsent: current, decodes: decodes) == nil, "usable settings are left alone")
            guard case .olderConsent(let repaired)? = AppRecordUnusableBinding.classify(json("{\"version\":1,\"consent\":\"app-records-automatic-v1\",\"revision\":7,\"later\":\"kept\"}"), currentConsent: "app-records-automatic-v2", decodes: decodes) else { preconditionFailure("an older consent is repaired") }
            let object = try JSONSerialization.jsonObject(with: repaired) as! [String: Any]
            check(object["consent"] as? String == "app-records-automatic-v2" && object["revision"] as? Int == 7 && object["later"] as? String == "kept", "repair changes only the consent")
            check(AppRecordUnusableBinding.mayRepair(AppRecordBindingError.consent) && AppRecordUnusableBinding.mayRepair(AppRecordBindingError.format) && !AppRecordUnusableBinding.mayRepair(AppRecordBindingError.destination), "only consent/format/corrupt settings are repaired")
            AppRecordDataset.support=FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-unusable-"+UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:AppRecordDataset.support)}
            let raw = json("{\"version\":1,\"consent\":\"broken")
            try AppRecordUnusableBinding.setAside(raw, in: AppRecordDataset.control)
            try AppRecordUnusableBinding.setAside(raw, in: AppRecordDataset.control)
            let kept = try FileManager.default.contentsOfDirectory(at: AppRecordDataset.control.appendingPathComponent("previous-settings"), includingPropertiesForKeys: nil)
            check(kept.count == 2 && kept.allSatisfy { (try? Data(contentsOf: $0.appendingPathComponent("binding.json"))) == raw }, "each set-aside copy is exact and never overwritten")
        }
        print("Rebinding PASS: 8 interruption states; unchanged records and dataset receipt; old settings retained; old owner rejected; missing-pointer path; expired fence and unknown metadata rejected; unusable settings classified and kept aside")
    }
}
