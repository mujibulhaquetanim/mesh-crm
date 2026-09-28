import { computed } from 'vue';
import { mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ChannelList from 'dashboard/routes/dashboard/settings/inbox/ChannelList.vue';
import {
  CALL_CHANNEL_KEYS,
  withoutUnservedCallChannels,
} from '../callChannels';

const mocks = vi.hoisted(() => ({
  isEnterprise: false,
  isOnChatwootCloud: false,
}));

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('vue-router', () => ({ useRouter: () => ({ push: vi.fn() }) }));
vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => computed(() => ({})),
}));
vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    accountId: computed(() => 1),
    currentAccount: computed(() => ({ features: { channel_voice: true } })),
    isOnChatwootCloud: computed(() => mocks.isOnChatwootCloud),
  }),
}));
vi.mock('dashboard/composables/useConfig', () => ({
  useConfig: () => ({ isEnterprise: mocks.isEnterprise }),
}));

const ChannelItemStub = {
  props: ['channel', 'enabledFeatures'],
  template: '<div class="channel" :data-key="channel.key" />',
};

const renderedKeys = () =>
  mount(ChannelList, {
    global: {
      stubs: {
        ChannelItem: ChannelItemStub,
      },
    },
  })
    .findAll('.channel')
    .map(node => node.attributes('data-key'));

describe('Add inbox channel list (fork: call channels)', () => {
  beforeEach(() => {
    mocks.isEnterprise = false;
    mocks.isOnChatwootCloud = false;
  });

  it('hides Voice and WhatsApp Call on the community build, even with channel_voice on', () => {
    const keys = renderedKeys();

    CALL_CHANNEL_KEYS.forEach(key => expect(keys).not.toContain(key));
    expect(keys).toContain('whatsapp');
    expect(keys).toContain('sms');
  });

  it('shows them where the enterprise backend serves calls', () => {
    mocks.isEnterprise = true;

    expect(renderedKeys()).toEqual(expect.arrayContaining(CALL_CHANNEL_KEYS));
  });

  it('shows them on Chatwoot Cloud', () => {
    mocks.isOnChatwootCloud = true;

    expect(renderedKeys()).toEqual(expect.arrayContaining(CALL_CHANNEL_KEYS));
  });
});

describe('withoutUnservedCallChannels', () => {
  const channels = [
    { key: 'whatsapp' },
    { key: 'voice' },
    { key: 'whatsapp_call' },
  ];

  it('keeps every other channel, in order', () => {
    expect(
      withoutUnservedCallChannels(channels, {
        isOnChatwootCloud: false,
        isEnterprise: false,
      })
    ).toEqual([{ key: 'whatsapp' }]);
  });

  it('returns the list untouched when calls are served', () => {
    expect(
      withoutUnservedCallChannels(channels, {
        isOnChatwootCloud: false,
        isEnterprise: true,
      })
    ).toBe(channels);
  });
});
