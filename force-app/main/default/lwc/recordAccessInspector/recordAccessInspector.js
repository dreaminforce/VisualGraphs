import { LightningElement, api, wire } from 'lwc';
import getRecordAccess from '@salesforce/apex/RecordAccessInspectorController.getRecordAccess';

const ACCESS_MODES = [
  { value: 'read', label: 'Read' },
  { value: 'edit', label: 'Write' },
  { value: 'delete', label: 'Delete' }
];
const USER_SCOPE_MODES = [
  { value: 'all', label: 'All', title: 'Show all users' },
  { value: 'internal', label: 'Internal', title: 'Show internal users only' },
  { value: 'external', label: 'External', title: 'Show external users only' }
];
const PAGE_SIZE_OPTIONS = [10, 25, 50, 100];
const PATH_GROUP_CONFIG = [
  { key: 'owner', label: 'Ownership', shortLabel: 'O' },
  { key: 'object', label: 'Object Grants', shortLabel: 'P' },
  { key: 'owd', label: 'OWD', shortLabel: 'W' },
  { key: 'direct', label: 'Direct Shares', shortLabel: 'D' },
  { key: 'group', label: 'Group Shares', shortLabel: 'G' },
  { key: 'implicit', label: 'Implicit', shortLabel: 'I' },
  { key: 'other', label: 'Other', shortLabel: '?' }
];

const EMPTY_RESPONSE = {
  objectApiName: '',
  objectLabel: '',
  selectedAccessType: 'read',
  internalSharingModel: '',
  externalSharingModel: '',
  shareObjectApiName: '',
  shareObjectAvailable: false,
  totalActiveUsers: 0,
  scannedUsers: 0,
  usersWithAccess: 0,
  directShareCount: 0,
  groupShareCount: 0,
  notes: [],
  users: []
};

export default class RecordAccessInspector extends LightningElement {
  @api recordId;
  @api objectApiName;
  @api compactLayout = false;
  @api compactSize = 'normal';

  selectedMode = 'read';
  selectedUserScope = 'all';
  searchTerm = '';
  pageSize = 25;
  currentPage = 1;
  expandedContextUserIds = [];
  expandedUserId;
  expandedPathGroupKey;
  isLoading = true;
  errorMessage;
  response = { ...EMPTY_RESPONSE };

  @wire(getRecordAccess, { recordId: '$recordId', accessType: '$selectedMode' })
  wiredRecordAccess({ data, error }) {
    if (!this.recordId) {
      this.isLoading = false;
      this.errorMessage = undefined;
      this.resetExpandedState();
      this.response = { ...EMPTY_RESPONSE };
      return;
    }

    if (data) {
      this.response = {
        ...EMPTY_RESPONSE,
        ...data,
        notes: Array.isArray(data.notes) ? data.notes : [],
        users: Array.isArray(data.users) ? data.users : []
      };
      this.errorMessage = undefined;
      this.isLoading = false;
      this.currentPage = 1;
      this.resetExpandedState();
      return;
    }

    if (error) {
      this.resetExpandedState();
      this.response = { ...EMPTY_RESPONSE };
      this.errorMessage = reduceErrors(error).join(', ');
      this.isLoading = false;
      this.currentPage = 1;
    }
  }

  handleModeChange(event) {
    const mode = event.currentTarget.dataset.mode;
    if (!mode || mode === this.selectedMode) {
      return;
    }

    this.isLoading = true;
    this.selectedMode = mode;
    this.currentPage = 1;
    this.resetExpandedState();
  }

  handleUserScopeChange(event) {
    const nextScope = event.currentTarget.dataset.scope;
    if (!nextScope || nextScope === this.selectedUserScope) {
      return;
    }
    this.selectedUserScope = nextScope;
    this.currentPage = 1;
    this.resetExpandedState();
  }

  handleSearchInput(event) {
    this.searchTerm = event.target.value || '';
    this.currentPage = 1;
    this.resetExpandedState();
  }

  handlePageSizeChange(event) {
    const nextSize = Number(event.detail?.value || event.target?.value);
    this.pageSize = Number.isNaN(nextSize) ? 25 : nextSize;
    this.currentPage = 1;
    this.resetExpandedState();
  }

  handlePreviousPage() {
    if (!this.canGoPrevious) {
      return;
    }
    this.currentPage -= 1;
    this.resetExpandedState();
  }

  handleNextPage() {
    if (!this.canGoNext) {
      return;
    }
    this.currentPage += 1;
    this.resetExpandedState();
  }

