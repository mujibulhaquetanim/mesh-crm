// Zasmate fork.
//
// Inbox settings -> Collaborators shows a "Default rules" card when the account
// lacks `advanced_assignment` (custom assignment policies). Upstream ends that
// card with plan guidance: Chatwoot Cloud links to its billing page, and a
// self-hosted install without a licence gets "Upgrade to Premium", which opens
// chatwoot.com's self-hosted pricing in a new tab.
//
// advanced_assignment is implemented only in enterprise/, which the production
// image does not ship (MIT_ONLY), so on this build there is nothing to buy and
// the guidance would only send a vendor to Chatwoot's sales page. It keeps
// upstream's behaviour on Chatwoot Cloud and on a licensed self-hosted install.
export const showsAssignmentPlanGuidance = ({
  isOnChatwootCloud,
  isLicensedSelfHosted,
}) => isOnChatwootCloud || isLicensedSelfHosted;
