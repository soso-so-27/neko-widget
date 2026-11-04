// Dedicated private entrypoint for production preservation observations.
// The public sharing Worker and the owner-only Sandbox gateway are unchanged.
export { RetentionBillingObserver } from '../../SharingService/src/billing-gateway';
export default { fetch: () => new Response(null, { status: 404 }) };