  handleContextDetailToggle(event) {
    const userId = event.currentTarget.dataset.userId;
    if (!userId) {
      return;
    }

    if (this.expandedContextUserIds.includes(userId)) {
      this.expandedContextUserIds = this.expandedContextUserIds.filter((value) => value !== userId);
      return;
    }

    this.expandedContextUserIds = [...this.expandedContextUserIds, userId];
  }

  handlePathDetailToggle(event) {
    const userId = event.currentTarget.dataset.userId;
    if (!userId) {
      return;
    }

    if (this.expandedUserId === userId) {
      this.expandedUserId = undefined;
      this.expandedPathGroupKey = undefined;
      return;
    }

    this.expandedUserId = userId;
    this.expandedPathGroupKey = undefined;
  }

  handlePathSummaryClick(event) {
    const userId = event.currentTarget.dataset.userId;
    const groupKey = event.currentTarget.dataset.groupKey;

    if (!userId || !groupKey) {
      return;
    }

    if (this.expandedUserId === userId && this.expandedPathGroupKey === groupKey) {
      this.expandedPathGroupKey = undefined;
      return;
    }

    this.expandedUserId = userId;
    this.expandedPathGroupKey = groupKey;
  }

  handleShowAllPathGroups(event) {
    const userId = event.currentTarget.dataset.userId;
    if (!userId) {
      return;
    }

    this.expandedUserId = userId;
    this.expandedPathGroupKey = undefined;
  }

  resetExpandedState() {
    this.expandedContextUserIds = [];
    this.expandedUserId = undefined;
    this.expandedPathGroupKey = undefined;
  }

  get modeButtons() {
    return ACCESS_MODES.map((mode) => {
      const isSelected = mode.value === this.selectedMode;
      return {
        ...mode,
        title: `Show users with ${mode.label.toLowerCase()} access`,
        className: `mode-button${isSelected ? ' mode-button--active' : ''}`
      };
    });
  }

  get userScopeButtons() {
    return USER_SCOPE_MODES.map((scope) => ({
      ...scope,
      className: `scope-button${scope.value === this.selectedUserScope ? ' scope-button--active' : ''}`
    }));
  }

  get compactStats() {
    return [
      {
        key: 'matched',
        label: 'Match',
        value: this.response.usersWithAccess,
        title: 'Users matched'
      },
      {
        key: 'scanned',
        label: 'Scan',
        value: this.response.scannedUsers,
        title: 'Users scanned'
      },
      {
        key: 'direct',
        label: 'Dir',
        value: this.response.directShareCount,
        title: 'Direct shares'
      },
      {
        key: 'group',
        label: 'Grp',
        value: this.response.groupShareCount,
        title: 'Group shares'
      },
      {
        key: 'internalOwd',
        label: 'Int',
        value: this.response.internalSharingModel,
        title: 'Internal OWD'
      },
      {
        key: 'externalOwd',
        label: 'Ext',
        value: this.response.externalSharingModel,
        title: 'External OWD'
      },
      {
        key: 'shareObject',
        label: 'Share',
        value: this.shareObjectDisplayLabel,
        title: 'Share object'
      }
    ];
  }

  get accessModeLabel() {
    if (this.selectedMode === 'edit') {
      return 'Write';
    }
    if (this.selectedMode === 'delete') {
      return 'Delete';
    }
    return 'Read';
  }

  get hasRecordContext() {
    return Boolean(this.recordId);
  }

  get isSmallCompactLayout() {
    return this.compactSize === 'small';
  }

  get shellClassName() {
    return `access-shell access-shell--compact${this.isSmallCompactLayout ? ' access-shell--compact-small' : ''}`;
  }

  get showMainContent() {
    return this.hasRecordContext && !this.isLoading && !this.errorMessage;
  }

  get hasUsers() {
    return Array.isArray(this.response.users) && this.response.users.length > 0;
  }

