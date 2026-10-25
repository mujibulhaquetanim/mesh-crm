import { computed } from 'vue';
import { flushPromises, mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import CollaboratorsPage from 'dashboard/routes/dashboard/settings/inbox/settingsPage/CollaboratorsPage.vue';
import { showsAssignmentPlanGuidance } from '../assignmentUpsell';

const mocks = vi.hoisted(() => ({
  isOnChatwootCloud: false,
  isEnterprise: false,
  enterprisePlanName: 'community',
}));

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '1' } }),
  useRouter: () => ({ push: vi.fn() }),
}));
vi.mock('vuex', () => ({
  useStore: () => ({
    getters: {
      'agents/getAgents': [],
      // assignment_v2 is on by default (config/features.yml);
      // advanced_assignment is enterprise-only and off.
      'accounts/isFeatureEnabledonAccount': (_id, feature) =>
        feature === 'assignment_v2',
    },
    dispatch: vi.fn(() => Promise.resolve({ data: { payload: [] } })),
  }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/useConfig', () => ({
  useConfig: () => ({
    isEnterprise: mocks.isEnterprise,
    enterprisePlanName: mocks.enterprisePlanName,
  }),
}));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    isOnChatwootCloud: computed(() => mocks.isOnChatwootCloud),
  }),
}));
vi.mock('dashboard/api/assignmentPolicies', () => ({
  default: {
    get: vi.fn(() => Promise.resolve({ data: [] })),
    getInboxPolicy: vi.fn(() => Promise.resolve({ data: null })),
  },
}));

const SlotStub = { template: '<div><slot /><slot name="extra" /></div>' };
const ToggleStub = { template: '<div><slot name="editor" /></div>' };
const ButtonStub = {
  props: ['label'],
  template: '<button class="next-button">{{ label }}</button>',
};

const renderAssignmentCard = async () => {
  const wrapper = mount(CollaboratorsPage, {
    props: { inbox: { id: 7, enable_auto_assignment: true } },
    global: {
      mocks: { $t: key => key },
      stubs: {
        SettingsFieldSection: SlotStub,
        SettingsAccordion: SlotStub,
        SettingsToggleSection: ToggleStub,
        NextButton: ButtonStub,
        TagInput: true,
        DropdownMenu: true,
        Icon: true,
        'woot-input': true,
      },
    },
  });
  await flushPromises();
  return wrapper.text();
};

describe('Inbox collaborators assignment card (fork: plan upsell)', () => {
  beforeEach(() => {
    mocks.isOnChatwootCloud = false;
    mocks.isEnterprise = false;
    mocks.enterprisePlanName = 'community';
  });

  it('shows the default rules without a Premium upsell on the community build', async () => {
    const text = await renderAssignmentCard();

    expect(text).toContain('INBOX_MGMT.ASSIGNMENT.DEFAULT_RULES_TITLE');
    expect(text).not.toContain('INBOX_MGMT.ASSIGNMENT.SELF_HOSTED_PROMPT');
    expect(text).not.toContain('INBOX_MGMT.ASSIGNMENT.UPGRADE_TO_PREMIUM');
  });

  it('keeps upstream behaviour on Chatwoot Cloud', async () => {
    mocks.isOnChatwootCloud = true;

    const text = await renderAssignmentCard();

    expect(text).toContain('INBOX_MGMT.ASSIGNMENT.UPGRADE_PROMPT');
    expect(text).toContain('INBOX_MGMT.ASSIGNMENT.UPGRADE_TO_BUSINESS');
  });

  it('keeps upstream behaviour on a licensed self-hosted install', async () => {
    mocks.isEnterprise = true;
    mocks.enterprisePlanName = 'enterprise';

    const text = await renderAssignmentCard();

    expect(text).toContain('INBOX_MGMT.ASSIGNMENT.FEATURE_DISABLED_PROMPT');
  });
});

describe('showsAssignmentPlanGuidance', () => {
  it('is false only on an unlicensed self-hosted install', () => {
    expect(
      showsAssignmentPlanGuidance({
        isOnChatwootCloud: false,
        isLicensedSelfHosted: false,
      })
    ).toBe(false);
    expect(
      showsAssignmentPlanGuidance({
        isOnChatwootCloud: true,
        isLicensedSelfHosted: false,
      })
    ).toBe(true);
    expect(
      showsAssignmentPlanGuidance({
        isOnChatwootCloud: false,
        isLicensedSelfHosted: true,
      })
    ).toBe(true);
  });
});
