
@main struct Check {
 @MainActor static func main() async throws {
  var attempts=0; var pauses=0
  let success = try await PreservationOpeningCheck.read(observingOnly:true,pause:{ pauses += 1 }) {
   attempts += 1; if attempts == 1 { throw ManagedPreservationError.unavailable }; return true
  }
  precondition(success && attempts == 2 && pauses == 1)
  attempts=0; pauses=0
  do { let _: Bool = try await PreservationOpeningCheck.read(observingOnly:true,pause:{pauses += 1}) {
   attempts += 1; throw ManagedPreservationError.unavailable
  }; fatalError("must report second failure") } catch ManagedPreservationError.unavailable {}
  precondition(attempts == 2 && pauses == 1)
  for observing in [false,true] {
   attempts=0; pauses=0
   do { let _: Bool = try await PreservationOpeningCheck.read(observingOnly:observing,pause:{pauses += 1}) {
    attempts += 1; throw ManagedPreservationError.staleSession
   }; fatalError("identity must fail") } catch ManagedPreservationError.staleSession {}
   precondition(attempts == 1 && pauses == 0)
  }
  attempts=0
  do { let _: Bool = try await PreservationOpeningCheck.read(observingOnly:true,pause:{throw CancellationError()}) {
   attempts += 1; throw ManagedPreservationError.unavailable
  }; fatalError("cancel must stop") } catch is CancellationError {}
  precondition(attempts == 1)
  print("PASS opening: first failure hidden, second reported, identity/cancellation preserved")
 }
}