  get users() {
    if (!this.hasUsers) {
      return [];
    }

    return this.response.users.map((userRow) => {
      const userName = userRow.userName || 'Unknown User';
      const accessPaths = normalizeAccessPaths(userRow);
      const pathGroups = buildPathGroups(userRow.userId, accessPaths);
      const isExpanded = userRow.userId === this.expandedUserId;
      const isContextExpanded = this.expandedContextUserIds.includes(userRow.userId);
      const activePathGroupKey = isExpanded ? this.expandedPathGroupKey : undefined;

      return {
        ...userRow,
        isExternal: inferIsExternal(userRow),
        accessPaths,
        isContextExpanded,
        isExpanded,
        hasActivePathGroup: Boolean(activePathGroupKey),
        detailRowKey: `${userRow.userId}-details`,
        pathToggleLabel: isExpanded ? 'Hide' : 'More',
        pathToggleIcon: isExpanded ? 'utility:chevrondown' : 'utility:chevronright',
        pathToggleTitle: `${isExpanded ? 'Hide' : 'Show'} access path details`,
        contextToggleIcon: isContextExpanded ? 'utility:chevrondown' : 'utility:chevronright',
        contextToggleTitle: `${isContextExpanded ? 'Hide' : 'Show'} access context`,
        visiblePathGroups: buildVisiblePathGroups(pathGroups, activePathGroupKey),
        pathSummaryBadges: pathGroups.map((group) => ({
          key: `${userRow.userId}-${group.groupKey}`,
          groupKey: group.groupKey,
          shortLabel: group.shortLabel,
          count: group.count,
          title: `${group.label}: ${group.count}`,
          className: `path-summary-badge path-summary-badge--${group.groupKey}${
            isExpanded && activePathGroupKey === group.groupKey ? ' path-summary-badge--active' : ''
          }`
        })),
        profileUrl: userRow.profileId
          ? `/lightning/setup/EnhancedProfiles/page?address=%2F${userRow.profileId}`
          : null,
        permissionBadges: [
          {
            key: `${userRow.userId}-read`,
            label: 'R',
            title: 'Read',
            className: `perm-badge${userRow.hasRead ? ' perm-badge--on' : ''}`
          },
          {
            key: `${userRow.userId}-write`,
            label: 'W',
            title: 'Write',
            className: `perm-badge${userRow.hasEdit ? ' perm-badge--on' : ''}`
          },
          {
            key: `${userRow.userId}-delete`,
            label: 'D',
            title: 'Delete',
            className: `perm-badge${userRow.hasDelete ? ' perm-badge--on perm-badge--danger' : ''}`
          }
        ]
      };
    });
  }

  get notes() {
    return Array.isArray(this.response.notes) ? this.response.notes : [];
  }

  get hasNotes() {
    return this.notes.length > 0;
  }

  get selectedCountLabel() {
    return `${this.response.usersWithAccess || 0} users with ${this.accessModeLabel.toLowerCase()} access`;
  }

  get shareObjectDisplayLabel() {
    if (this.response.shareObjectAvailable && this.response.shareObjectApiName) {
      return this.response.shareObjectApiName;
    }
    return 'Not available';
  }

  get normalizedSearchTerm() {
    return (this.searchTerm || '').trim().toLowerCase();
  }

  get filteredUsers() {
    if (!this.hasUsers) {
      return [];
    }

    const byScope = this.users.filter((userRow) => {
      if (this.selectedUserScope === 'internal') {
        return !userRow.isExternal;
      }
      if (this.selectedUserScope === 'external') {
        return userRow.isExternal;
      }
      return true;
    });

    const needle = this.normalizedSearchTerm;
    if (!needle) {
      return byScope;
    }

    return byScope.filter((userRow) => {
      const haystack = [
        userRow.userName,
        userRow.loginName,
        userRow.profileName,
        userRow.roleName,
        userRow.userType,
        userRow.maxAccessLevel,
        ...(Array.isArray(userRow.accessPaths) ? userRow.accessPaths.map((path) => path.label) : [])
      ]
        .filter(Boolean)
        .join(' ')
        .toLowerCase();

      return haystack.includes(needle);
    });
  }

  get totalFilteredUsers() {
    return this.filteredUsers.length;
  }

  get totalPages() {
    return Math.max(1, Math.ceil(this.totalFilteredUsers / this.pageSize));
  }

  get effectivePage() {
    return Math.min(this.currentPage, this.totalPages);
  }

  get pagedUsers() {
    const startIndex = (this.effectivePage - 1) * this.pageSize;
    return this.filteredUsers.slice(startIndex, startIndex + this.pageSize);
  }

  get canGoPrevious() {
    return this.effectivePage > 1;
  }

  get canGoNext() {
    return this.effectivePage < this.totalPages;
  }

  get disablePreviousButton() {
    return !this.canGoPrevious;
  }

  get disableNextButton() {
    return !this.canGoNext;
  }

  get pageSummary() {
    if (!this.totalFilteredUsers) {
      return '0 users';
    }

    const startIndex = (this.effectivePage - 1) * this.pageSize;
    const startNumber = startIndex + 1;
    const endNumber = Math.min(startIndex + this.pageSize, this.totalFilteredUsers);
    return `Showing ${startNumber}-${endNumber} of ${this.totalFilteredUsers} users`;
  }

