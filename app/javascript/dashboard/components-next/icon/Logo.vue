<script setup>
import { useAttrs } from 'vue';
import { useMapGetter } from 'dashboard/composables/store';

const attrs = useAttrs();
const globalConfig = useMapGetter('globalConfig/get');
</script>

<template>
  <img
    v-if="globalConfig.logoThumbnail"
    v-bind="attrs"
    :src="globalConfig.logoThumbnail"
  />
  <svg
    v-else
    v-once
    v-bind="attrs"
    width="16"
    height="16"
    viewBox="0 0 16 16"
    fill="none"
    xmlns="http://www.w3.org/2000/svg"
  >
    <!--
      Only rendered when LOGO_THUMBNAIL is unset, which a configured install
      never is — but it used to be Chatwoot's own blue "C" bubble, so an install
      that lost its config fell back to someone else's brand. Drawn rather than
      referenced because a fallback that fetches a file is not a fallback.
    -->
    <circle cx="8" cy="8" r="8" fill="#19A6D3" />
    <path
      d="M5 5.4h6l-6 5.2h6"
      fill="none"
      stroke="white"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
    />
  </svg>
</template>
