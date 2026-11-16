import { nextTick, ref } from 'vue';
import { beforeEach, describe, expect, it } from 'vitest';
import { tabTitleFor, useAccountTabTitle } from '../tabTitle';

describe('tabTitleFor', () => {
  it('uses the account name', () => {
    expect(tabTitleFor('Ezvella', 'Inbox')).toBe('Ezvella');
    expect(tabTitleFor('রিনার কালেকশন', 'Inbox')).toBe('রিনার কালেকশন');
  });

  it('falls back when there is no usable name', () => {
    expect(tabTitleFor(undefined, 'Inbox')).toBe('Inbox');
    expect(tabTitleFor(null, 'Inbox')).toBe('Inbox');
    expect(tabTitleFor('  \n ', 'Inbox')).toBe('Inbox');
    expect(tabTitleFor(42, 'Inbox')).toBe('Inbox');
  });

  it('strips line breaks and shortens a very long name', () => {
    expect(tabTitleFor(" Rina's\nCollection ", 'Inbox')).toBe(
      "Rina's Collection"
    );
    expect(tabTitleFor(`${'a'.repeat(59)}😀😀`, 'Inbox')).toBe(
      `${'a'.repeat(59)}😀…`
    );
  });
});

describe('useAccountTabTitle', () => {
  beforeEach(() => {
    document.title = 'Inbox';
  });

  it('keeps the installation name until the account has loaded, then names the account', async () => {
    const account = ref(undefined);
    useAccountTabTitle(account);
    expect(document.title).toBe('Inbox');

    account.value = { name: 'Ezvella' };
    await nextTick();
    expect(document.title).toBe('Ezvella');
  });

  it('follows a switch to another account, and back to the installation name', async () => {
    const account = ref({ name: 'Ezvella' });
    useAccountTabTitle(account);
    expect(document.title).toBe('Ezvella');

    account.value = { name: 'Parmun' };
    await nextTick();
    expect(document.title).toBe('Parmun');

    account.value = undefined;
    await nextTick();
    expect(document.title).toBe('Inbox');
  });
});