  get pageSizeOptions() {
    return PAGE_SIZE_OPTIONS.map((size) => ({
      label: `${size} per page`,
      value: String(size)
    }));
  }

  get compactPageSizeOptions() {
    return PAGE_SIZE_OPTIONS.map((size) => ({
      label: `${size}/page`,
      value: String(size)
    }));
  }

  get pageSizeValue() {
    return String(this.pageSize);
  }

  get compactToolbarPageSizeOptions() {
    return this.isSmallCompactLayout ? this.compactPageSizeOptions : this.pageSizeOptions;
  }

  get compactPageSummary() {
    if (!this.totalFilteredUsers) {
      return '0';
    }

    const startIndex = (this.effectivePage - 1) * this.pageSize;
    const startNumber = startIndex + 1;
    const endNumber = Math.min(startIndex + this.pageSize, this.totalFilteredUsers);
    return `${startNumber}-${endNumber} / ${this.totalFilteredUsers}`;
  }

  get compactToolbarPageSummary() {
    return this.isSmallCompactLayout ? this.compactPageSummary : this.pageSummary;
  }

  get showUsersGrid() {
    return this.totalFilteredUsers > 0;
  }

  get showFilterEmptyState() {
    return this.hasUsers && this.totalFilteredUsers === 0;
  }

  get showEmptyState() {
    return !this.isLoading && !this.errorMessage && this.hasRecordContext && !this.hasUsers;
  }
}

function reduceErrors(error) {
  if (!Array.isArray(error?.body)) {
    return [error?.body?.message || error?.message || 'Unknown error'];
  }
  return error.body.map((err) => err.message);
}

function normalizeAccessPaths(userRow) {
  const rawPaths = Array.isArray(userRow?.accessPaths) ? userRow.accessPaths : [];
  return rawPaths
    .map((path, index) => {
      if (typeof path === 'string') {
        return {
          key: `${userRow.userId || 'u'}-path-${index}`,
          label: path,
          url: null
        };
      }

      return {
        key: path?.key || `${userRow.userId || 'u'}-path-${index}`,
        label: path?.label || '',
        url: path?.url || null
      };
    })
    .filter((path) => path.label);
}

function inferIsExternal(userRow) {
  if (typeof userRow?.isExternal === 'boolean') {
    return userRow.isExternal;
  }

  const userType = (userRow?.userType || '').toLowerCase();
  return /portal|customer|partner|guest|community/.test(userType);
}

function buildPathGroups(userId, accessPaths) {
  const groupsByKey = new Map();

  accessPaths.forEach((path) => {
    const config = classifyPathGroup(path?.label);
    if (!groupsByKey.has(config.key)) {
      groupsByKey.set(config.key, {
        key: `${userId || 'u'}-${config.key}`,
        groupKey: config.key,
        label: config.label,
        shortLabel: config.shortLabel,
        count: 0,
        paths: [],
        className: `path-group path-group--${config.key}`
      });
    }

    const group = groupsByKey.get(config.key);
    group.count += 1;
    group.paths.push(path);
  });

  return PATH_GROUP_CONFIG.map((config) => groupsByKey.get(config.key)).filter(Boolean);
}

function buildVisiblePathGroups(pathGroups, activePathGroupKey) {
  if (!activePathGroupKey) {
    return pathGroups;
  }

  const activeGroups = pathGroups.filter((group) => group.groupKey === activePathGroupKey);
  if (!activeGroups.length) {
    return pathGroups;
  }

  return activeGroups;
}

function classifyPathGroup(label) {
  const normalizedLabel = (label || '').toLowerCase();

  if (normalizedLabel.startsWith('record owner')) {
    return PATH_GROUP_CONFIG[0];
  }
  if (
    normalizedLabel.startsWith('object ') ||
    normalizedLabel.startsWith('global record visibility via') ||
    normalizedLabel.startsWith('modify all records via')
  ) {
    return PATH_GROUP_CONFIG[1];
  }
  if (normalizedLabel.startsWith('org-wide default grants')) {
    return PATH_GROUP_CONFIG[2];
  }
  if (normalizedLabel.startsWith('direct share:')) {
    return PATH_GROUP_CONFIG[3];
  }
  if (normalizedLabel.startsWith('group share via')) {
    return PATH_GROUP_CONFIG[4];
  }
  if (normalizedLabel.startsWith('implicit access path')) {
    return PATH_GROUP_CONFIG[5];
  }
  return PATH_GROUP_CONFIG[6];
}
