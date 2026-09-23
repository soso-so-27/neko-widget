# Full app UI test sharding

Scope: CI orchestration only. Keep the existing full test selection, fixture setup, build, Photos smoke, runtime checks, and three Gallery conditions. Split only `full-v1` app UI into the SoloMemories suite and the remaining suites. A mapped scope still has its single app UI job. Both full shards must succeed on the same SHA; one shard or an old unsharded result is not release evidence.

The first preservation-usage candidate ran all 62 app UI tests but the single Mac job reached its 75-minute limit during result export. Earlier full-route observations were 64.43 minutes (failed) and 97.92 minutes (successful retry); neither measures the new split. The target is to finish verification and evidence export below each shard's 60-minute cap, with at most five initial Mac slots by running the Gallery/runtime matrix one lane at a time. This may use more total runner minutes because the two UI shards prepare separate Simulators. Initial 30-minute development target is not credible for this full route; plan against the observed historical upper bound until the new candidate is measured. Do not call the split faster until the actual candidate elapsed and runner minutes are recorded.

The preservation feature stays default OFF. This CI change does not deploy or distribute it.
