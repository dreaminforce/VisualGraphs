# Visual Graphs

Visual Graphs is a growing package of professional, polished Salesforce visualizations built as Lightning Web Components (LWC), with or without AI assistance. The goal is to deliver reusable, production-quality UI patterns that make Salesforce data feel modern, clear, and story-driven.

## Module 1: Opportunity Journey

Opportunity Journey is the first module in the Visual Graphs collection. It renders a timeline-style narrative of an Opportunity, including:
- Record creation context and key metadata
- Stage updates
- Field updates (grouped by change moment)
- Email conversation highlights
- Deal health, momentum, stakeholders, and open items

## Screenshot

> <img width="1450" height="1993" alt="image" src="https://github.com/user-attachments/assets/978bc520-878d-49a1-9edf-e00d95324d3c" />


## Components

- LWC: `opportunityJourney`
- Apex: `OpportunityJourneyController`

## Deployment (SFDX)

Use the package manifest to deploy just the Visual Graphs components:

```bash
sf project deploy start -x manifest/package.xml
```

## Notes

- Stage history relies on Opportunity history tracking for StageName.
- Email highlights require EmailMessage data to be present.
