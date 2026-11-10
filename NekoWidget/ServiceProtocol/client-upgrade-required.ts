export interface ClientUpgradePolicy {
  CLIENT_UPGRADE_REQUIRED_ENABLED?: string;
  MINIMUM_SUPPORTED_IOS_BUILD?: string;
}

// OFF unless explicitly enabled in a later operational change. The build hint
// is not authentication and never grants access. Requests without the iOS hint
// (Apple notifications, service calls, health checks) retain their own protocol.
export function clientUpgradeResponse(request: Request, policy: ClientUpgradePolicy): Response | null {
  if (policy.CLIENT_UPGRADE_REQUIRED_ENABLED !== 'YES') return null;
  const minimum = policy.MINIMUM_SUPPORTED_IOS_BUILD;
  const build = request.headers.get('X-Neko-App-Build');
  if (!minimum || !/^[1-9][0-9]{0,8}$/.test(minimum)
      || !build || !/^[0-9]{1,9}$/.test(build) || Number(build) >= Number(minimum)) return null;
  return Response.json({ error: { code: 'CLIENT_UPGRADE_REQUIRED' } }, {
    status: 426, headers: { 'Cache-Control': 'no-store' }
  });
}
