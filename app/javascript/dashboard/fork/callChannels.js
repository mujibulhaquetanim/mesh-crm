// Zasmate fork (docs/fork/UPSTREAM_DIFF.md §5, docs/fork/VENDOR_FEATURE_POLICY.md).
//
// Voice (Twilio) and WhatsApp calling run entirely on the enterprise-only
// backend: the Call model, the calls API and the Twilio voice webhooks all live
// in enterprise/, and config/routes.rb draws their routes only when
// ChatwootApp.enterprise? is true. The production image is built without
// enterprise/ (docs/fork/MIT_ONLY.md), so those routes don't exist there, but
// upstream's "Add inbox" list pushes both tiles unconditionally. A vendor would
// see a calling channel that can never ring.
//
// Same condition upstream's own Sidebar.vue uses to hide the Calls entry
// (`isCallsAvailable = isOnChatwootCloud || isEnterprise`). On the community
// plan Custom::DashboardController also reports IS_ENTERPRISE=false in trees
// where the folder is present, so development matches production.
export const CALL_CHANNEL_KEYS = ['voice', 'whatsapp_call'];

export const withoutUnservedCallChannels = (
  channels,
  { isOnChatwootCloud, isEnterprise }
) => {
  if (isOnChatwootCloud || isEnterprise) return channels;

  return channels.filter(({ key }) => !CALL_CHANNEL_KEYS.includes(key));
};
