import { watchEffect } from 'vue';

/**
 * Fork-only: the browser tab names the account (the vendor's shop) instead of
 * the installation.
 *
 * The page is served with `<title>` set to INSTALLATION_NAME, the same word on
 * every tab of every account. A vendor with the inbox and the dashboard open,
 * or an agent who works in two shops, could not tell the tabs apart (owner
 * request 2026-11-16).
 *
 * The installation name stays as the fallback: before the account has loaded,
 * on pages with no account in the URL (login, onboarding), and for an account
 * with a blank name.
 */

const MAX_TAB_TITLE_CHARS = 60;

/** The tab title for an account name, or the fallback when there is none. */
export const tabTitleFor = (accountName, fallback = '') => {
  const name = typeof accountName === 'string' ? accountName : '';
  // Line breaks and control characters have no place on a tab. Direction
  // overrides and isolates (U+202A–202E, U+2066–2069) would show the text
  // reversed; the zero-width joiner Bangla script uses is kept.
  const clean = name
    .replace(/[\u202A-\u202E\u2066-\u2069]/g, '')
    .replace(/\p{Cc}+/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (!clean) return fallback;
  const chars = Array.from(clean);
  return chars.length > MAX_TAB_TITLE_CHARS
    ? `${chars.slice(0, MAX_TAB_TITLE_CHARS).join('').trimEnd()}…`
    : clean;
};

/**
 * Keep `document.title` on the current account's name.
 * @param {import('vue').Ref<{ name?: string } | undefined>} currentAccount
 */
export function useAccountTabTitle(currentAccount) {
  // What the server rendered: the installation name, read once.
  const installationTitle = document.title.trim();
  watchEffect(() => {
    const title = tabTitleFor(currentAccount.value?.name, installationTitle);
    if (title && document.title !== title) document.title = title;
  });
}
