// Zasmate fork (docs/fork/UPSTREAM_DIFF.md §5, docs/fork/VENDOR_FEATURE_POLICY.md).
//
// Voice (Twilio) and WhatsApp calling run entirely on the enterprise-only
// backend: the Call model, the calls API and the Twilio voice webhooks all live
// in enterprise/, and config/routes.rb draws their routes only when that folder
// exists. The production image is built without it (docs/fork/MIT_ONLY.md), but
// upstream's "Add inbox" list pushes both tiles unconditionally, so a vendor saw
// a calling channel that can never ring.
//
// The account's `channel_voice` flag is the one signal for "this workspace can
// place calls": the fork's Custom::Account overlay reads it as off whenever the
// build has no Call model, and the conversation call button and the WhatsApp
// Calls tab already key on it. Upstream shows these tiles as "Coming soon" or
// "Beta" with the flag off; here a tile that can't be clicked isn't shown.
// Chatwoot Cloud keeps upstream's behaviour (its access-request flow).
export const CALL_CHANNEL_KEYS = ['voice', 'whatsapp_call'];

export const withoutUnservedCallChannels = (
  channels,
  { isOnChatwootCloud, callsEnabled }
) => {
  if (isOnChatwootCloud || callsEnabled) return channels;

  return channels.filter(({ key }) => !CALL_CHANNEL_KEYS.includes(key));
};
