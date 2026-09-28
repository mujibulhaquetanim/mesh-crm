import { computed } from 'vue';
import { mount } from '@vue/test-utils';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ChannelList from 'dashboard/routes/dashboard/settings/inbox/ChannelList.vue';
import {
  CALL_CHANNEL_KEYS,
  withoutUnservedCallChannels,
} from '../callChannels';

const mocks = vi.hoisted(() => ({
  features: {},
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
    currentAccount: computed(() => ({ features: mocks.features })),
    isOnChatwootCloud: computed(() => mocks.isOnChatwootCloud),
  }),
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
    mocks.features = {};
    mocks.isOnChatwootCloud = false;
  });

  it('hides Voice and WhatsApp Call when the account cannot place calls', () => {
    const keys = renderedKeys();

    CALL_CHANNEL_KEYS.forEach(key => expect(keys).not.toContain(key));
    expect(keys).toContain('whatsapp');
    expect(keys).toContain('sms');
  });

  it('shows them when channel_voice is on (the build serves calls)', () => {
    mocks.features = { channel_voice: true };

    expect(renderedKeys()).toEqual(expect.arrayContaining(CALL_CHANNEL_KEYS));
  });

  it('keeps upstream behaviour on Chatwoot Cloud', () => {
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
        callsEnabled: false,
      })
    ).toEqual([{ key: 'whatsapp' }]);
  });

  it('returns the list untouched when calls are served', () => {
    expect(
      withoutUnservedCallChannels(channels, {
        isOnChatwootCloud: false,
        callsEnabled: true,
      })
    ).toBe(channels);
  });
});
