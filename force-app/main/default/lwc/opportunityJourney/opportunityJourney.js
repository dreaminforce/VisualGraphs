import { LightningElement, api, wire } from 'lwc';
import getJourney from '@salesforce/apex/OpportunityJourneyController.getJourney';

const EVENT_META = {
  creation: { icon: 'utility:new', className: 'event event--creation' },
  stage: { icon: 'utility:strategy', className: 'event event--stage' },
  field: { icon: 'utility:edit', className: 'event event--field' },
  email: { icon: 'utility:email', className: 'event event--email' },
  note: { icon: 'utility:note', className: 'event event--note' }
};

const FALLBACK_RECORD = {
  name: '',
  stage: 'Unknown',
  owner: 'N/A',
  account: 'N/A',
  territory: 'N/A',
  amount: 'N/A',
  closeDate: 'N/A',
  probability: 0,
  health: 'N/A',
  lastActivity: 'N/A',
  nextStep: 'N/A',
  momentum: 'N/A',
  momentumDetail: '',
  stakeholders: 'N/A',
  openItems: 'N/A',
  openItemsDetail: '',
  openItemsDetails: []
};

export default class OpportunityJourney extends LightningElement {
  @api recordId;

  record = { ...FALLBACK_RECORD };
  timeline = [];
  contacts = [];
  products = [];
  errorMessage;
  isLoading = false;

  @wire(getJourney, { recordId: '$recordId' })
  wiredJourney({ data, error }) {
    if (!this.recordId) {
      this.isLoading = false;
      this.record = { ...FALLBACK_RECORD };
      this.timeline = [];
      this.errorMessage = undefined;
      return;
    }

    this.isLoading = true;

    if (data) {
      this.record = { ...FALLBACK_RECORD, ...data.record };
      this.timeline = Array.isArray(data.timeline) ? data.timeline : [];
      this.contacts = Array.isArray(data.contacts) ? data.contacts : [];
      this.products = Array.isArray(data.products) ? data.products : [];
      this.errorMessage = undefined;
      this.isLoading = false;
    } else if (error) {
      this.record = { ...FALLBACK_RECORD };
      this.timeline = [];
      this.contacts = [];
      this.products = [];
      this.errorMessage = reduceErrors(error).join(', ');
      this.isLoading = false;
    }
  }

  get hasRecord() {
    return Boolean(this.record && this.record.name);
  }

  get hasTimeline() {
    return Array.isArray(this.timeline) && this.timeline.length > 0;
  }

  get hasContacts() {
    return Array.isArray(this.contacts) && this.contacts.length > 0;
  }

  get hasProducts() {
    return Array.isArray(this.products) && this.products.length > 0;
  }

  get openItemsParts() {
    if (!this.record) {
      return [];
    }
    if (Array.isArray(this.record.openItemsDetails) && this.record.openItemsDetails.length) {
      return this.record.openItemsDetails.filter((part) => part && part.trim().length);
    }
    if (!this.record.openItemsDetail) {
      return [];
    }
    return this.record.openItemsDetail
      .split(' / ')
      .map((part) => part.trim())
      .filter((part) => part.length);
  }

  get showEmptyState() {
    return !this.isLoading && !this.errorMessage && !this.hasRecord;
  }

  get stagePillClass() {
    const stage = this.record && this.record.stage ? this.record.stage : 'Unknown';
    const slug = stage.toLowerCase().replace(/[^a-z0-9]+/g, '-');
    return `pill pill--${slug}`;
  }

  get events() {
    if (!this.hasTimeline) {
      return [];
    }

    return this.timeline.map((event) => {
      const meta = EVENT_META[event.type] || {};
      return {
        ...event,
        iconName: meta.icon || 'utility:record',
        className: meta.className || 'event',
        isCreation: event.type === 'creation',
        isStage: event.type === 'stage',
        isField: event.type === 'field',
        isEmail: event.type === 'email',
        isNote: event.type === 'note'
      };
    });
  }

  renderedCallback() {
    const probability = this.record && typeof this.record.probability === 'number'
      ? this.record.probability
      : 0;
    const stageBar = this.template.querySelector('.stage-bar');
    if (stageBar) {
      stageBar.style.setProperty('--progress', String(probability / 100));
    }

    const cards = this.template.querySelectorAll('.event');
    cards.forEach((card, index) => {
      card.style.setProperty('--i', String(index));
    });
  }
}

function reduceErrors(error) {
  if (!Array.isArray(error.body)) {
    return [error.body && error.body.message ? error.body.message : error.message];
  }
  return error.body.map((err) => err.message);
}