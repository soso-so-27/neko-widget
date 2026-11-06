@main struct Check {
    enum Stop: Error { case fence }
    static func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
    static func seed(active: Bool = true) throws -> (URL, [String:Data], [String:Data], URL, Data) {
        AppRecordDataset.support=FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-rebind-"+UUID().uuidString)
        let c=AppRecordDataset.control, id=UUID()
        let old=AppRecordDataset.Pointer(version:1,datasetID:id,owner:"old-owner",origin:"https://staging.invalid",manifests:["CatCare/state.json"])
        let raw=try JSONEncoder().encode(old)
        let root=AppRecordDataset.datasets.appendingPathComponent(id.uuidString)
        let data=Data("{\"retained\":\"cat and notes\"}".utf8)
        try AppRecordRebinding.write(data,to:root.appendingPathComponent("CatCare/state.json"))
        try AppRecordRebinding.write(raw,to:root.appendingPathComponent("dataset.json"))
        var previous=["binding.json":Data("{\"owner\":\"old-owner\",\"origin\":\"https://staging.invalid\"}".utf8)]
        if active { previous["active.json"]=raw; previous["owner.json"]=raw }
        var next=["binding.json":Data("{\"owner\":\"new-owner\",\"origin\":\"https://production.invalid\"}".utf8),
                  "owner.json":try JSONEncoder().encode(AppRecordDataset.Pointer(version:1,datasetID:id,owner:"new-owner",origin:"https://production.invalid"))]
        if active { next["active.json"]=try JSONEncoder().encode(AppRecordDataset.Pointer(version:1,datasetID:id,owner:"new-owner",origin:"https://production.invalid",manifests:old.manifests,sourceReceipt:raw)) }
        for(n,d) in previous {try AppRecordRebinding.write(d,to:c.appendingPathComponent(n))}
        return(c,previous,next,root,data)
    }
    static func main() throws {
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
        print("Rebinding PASS: 8 interruption states; unchanged records and dataset receipt; old settings retained; old owner rejected; missing-pointer path; expired fence and unknown metadata rejected")
    }
}
