<template>
  <Settings :title="$t('secrets.secrets')" :description="$t('secrets.desc')" docs-url="docs/usage/secrets">
    <template #headerActions>
      <Button v-if="selectedSecret" :text="$t('secrets.show')" start-icon="back" @click="selectedSecret = undefined" />
      <Button v-else :text="$t('secrets.add')" start-icon="plus" @click="showAddSecret" />
    </template>

    <!-- Tabbed view when grouping is enabled -->
    <template v-if="groupingEnabled && !selectedSecret">
      <div class="tabs flex space-x-1 border-b border-wp-background-200 mb-4">
        <button
          v-for="groupName in sortedGroupNames"
          :key="groupName"
          class="px-4 py-2 font-medium text-sm transition-colors"
          :class="[
            activeTab === groupName
              ? 'border-b-2 border-wp-primary-500 text-wp-primary-500'
              : 'text-wp-text-alt-100 hover:text-wp-text-100',
          ]"
          @click="activeTab = groupName"
        >
          {{ groupName }}
          <span class="ml-1 text-xs text-wp-text-alt-100">
            {{ `(${getGroupSecretCount(groupName)})` }}
          </span>
        </button>
      </div>

      <SecretList
        :model-value="activeGroupSecrets"
        :is-deleting="isDeleting"
        :loading="loading"
        @edit="editSecret"
        @delete="deleteSecret"
      />
    </template>

    <!-- Flat list view when grouping is disabled -->
    <SecretList
      v-else-if="!selectedSecret"
      :model-value="secrets"
      :is-deleting="isDeleting"
      :loading="loading"
      @edit="editSecret"
      @delete="deleteSecret"
    />

    <SecretEdit
      v-else
      v-model="selectedSecret"
      :is-saving="isSaving"
      @save="createSecret"
      @cancel="selectedSecret = undefined"
    />
  </Settings>
</template>

<script lang="ts" setup>
import { cloneDeep } from 'lodash';
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from '~/components/atomic/Button.vue';
import Settings from '~/components/layout/Settings.vue';
import SecretEdit from '~/components/secrets/SecretEdit.vue';
import SecretList from '~/components/secrets/SecretList.vue';
import useApiClient from '~/compositions/useApiClient';
import { useAsyncAction } from '~/compositions/useAsyncAction';
import { requiredInject } from '~/compositions/useInjectProvide';
import useNotifications from '~/compositions/useNotifications';
import { usePagination } from '~/compositions/usePaginate';
import { useWPTitle } from '~/compositions/useWPTitle';
import { WebhookEvents } from '~/lib/api/types';
import type { Secret } from '~/lib/api/types';

const emptySecret: Partial<Secret> = {
  name: '',
  value: '',
  images: [],
  events: [WebhookEvents.Push],
};

const apiClient = useApiClient();
const notifications = useNotifications();
const i18n = useI18n();

const repo = requiredInject('repo');
const selectedSecret = ref<Partial<Secret>>();
const isEditingSecret = computed(() => !!selectedSecret.value?.id);

// Grouping state
const groupingEnabled = computed(() => repo.value.secret_prefix_grouping_enabled ?? false);
const groupedSecrets = ref<Record<string, Secret[]>>({});
const sortedGroupNames = ref<string[]>([]);
const activeTab = ref<string>('General');

async function loadSecrets(page: number, level: 'repo' | 'org' | 'global'): Promise<Secret[] | null> {
  switch (level) {
    case 'repo':
      return apiClient.getSecretList(repo.value.id, { page });
    case 'org':
      return apiClient.getOrgSecretList(repo.value.org_id, { page });
    case 'global':
      return apiClient.getGlobalSecretList({ page });
    default:
      throw new Error(`Unexpected level: ${level}`);
  }
}

async function loadGroupedSecrets(): Promise<void> {
  if (!groupingEnabled.value) {
    return;
  }

  try {
    const result = await apiClient.getSecretListGrouped(repo.value.id);
    if (result && result.enabled && result.groups) {
      groupedSecrets.value = result.groups;
      sortedGroupNames.value = result.sorted_group_names || [];

      // Set active tab to first group if current tab doesn't exist
      if (sortedGroupNames.value.length > 0 && !sortedGroupNames.value.includes(activeTab.value)) {
        activeTab.value = sortedGroupNames.value[0];
      }
    }
  } catch (error) {
    console.error('Failed to load grouped secrets:', error);
  }
}

const {
  resetPage,
  data: _secrets,
  loading,
} = usePagination(loadSecrets, () => !selectedSecret.value, {
  each: ['repo', 'org', 'global'],
});

// Watch for grouping enabled changes and reload grouped secrets
watch(() => groupingEnabled.value, async (enabled) => {
  if (enabled) {
    await loadGroupedSecrets();
  }
}, { immediate: true });

// Watch for secrets changes and reload grouped view if enabled
watch(() => _secrets.value, async () => {
  if (groupingEnabled.value) {
    await loadGroupedSecrets();
  }
});

const secrets = computed(() => {
  const secretsList: Record<string, Secret & { edit?: boolean; level: 'repo' | 'org' | 'global' }> = {};

  for (const level of ['repo', 'org', 'global']) {
    for (const secret of _secrets.value) {
      if (
        ((level === 'repo' && secret.repo_id !== 0 && secret.org_id === 0) ||
          (level === 'org' && secret.repo_id === 0 && secret.org_id !== 0) ||
          (level === 'global' && secret.repo_id === 0 && secret.org_id === 0)) &&
        !secretsList[secret.name]
      ) {
        secretsList[secret.name] = { ...secret, edit: secret.repo_id !== 0, level };
      }
    }
  }

  const levelsOrder = {
    global: 0,
    org: 1,
    repo: 2,
  };

  return Object.values(secretsList)
    .toSorted((a, b) => a.name.localeCompare(b.name))
    .toSorted((a, b) => levelsOrder[b.level] - levelsOrder[a.level]);
});

const activeGroupSecrets = computed(() => {
  if (!groupingEnabled.value || !activeTab.value) {
    return [];
  }
  return groupedSecrets.value[activeTab.value] || [];
});

function getGroupSecretCount(groupName: string): number {
  return groupedSecrets.value[groupName]?.length || 0;
}

const { doSubmit: createSecret, isLoading: isSaving } = useAsyncAction(async () => {
  if (!selectedSecret.value) {
    throw new Error("Unexpected: Can't get secret");
  }

  if (isEditingSecret.value) {
    await apiClient.updateSecret(repo.value.id, selectedSecret.value);
  } else {
    await apiClient.createSecret(repo.value.id, selectedSecret.value);
  }
  notifications.notify({
    title: isEditingSecret.value ? i18n.t('secrets.saved') : i18n.t('secrets.created'),
    type: 'success',
  });
  selectedSecret.value = undefined;
  await resetPage();
  if (groupingEnabled.value) {
    await loadGroupedSecrets();
  }
});

const { doSubmit: deleteSecret, isLoading: isDeleting } = useAsyncAction(async (_secret: Secret) => {
  await apiClient.deleteSecret(repo.value.id, _secret.name);
  notifications.notify({ title: i18n.t('secrets.deleted'), type: 'success' });
  await resetPage();
  if (groupingEnabled.value) {
    await loadGroupedSecrets();
  }
});

function editSecret(secret: Secret) {
  selectedSecret.value = cloneDeep(secret);
}

function showAddSecret() {
  selectedSecret.value = cloneDeep(emptySecret);
}

useWPTitle(computed(() => [i18n.t('secrets.secrets'), repo.value.full_name]));
</script>
