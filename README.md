# Visual Graphs

Visual Graphs is a Salesforce DX project containing focused Lightning Web Components for narrative analytics and record-access visibility.

## What Is Included

- `recordAccessInspector`: record-access analysis for admins, including dense compact mode
- `opportunityJourney`: timeline-style opportunity narrative

## Components

### 1) Record Access Inspector

Record Access Inspector shows who has access to a specific record and why, across supported sharing and permission paths.

Key capabilities:
- Read / Write / Delete toggle
- Access path reasoning (owner, OWD, profile/permission set, share-derived paths)
- Deep links in access paths for Profile and Permission Set sources (when available)
- User profile link on each user card
- Search, pagination, and page-size controls
- User scope filtering: All / Internal / External
- Compact admin layout designed for tight Lightning page regions
- Dense tabular view so admins can scan many users without large cards consuming space
- Grouped access-path summaries in compact mode instead of full-width path chips on every row
- Expandable full-width detail row in compact mode so path details open only when needed
- Inline badges and tooltips for compressed labels and grouped path categories

- LWC: `recordAccessInspector`
- Apex: `RecordAccessInspectorController`
- Test: `RecordAccessInspectorControllerTest`

#### Demo Video Placeholder

- `TODO: Add Record Access Inspector demo video link`
- `Placeholder: <RECORD_ACCESS_INSPECTOR_VIDEO_URL>`

---

### 2) Opportunity Journey

Opportunity Journey renders a timeline-style narrative of an Opportunity, including:
- Record creation context and key metadata
- Stage updates
- Field updates grouped by change moment
- Email conversation highlights
- Deal health, momentum, stakeholders, and open items

- LWC: `opportunityJourney`
- Apex: `OpportunityJourneyController`

#### Screenshot

> <img width="1450" height="1993" alt="Opportunity Journey" src="https://github.com/user-attachments/assets/978bc520-878d-49a1-9edf-e00d95324d3c" />

#### Demo Video Placeholder

https://github.com/user-attachments/assets/188b5549-72d6-4ec5-9806-294c6f98b7f4

---

## Deployment

### Deploy all Visual Graphs components in this repo

```bash
sf project deploy start \
  --source-dir force-app/main/default/classes/OpportunityJourneyController.cls \
  --source-dir force-app/main/default/lwc/opportunityJourney \
  --source-dir force-app/main/default/classes/RecordAccessInspectorController.cls \
  --source-dir force-app/main/default/classes/RecordAccessInspectorControllerTest.cls \
  --source-dir force-app/main/default/lwc/recordAccessInspector
```

### Optional: Run targeted test for Record Access Inspector

```bash
sf apex run test --tests RecordAccessInspectorControllerTest --result-format human --wait 20
```

## Notes

- Opportunity stage timeline depends on Opportunity history tracking for `StageName`.
- Email highlights depend on available `EmailMessage` data.
- Some objects (for example, `ControlledByParent`) may not expose a standalone share object; the UI handles this and labels it accordingly.

## License

This project is licensed under the MIT License. See `LICENSE`.
