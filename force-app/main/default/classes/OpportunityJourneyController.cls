public with sharing class OpportunityJourneyController {
  @AuraEnabled(cacheable=true)
  public static JourneyResponse getJourney(Id recordId) {
    if (recordId == null) {
      throw new AuraHandledException('Missing recordId.');
    }

    JourneyResponse response = new JourneyResponse();
    Opportunity opp = [
      SELECT Id,
        Name,
        StageName,
        Amount,
        CloseDate,
        Probability,
        Owner.Name,
        Account.Name,
        NextStep,
        LastActivityDate,
        CreatedDate,
        CreatedBy.Name,
        LeadSource,
        Type
      FROM Opportunity
      WHERE Id = :recordId
      LIMIT 1
    ];

    response.record = buildSummary(opp, recordId);

    List<JourneyEvent> events = new List<JourneyEvent>();
    events.add(buildCreationEvent(opp));
    events.addAll(buildStageEvents(recordId));
    events.addAll(buildFieldEvents(recordId));

    JourneyEvent emailEvent = buildEmailEvent(recordId);
    if (emailEvent != null) {
      events.add(emailEvent);
    }

    events.sort(new JourneyEventSorter());
    response.timeline = events;
    response.contacts = buildContactRoles(recordId);
    response.products = buildProductLines(recordId);

    return response;
  }

  private static OpportunitySummary buildSummary(Opportunity opp, Id recordId) {
    OpportunitySummary summary = new OpportunitySummary();
    summary.name = opp.Name;
    summary.stage = opp.StageName;
    summary.owner = opp.Owner != null ? opp.Owner.Name : 'N/A';
    summary.account = opp.Account != null ? opp.Account.Name : 'N/A';
    summary.territory = 'N/A';
    summary.amount = opp.Amount != null ? opp.Amount.format() : 'N/A';
    summary.closeDate = opp.CloseDate != null ? formatDate(opp.CloseDate) : 'N/A';
    summary.probability = opp.Probability != null ? Integer.valueOf(opp.Probability) : 0;
    summary.nextStep = String.isBlank(opp.NextStep) ? 'Add the next step to keep this deal moving.' : opp.NextStep;

    summary.lastActivity = opp.LastActivityDate != null
      ? 'Activity on ' + formatDate(opp.LastActivityDate)
      : 'No recent activity logged';

    summary.health = buildHealth(summary.probability, opp.LastActivityDate);

    ActivitySnapshot activitySnapshot = buildActivitySnapshot(recordId);
    summary.momentum = activitySnapshot.momentumLabel;
    summary.momentumDetail = activitySnapshot.momentumDetail;

    StakeholderSnapshot stakeholderSnapshot = buildStakeholderSnapshot(recordId);
    summary.stakeholders = stakeholderSnapshot.label;

    OpenItemSnapshot openItems = buildOpenItemSnapshot(recordId);
    summary.openItems = openItems.label;
    summary.openItemsDetail = openItems.detail;
    summary.openItemsDetails = openItems.details;

    return summary;
  }

  private static String buildHealth(Integer probability, Date lastActivity) {
    Integer daysSince = lastActivity == null ? 999 : lastActivity.daysBetween(Date.today());
    if (probability >= 70 && daysSince <= 7) {
      return 'Strong';
    }
    if (probability >= 40 && daysSince <= 14) {
      return 'Steady';
    }
    if (probability >= 25) {
      return 'Watch';
    }
    return 'At Risk';
  }

  private static ActivitySnapshot buildActivitySnapshot(Id recordId) {
    DateTime windowStart = System.now().addDays(-14);
    Integer taskCount = [
      SELECT count()
      FROM Task
      WHERE WhatId = :recordId
        AND CreatedDate >= :windowStart
    ];

    Integer eventCount = [
      SELECT count()
      FROM Event
      WHERE WhatId = :recordId
        AND CreatedDate >= :windowStart
    ];

    Integer emailCount = 0;
    if (Schema.getGlobalDescribe().containsKey('EmailMessage')) {
      emailCount = [
        SELECT count()
        FROM EmailMessage
        WHERE RelatedToId = :recordId
          AND MessageDate >= :windowStart
      ];
    }

    Integer total = taskCount + eventCount + emailCount;
    String label;
    if (total >= 8) {
      label = 'High';
    } else if (total >= 3) {
      label = 'Steady';
    } else {
      label = 'Quiet';
    }

    ActivitySnapshot snapshot = new ActivitySnapshot();
    snapshot.momentumLabel = label;
    snapshot.momentumDetail = total + ' activities in the last 14 days';
    return snapshot;
  }

  private static StakeholderSnapshot buildStakeholderSnapshot(Id recordId) {
    Integer roleCount = [
      SELECT count()
      FROM OpportunityContactRole
      WHERE OpportunityId = :recordId
    ];

    List<OpportunityContactRole> roles = [
      SELECT Contact.Name, IsPrimary
      FROM OpportunityContactRole
      WHERE OpportunityId = :recordId
      ORDER BY IsPrimary DESC
      LIMIT 3
    ];

    String primaryName = roles.isEmpty() ? null : roles[0].Contact != null ? roles[0].Contact.Name : null;
    StakeholderSnapshot snapshot = new StakeholderSnapshot();
    snapshot.label = roleCount + ' linked';
    return snapshot;
  }

  private static List<ContactRoleSummary> buildContactRoles(Id recordId) {
    List<ContactRoleSummary> results = new List<ContactRoleSummary>();
    for (OpportunityContactRole role : [
      SELECT Contact.Name, IsPrimary, Role
      FROM OpportunityContactRole
      WHERE OpportunityId = :recordId
      ORDER BY IsPrimary DESC, Contact.Name ASC
      LIMIT 8
    ]) {
      ContactRoleSummary summary = new ContactRoleSummary();
      summary.name = role.Contact != null ? role.Contact.Name : 'Unknown';
      summary.role = role.Role;
      summary.isPrimary = role.IsPrimary;
      results.add(summary);
    }
    return results;
  }

  private static List<ProductSummary> buildProductLines(Id recordId) {
    List<ProductSummary> results = new List<ProductSummary>();
    for (OpportunityLineItem line : [
      SELECT Quantity, UnitPrice, TotalPrice, PricebookEntry.Product2.Name
      FROM OpportunityLineItem
      WHERE OpportunityId = :recordId
      ORDER BY CreatedDate ASC
      LIMIT 10
    ]) {
      ProductSummary summary = new ProductSummary();
      summary.name = line.PricebookEntry != null && line.PricebookEntry.Product2 != null
        ? line.PricebookEntry.Product2.Name
        : 'Product';
      summary.quantity = line.Quantity != null ? line.Quantity : 0;
      summary.unitPrice = line.UnitPrice != null ? line.UnitPrice.format() : 'N/A';
      summary.totalPrice = line.TotalPrice != null ? line.TotalPrice.format() : 'N/A';
      results.add(summary);
    }
    return results;
  }

  private static OpenItemSnapshot buildOpenItemSnapshot(Id recordId) {
    Integer openTasks = [
      SELECT count()
      FROM Task
      WHERE WhatId = :recordId
        AND IsClosed = false
    ];

    Integer upcomingEvents = [
      SELECT count()
      FROM Event
      WHERE WhatId = :recordId
        AND ActivityDate >= :Date.today()
    ];

    List<String> detailParts = new List<String>();
    for (Task task : [
      SELECT Subject, ActivityDate, Priority
      FROM Task
      WHERE WhatId = :recordId
        AND IsClosed = false
      ORDER BY ActivityDate ASC NULLS LAST, CreatedDate DESC
      LIMIT 3
    ]) {
      String subject = String.isBlank(task.Subject) ? 'Task' : task.Subject;
      String detail = 'Task: ' + subject;
      if (task.ActivityDate != null) {
        detail += ' - due ' + formatDate(task.ActivityDate);
      }
      if (!String.isBlank(task.Priority)) {
        detail += ' (' + task.Priority + ')';
      }
      detailParts.add(detail);
    }

    for (Event meeting : [
      SELECT Subject, ActivityDate, StartDateTime, Location
      FROM Event
      WHERE WhatId = :recordId
        AND ActivityDate >= :Date.today()
      ORDER BY ActivityDate ASC, StartDateTime ASC
      LIMIT 3
    ]) {
      String subject = String.isBlank(meeting.Subject) ? 'Meeting' : meeting.Subject;
      String detail = 'Event: ' + subject;
      String whenLabel = meeting.StartDateTime != null
        ? formatDateTime(meeting.StartDateTime)
        : (meeting.ActivityDate != null ? formatDate(meeting.ActivityDate) : '');
      if (!String.isBlank(whenLabel)) {
        detail += ' - ' + whenLabel;
      }
      if (!String.isBlank(meeting.Location)) {
        detail += ' @ ' + meeting.Location;
      }
      detailParts.add(detail);
    }

    Integer total = openTasks + upcomingEvents;
    OpenItemSnapshot snapshot = new OpenItemSnapshot();
    snapshot.label = total + ' open items';
    snapshot.detail = detailParts.isEmpty()
      ? 'No open tasks or upcoming meetings.'
      : String.join(detailParts, ' / ');
    snapshot.details = detailParts;
    return snapshot;
  }

  private static JourneyEvent buildCreationEvent(Opportunity opp) {
    JourneyEvent event = new JourneyEvent();
    event.id = 'created-' + opp.Id;
    event.type = 'creation';
    event.title = 'Opportunity created';
    event.timeLabel = formatDateTime(opp.CreatedDate);
    event.details = 'Created by ' + opp.CreatedBy.Name + ' and assigned to ' + opp.Owner.Name + '.';
    event.actor = opp.CreatedBy != null ? opp.CreatedBy.Name : 'System';
    event.chips = new List<String>();
    if (!String.isBlank(opp.LeadSource)) {
      event.chips.add('Source: ' + opp.LeadSource);
    }
    if (!String.isBlank(opp.Type)) {
      event.chips.add('Type: ' + opp.Type);
    }
    if (opp.Amount != null) {
      event.chips.add('Initial amount: ' + opp.Amount.format());
    }
    event.sortTime = opp.CreatedDate;
    return event;
  }

  private static List<JourneyEvent> buildStageEvents(Id recordId) {
    List<JourneyEvent> events = new List<JourneyEvent>();
    if (!Schema.getGlobalDescribe().containsKey('OpportunityHistory')) {
      return buildStageEventsFromFieldHistory(recordId);
    }

    List<OpportunityHistory> history = [
      SELECT StageName, CreatedDate, Probability, CreatedBy.Name
      FROM OpportunityHistory
      WHERE OpportunityId = :recordId
      ORDER BY CreatedDate ASC
      LIMIT 20
    ];

    String previousStage;
    for (OpportunityHistory entry : history) {
      if (previousStage != null && entry.StageName != previousStage) {
        JourneyEvent event = new JourneyEvent();
        event.id = 'stage-' + String.valueOf(entry.CreatedDate.getTime());
        event.type = 'stage';
        event.title = 'Stage update';
        event.timeLabel = formatDateTime(entry.CreatedDate);
        event.fromStage = previousStage;
        event.toStage = entry.StageName;
        event.probability = entry.Probability != null ? Integer.valueOf(entry.Probability) : 0;
        event.reason = 'Stage updated in pipeline history.';
        event.actor = entry.CreatedBy != null ? entry.CreatedBy.Name : 'System';
        event.sortTime = entry.CreatedDate;
        events.add(event);
      }
      previousStage = entry.StageName;
    }

    if (!events.isEmpty()) {
      return events;
    }
    return buildStageEventsFromFieldHistory(recordId);
  }

  private static List<JourneyEvent> buildStageEventsFromFieldHistory(Id recordId) {
    List<JourneyEvent> events = new List<JourneyEvent>();
    if (!Schema.getGlobalDescribe().containsKey('OpportunityFieldHistory')) {
      return events;
    }

    List<OpportunityFieldHistory> history = [
      SELECT OldValue, NewValue, CreatedDate, CreatedBy.Name
      FROM OpportunityFieldHistory
      WHERE OpportunityId = :recordId
        AND Field = 'StageName'
      ORDER BY CreatedDate ASC
      LIMIT 20
    ];

    for (OpportunityFieldHistory entry : history) {
      String fromStage = entry.OldValue != null ? String.valueOf(entry.OldValue) : 'Unknown';
      String toStage = entry.NewValue != null ? String.valueOf(entry.NewValue) : 'Unknown';
      if (fromStage == toStage) {
        continue;
      }
      JourneyEvent event = new JourneyEvent();
      event.id = 'stage-field-' + String.valueOf(entry.CreatedDate.getTime());
      event.type = 'stage';
      event.title = 'Stage update';
      event.timeLabel = formatDateTime(entry.CreatedDate);
      event.fromStage = fromStage;
      event.toStage = toStage;
      event.probability = 0;
      event.reason = 'Stage updated from field history.';
      event.actor = entry.CreatedBy != null ? entry.CreatedBy.Name : 'System';
      event.sortTime = entry.CreatedDate;
      events.add(event);
    }

    return events;
  }

  private static List<JourneyEvent> buildFieldEvents(Id recordId) {
    List<JourneyEvent> events = new List<JourneyEvent>();
    if (!Schema.getGlobalDescribe().containsKey('OpportunityFieldHistory')) {
      return events;
    }

    Map<String, Schema.SObjectField> fieldMap = Schema.SObjectType.Opportunity.fields.getMap();
    Set<String> ignoredFields = new Set<String>{
      'StageName',
      'CreatedDate',
      'CreatedById',
      'LastModifiedDate',
      'LastModifiedById',
      'SystemModstamp'
    };
    Map<Long, JourneyEvent> grouped = new Map<Long, JourneyEvent>();

    for (OpportunityFieldHistory history : [
      SELECT Field, OldValue, NewValue, CreatedDate, CreatedBy.Name
      FROM OpportunityFieldHistory
      WHERE OpportunityId = :recordId
      ORDER BY CreatedDate DESC
      LIMIT 25
    ]) {
      Long bucket = history.CreatedDate.getTime() / 60000;
      JourneyEvent event = grouped.get(bucket);
      if (event == null) {
        event = new JourneyEvent();
        event.id = 'field-' + String.valueOf(bucket);
        event.type = 'field';
        event.title = 'Fields updated';
        event.timeLabel = formatDateTime(history.CreatedDate);
        event.changes = new List<FieldChange>();
        event.sortTime = history.CreatedDate;
        grouped.put(bucket, event);
      }

      if (ignoredFields.contains(history.Field)) {
        continue;
      }

      FieldChange change = new FieldChange();
      change.field = fieldMap.containsKey(history.Field)
        ? fieldMap.get(history.Field).getDescribe().getLabel()
        : history.Field;
      String fromValue = history.OldValue != null ? String.valueOf(history.OldValue) : '';
      String toValue = history.NewValue != null ? String.valueOf(history.NewValue) : '';
      if (String.isBlank(fromValue) && String.isBlank(toValue)) {
        continue;
      }
      if (fromValue == toValue) {
        continue;
      }
      change.fromValue = String.isBlank(fromValue) ? 'N/A' : fromValue;
      change.toValue = String.isBlank(toValue) ? 'N/A' : toValue;
      event.changes.add(change);
      event.actor = history.CreatedBy != null ? history.CreatedBy.Name : 'System';

      if (history.CreatedDate > event.sortTime) {
        event.sortTime = history.CreatedDate;
      }
    }

    for (JourneyEvent event : grouped.values()) {
      if (event.changes != null && !event.changes.isEmpty()) {
        events.add(event);
      }
    }
    return events;
  }

  private static JourneyEvent buildEmailEvent(Id recordId) {
    if (!Schema.getGlobalDescribe().containsKey('EmailMessage')) {
      return null;
    }

    List<EmailMessage> emails = [
      SELECT Id, FromName, FromAddress, ToAddress, Subject, TextBody, MessageDate, CreatedBy.Name
      FROM EmailMessage
      WHERE RelatedToId = :recordId
      ORDER BY MessageDate DESC
      LIMIT 4
    ];

    if (emails.isEmpty()) {
      return null;
    }

    JourneyEvent event = new JourneyEvent();
    event.id = 'email-' + String.valueOf(emails[0].MessageDate.getTime());
    event.type = 'email';
    event.title = 'Customer email thread';
    event.timeLabel = formatDateTime(emails[0].MessageDate);
    event.subject = String.isBlank(emails[0].Subject) ? 'Email conversation' : emails[0].Subject;
    event.participants = buildParticipants(emails[0]);
    event.actor = !String.isBlank(emails[0].FromName)
      ? emails[0].FromName
      : (emails[0].CreatedBy != null ? emails[0].CreatedBy.Name : 'System');
    event.thread = new List<EmailEntry>();
    event.sortTime = emails[0].MessageDate;

    for (EmailMessage email : emails) {
      EmailEntry entry = new EmailEntry();
      entry.id = email.Id;
      entry.fromName = !String.isBlank(email.FromName) ? email.FromName : email.FromAddress;
      entry.timeLabel = email.MessageDate != null ? email.MessageDate.format('MMM d - h:mm a') : '';
      entry.snippet = truncate(email.TextBody, 140);
      event.thread.add(entry);
    }

    return event;
  }

  private static String buildParticipants(EmailMessage email) {
    List<String> names = new List<String>();
    if (!String.isBlank(email.FromName)) {
      names.add(email.FromName);
    } else if (!String.isBlank(email.FromAddress)) {
      names.add(email.FromAddress);
    }

    if (!String.isBlank(email.ToAddress)) {
      for (String addr : email.ToAddress.split(';')) {
        if (names.size() >= 3) {
          break;
        }
        String trimmed = addr != null ? addr.trim() : null;
        if (!String.isBlank(trimmed)) {
          names.add(trimmed);
        }
      }
    }

    return String.join(names, ', ');
  }

  private static String truncate(String value, Integer maxChars) {
    if (String.isBlank(value)) {
      return 'No email body captured.';
    }
    String trimmed = value.replace('\n', ' ').replace('\r', ' ').trim();
    if (trimmed.length() <= maxChars) {
      return trimmed;
    }
    return trimmed.substring(0, maxChars) + '...';
  }

  private static String formatDate(Date dateValue) {
    return dateValue != null ? dateValue.format() : '';
  }

  private static String formatDateTime(DateTime dateTimeValue) {
    return dateTimeValue != null ? dateTimeValue.format('MMM d, yyyy - h:mm a') : '';
  }

  public class JourneyResponse {
    @AuraEnabled public OpportunitySummary record;
    @AuraEnabled public List<JourneyEvent> timeline;
    @AuraEnabled public List<ContactRoleSummary> contacts;
    @AuraEnabled public List<ProductSummary> products;
  }

  public class OpportunitySummary {
    @AuraEnabled public String name;
    @AuraEnabled public String stage;
    @AuraEnabled public String owner;
    @AuraEnabled public String account;
    @AuraEnabled public String territory;
    @AuraEnabled public String amount;
    @AuraEnabled public String closeDate;
    @AuraEnabled public Integer probability;
    @AuraEnabled public String health;
    @AuraEnabled public String lastActivity;
    @AuraEnabled public String nextStep;
    @AuraEnabled public String momentum;
    @AuraEnabled public String momentumDetail;
    @AuraEnabled public String stakeholders;
    @AuraEnabled public String openItems;
    @AuraEnabled public String openItemsDetail;
    @AuraEnabled public List<String> openItemsDetails;
  }

  public class JourneyEvent {
    @AuraEnabled public String id;
    @AuraEnabled public String type;
    @AuraEnabled public String title;
    @AuraEnabled public String timeLabel;
    @AuraEnabled public String actor;
    @AuraEnabled public String details;
    @AuraEnabled public List<String> chips;
    @AuraEnabled public String fromStage;
    @AuraEnabled public String toStage;
    @AuraEnabled public Integer probability;
    @AuraEnabled public String reason;
    @AuraEnabled public List<FieldChange> changes;
    @AuraEnabled public String subject;
    @AuraEnabled public String participants;
    @AuraEnabled public List<EmailEntry> thread;
    @AuraEnabled public String note;
    @AuraEnabled public String owner;
    public DateTime sortTime;
  }

  public class FieldChange {
    @AuraEnabled public String field;
    @AuraEnabled public String fromValue;
    @AuraEnabled public String toValue;
  }

  public class EmailEntry {
    @AuraEnabled public String id;
    @AuraEnabled public String fromName;
    @AuraEnabled public String timeLabel;
    @AuraEnabled public String snippet;
  }

  public class ContactRoleSummary {
    @AuraEnabled public String name;
    @AuraEnabled public String role;
    @AuraEnabled public Boolean isPrimary;
  }

  public class ProductSummary {
    @AuraEnabled public String name;
    @AuraEnabled public Decimal quantity;
    @AuraEnabled public String unitPrice;
    @AuraEnabled public String totalPrice;
  }

  private class ActivitySnapshot {
    public String momentumLabel;
    public String momentumDetail;
  }

  private class StakeholderSnapshot {
    public String label;
  }

  private class OpenItemSnapshot {
    public String label;
    public String detail;
    public List<String> details;
  }

  private class JourneyEventSorter implements Comparator<JourneyEvent> {
    public Integer compare(JourneyEvent left, JourneyEvent right) {
      if (left == null && right == null) {
        return 0;
      }
      if (left == null) {
        return 1;
      }
      if (right == null) {
        return -1;
      }
      if (left.sortTime == right.sortTime) {
        return 0;
      }
      if (left.sortTime == null) {
        return 1;
      }
      if (right.sortTime == null) {
        return -1;
      }
      return left.sortTime > right.sortTime ? -1 : 1;
    }
  }
}