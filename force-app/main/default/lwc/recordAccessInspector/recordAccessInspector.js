import { LightningElement, api, wire } from 'lwc';
import getRecordAccess from '@salesforce/apex/RecordAccessInspectorController.getRecordAccess';

const ACCESS_MODES = [
  { value: 'read', label: 'Read' },
  { value: 'edit', label: 'Write' },
  { value: 'delete', label: 'Delete' }
];
const PAGE_SIZE_OPTIONS = [10, 25, 50, 100];

const EMPTY_RESPONSE = {
  objectApiName: '',
  objectLabel: '',
  selectedAccessType: 'read',
  internalSharingModel: '',
  externalSharingModel: '',
  shareObjectApiName: '',
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

  selectedMode = 'read';
  searchTerm = '';
  pageSize = 25;
  currentPage = 1;
  isLoading = true;
  errorMessage;
  response = { ...EMPTY_RESPONSE };

  @wire(getRecordAccess, { recordId: '$recordId', accessType: '$selectedMode' })
  wiredRecordAccess({ data, error }) {
    if (!this.recordId) {
      this.isLoading = false;
      this.errorMessage = undefined;
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
      return;
    }

    if (error) {
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
  }

  handleSearchInput(event) {
    this.searchTerm = event.target.value || '';
    this.currentPage = 1;
  }

  handlePageSizeChange(event) {
    const nextSize = Number(event.detail.value);
    this.pageSize = Number.isNaN(nextSize) ? 25 : nextSize;
    this.currentPage = 1;
  }

  handlePreviousPage() {
    if (!this.canGoPrevious) {
      return;
    }
    this.currentPage -= 1;
  }

  handleNextPage() {
    if (!this.canGoNext) {
      return;
    }
    this.currentPage += 1;
  }

  get modeButtons() {
    return ACCESS_MODES.map((mode) => {
      const isSelected = mode.value === this.selectedMode;
      return {
        ...mode,
        className: `mode-button${isSelected ? ' mode-button--active' : ''}`
      };
    });
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
      return {
        ...userRow,
        initials: buildInitials(userName),
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

  get normalizedSearchTerm() {
    return (this.searchTerm || '').trim().toLowerCase();
  }

  get filteredUsers() {
    if (!this.hasUsers) {
      return [];
    }

    const needle = this.normalizedSearchTerm;
    if (!needle) {
      return this.users;
    }

    return this.users.filter((userRow) => {
      const haystack = [
        userRow.userName,
        userRow.loginName,
        userRow.profileName,
        userRow.roleName,
        userRow.userType,
        userRow.maxAccessLevel,
        ...(Array.isArray(userRow.accessPaths) ? userRow.accessPaths : [])
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

  get pageSizeValue() {
    return String(this.pageSize);
  }

  get permissionSetHomeUrl() {
    return '/lightning/setup/PermSets/home';
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

function buildInitials(name) {
  if (!name) {
    return 'NA';
  }

  const parts = name.trim().split(/\s+/);
  if (parts.length === 1) {
    return parts[0].substring(0, 2).toUpperCase();
  }
  return (parts[0].charAt(0) + parts[parts.length - 1].charAt(0)).toUpperCase();
}

function reduceErrors(error) {
  if (!Array.isArray(error?.body)) {
    return [error?.body?.message || error?.message || 'Unknown error'];
  }
  return error.body.map((err) => err.message);
}
