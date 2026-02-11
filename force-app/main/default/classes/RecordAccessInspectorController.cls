public with sharing class RecordAccessInspectorController {
  private static final Integer MAX_USERS_TO_SCAN = 2000;

  @AuraEnabled(cacheable=true)
  public static AccessResponse getRecordAccess(Id recordId, String accessType) {
    if (recordId == null) {
      throw new AuraHandledException('Missing recordId.');
    }

    AccessResponse response = new AccessResponse();
    response.notes = new List<String>();
    response.users = new List<UserAccessRow>();

    String mode = normalizeAccessType(accessType);
    response.selectedAccessType = mode;

    Schema.DescribeSObjectResult objectDescribe = recordId.getSObjectType().getDescribe();
    String objectApiName = objectDescribe.getName();
    response.objectApiName = objectApiName;
    response.objectLabel = objectDescribe.getLabel();

    SharingModelInfo sharingModelInfo = getSharingModelInfo(objectApiName);
    response.internalSharingModel = sharingModelInfo.internalModel;
    response.externalSharingModel = sharingModelInfo.externalModel;

    response.totalActiveUsers = [
      SELECT count()
      FROM User
      WHERE IsActive = true
    ];

    List<User> scannedUsers = [
      SELECT Id,
        Name,
        Username,
        UserType,
        ProfileId,
        Profile.Name,
        UserRoleId,
        UserRole.Name,
        ManagerId
      FROM User
      WHERE IsActive = true
      ORDER BY Name
      LIMIT :MAX_USERS_TO_SCAN
    ];
    response.scannedUsers = scannedUsers.size();

    if (response.totalActiveUsers > response.scannedUsers) {
      response.notes.add(
        'Scanned the first ' + response.scannedUsers + ' active users out of ' + response.totalActiveUsers +
        '. Add a user filter in a future enhancement for very large orgs.'
      );
    }

    Map<Id, User> usersById = new Map<Id, User>(scannedUsers);
    Map<Id, PermissionSnapshot> permissionByUser = buildPermissionSnapshots(scannedUsers, objectApiName);

    Id ownerId = getOwnerId(recordId, objectApiName, objectDescribe);

    ShareInsights shareInsights = buildShareInsights(
      recordId,
      objectApiName,
      usersById,
      'read',
      response.notes
    );
    response.shareObjectApiName = shareInsights.shareObjectApiName;
    response.directShareCount = shareInsights.directShareCount;
    response.groupShareCount = shareInsights.groupShareCount;

    for (User candidate : scannedUsers) {
      PermissionSnapshot snapshot = permissionByUser.containsKey(candidate.Id)
        ? permissionByUser.get(candidate.Id)
        : new PermissionSnapshot();

      Boolean isOwner = ownerId != null && ownerId == candidate.Id;
      List<String> directReasons = shareInsights.directShareReasonsByUser.get(candidate.Id);
      List<String> groupReasons = shareInsights.groupShareReasonsByUser.get(candidate.Id);
      Boolean hasDirectShare = directReasons != null && !directReasons.isEmpty();
      Boolean hasGroupShare = groupReasons != null && !groupReasons.isEmpty();
      Boolean hasShareReadGrant = hasDirectShare || hasGroupShare;
      Boolean hasShareEditGrant = hasEditShare(directReasons) || hasEditShare(groupReasons);

      Boolean hasRead = evaluateReadAccess(
        snapshot,
        sharingModelInfo.internalModel,
        isOwner,
        hasShareReadGrant
      );
      Boolean hasEdit = evaluateEditAccess(
        snapshot,
        sharingModelInfo.internalModel,
        isOwner,
        hasShareEditGrant
      );
      Boolean hasDelete = evaluateDeleteAccess(snapshot, isOwner);
      if (!matchesSelectedAccess(mode, hasRead, hasEdit, hasDelete)) {
        continue;
      }

      List<String> orderedPaths = buildAccessPaths(
        candidate,
        ownerId,
        sharingModelInfo,
        snapshot,
        shareInsights,
        mode
      );

      if (orderedPaths.isEmpty()) {
        orderedPaths.add('Implicit access path (record hierarchy, enterprise sharing, or system-level grant).');
      }

      UserAccessRow row = new UserAccessRow();
      row.userId = candidate.Id;
      row.userName = candidate.Name;
      row.loginName = candidate.Username;
      row.profileName = candidate.Profile != null ? candidate.Profile.Name : null;
      row.profileId = candidate.ProfileId;
      row.roleName = candidate.UserRole != null ? candidate.UserRole.Name : null;
      row.userType = candidate.UserType;
      row.hasRead = hasRead;
      row.hasEdit = hasEdit;
      row.hasDelete = hasDelete;
      row.maxAccessLevel = deriveMaxAccessLevel(hasRead, hasEdit, hasDelete);
      row.accessPaths = orderedPaths;
      row.pathCount = orderedPaths.size();
      response.users.add(row);
    }

    response.usersWithAccess = response.users.size();
    return response;
  }

  private static String normalizeAccessType(String accessType) {
    String normalized = String.isBlank(accessType)
      ? 'read'
      : accessType.trim().toLowerCase();

    if (normalized == 'write') {
      return 'edit';
    }
    if (normalized == 'edit' || normalized == 'read' || normalized == 'delete') {
      return normalized;
    }
    return 'read';
  }

  private static Boolean matchesSelectedAccess(
    String mode,
    Boolean hasRead,
    Boolean hasEdit,
    Boolean hasDelete
  ) {
    if (mode == 'delete') {
      return hasDelete;
    }
    if (mode == 'edit') {
      return hasEdit;
    }
    return hasRead;
  }

  private static Boolean evaluateReadAccess(
    PermissionSnapshot snapshot,
    String internalSharingModel,
    Boolean isOwner,
    Boolean hasShareReadGrant
  ) {
    Boolean objectReadCapable = snapshot.canRead ||
      snapshot.canEdit ||
      snapshot.canDelete ||
      snapshot.canViewAllRecords ||
      snapshot.canModifyAllRecords;

    if (!objectReadCapable) {
      return false;
    }

    return isOwner ||
      hasShareReadGrant ||
      owdGrantsMode(internalSharingModel, 'read') ||
      snapshot.canViewAllRecords ||
      snapshot.canModifyAllRecords;
  }

  private static Boolean evaluateEditAccess(
    PermissionSnapshot snapshot,
    String internalSharingModel,
    Boolean isOwner,
    Boolean hasShareEditGrant
  ) {
    Boolean objectEditCapable = snapshot.canEdit || snapshot.canModifyAllRecords;
    if (!objectEditCapable) {
      return false;
    }

    return isOwner ||
      hasShareEditGrant ||
      owdGrantsMode(internalSharingModel, 'edit') ||
      snapshot.canModifyAllRecords;
  }

  private static Boolean evaluateDeleteAccess(PermissionSnapshot snapshot, Boolean isOwner) {
    if (snapshot.canModifyAllRecords) {
      return true;
    }
    if (!snapshot.canDelete) {
      return false;
    }
    return isOwner || snapshot.canDelete;
  }

  private static Boolean hasEditShare(List<String> reasons) {
    if (reasons == null || reasons.isEmpty()) {
      return false;
    }

    for (String reason : reasons) {
      if (String.isBlank(reason)) {
        continue;
      }

      String normalized = reason.toLowerCase();
      if (normalized.contains('(edit') ||
          normalized.contains('(all') ||
          normalized.contains('(full') ||
          normalized.contains('readwrite') ||
          normalized.contains('read/write')) {
        return true;
      }
    }
    return false;
  }

  private static String deriveMaxAccessLevel(Boolean hasRead, Boolean hasEdit, Boolean hasDelete) {
    if (hasDelete) {
      return 'Delete';
    }
    if (hasEdit) {
      return 'Edit';
    }
    if (hasRead) {
      return 'Read';
    }
    return 'None';
  }

  private static SharingModelInfo getSharingModelInfo(String objectApiName) {
    SharingModelInfo info = new SharingModelInfo();

    List<EntityDefinition> entityRows = [
      SELECT QualifiedApiName,
        InternalSharingModel,
        ExternalSharingModel
      FROM EntityDefinition
      WHERE QualifiedApiName = :objectApiName
      LIMIT 1
    ];

    if (!entityRows.isEmpty()) {
      EntityDefinition entity = entityRows[0];
      info.internalModel = String.valueOf(entity.InternalSharingModel);
      info.externalModel = String.valueOf(entity.ExternalSharingModel);
    }

    return info;
  }

  private static Id getOwnerId(
    Id recordId,
    String objectApiName,
    Schema.DescribeSObjectResult objectDescribe
  ) {
    if (!objectDescribe.fields.getMap().containsKey('OwnerId')) {
      return null;
    }

    String ownerQuery = 'SELECT OwnerId FROM ' + objectApiName + ' WHERE Id = :recordId LIMIT 1';
    List<SObject> records = Database.query(ownerQuery);
    if (records.isEmpty()) {
      return null;
    }

    return (Id) records[0].get('OwnerId');
  }

  private static Map<Id, PermissionSnapshot> buildPermissionSnapshots(
    List<User> users,
    String objectApiName
  ) {
    Map<Id, PermissionSnapshot> result = new Map<Id, PermissionSnapshot>();
    if (users.isEmpty()) {
      return result;
    }

    Set<Id> userIds = new Set<Id>();
    Set<Id> profileIds = new Set<Id>();
    for (User userRow : users) {
      userIds.add(userRow.Id);
      if (userRow.ProfileId != null) {
        profileIds.add(userRow.ProfileId);
      }
    }

    Map<Id, Set<Id>> assignedPermissionSetsByUser = new Map<Id, Set<Id>>();
    Set<Id> assignedPermissionSetIds = new Set<Id>();

    for (PermissionSetAssignment psa : [
      SELECT AssigneeId,
        PermissionSetId
      FROM PermissionSetAssignment
      WHERE AssigneeId IN :userIds
    ]) {
      if (!assignedPermissionSetsByUser.containsKey(psa.AssigneeId)) {
        assignedPermissionSetsByUser.put(psa.AssigneeId, new Set<Id>());
      }
      assignedPermissionSetsByUser.get(psa.AssigneeId).add(psa.PermissionSetId);
      assignedPermissionSetIds.add(psa.PermissionSetId);
    }

    Map<Id, Id> profilePermissionSetByProfileId = new Map<Id, Id>();
    Map<Id, String> sourceNameByPermissionSetId = new Map<Id, String>();
    Map<Id, String> profileSourceLabelByProfileId = new Map<Id, String>();

    for (User userRow : users) {
      if (userRow.ProfileId == null || profileSourceLabelByProfileId.containsKey(userRow.ProfileId)) {
        continue;
      }

      String profileName = (userRow.Profile != null && !String.isBlank(userRow.Profile.Name))
        ? userRow.Profile.Name
        : 'Unknown Profile';
      profileSourceLabelByProfileId.put(userRow.ProfileId, 'Profile: ' + profileName);
    }

    if (!profileIds.isEmpty()) {
      for (PermissionSet profileSet : [
        SELECT Id,
          ProfileId
        FROM PermissionSet
        WHERE ProfileId IN :profileIds
      ]) {
        profilePermissionSetByProfileId.put(profileSet.ProfileId, profileSet.Id);
        String sourceLabel = profileSourceLabelByProfileId.containsKey(profileSet.ProfileId)
          ? profileSourceLabelByProfileId.get(profileSet.ProfileId)
          : 'Profile: Unknown Profile';
        sourceNameByPermissionSetId.put(profileSet.Id, sourceLabel);
      }
    }

    if (!assignedPermissionSetIds.isEmpty()) {
      for (PermissionSet assignedSet : [
        SELECT Id,
          Label,
          Name,
          ProfileId,
          IsOwnedByProfile
        FROM PermissionSet
        WHERE Id IN :assignedPermissionSetIds
      ]) {
        String label = String.isBlank(assignedSet.Label) ? assignedSet.Name : assignedSet.Label;

        String sourcePrefix = assignedSet.IsOwnedByProfile
          ? 'Profile: '
          : 'Permission Set: ';
        sourceNameByPermissionSetId.put(assignedSet.Id, sourcePrefix + label);
      }
    }

    Set<Id> allPermissionSetIds = new Set<Id>();
    allPermissionSetIds.addAll(profilePermissionSetByProfileId.values());
    allPermissionSetIds.addAll(assignedPermissionSetIds);

    Map<Id, PermissionFlags> flagsByPermissionSetId = new Map<Id, PermissionFlags>();
    if (!allPermissionSetIds.isEmpty()) {
      for (ObjectPermissions objectPerm : [
        SELECT ParentId,
          PermissionsRead,
          PermissionsEdit,
          PermissionsDelete,
          PermissionsViewAllRecords,
          PermissionsModifyAllRecords
        FROM ObjectPermissions
        WHERE SObjectType = :objectApiName
          AND ParentId IN :allPermissionSetIds
      ]) {
        PermissionFlags flags = new PermissionFlags();
        flags.canRead = objectPerm.PermissionsRead;
        flags.canEdit = objectPerm.PermissionsEdit;
        flags.canDelete = objectPerm.PermissionsDelete;
        flags.canViewAll = objectPerm.PermissionsViewAllRecords;
        flags.canModifyAll = objectPerm.PermissionsModifyAllRecords;
        flagsByPermissionSetId.put(objectPerm.ParentId, flags);
      }
    }

    for (User userRow : users) {
      PermissionSnapshot snapshot = new PermissionSnapshot();

      Id profilePermissionSetId = profilePermissionSetByProfileId.get(userRow.ProfileId);
      if (profilePermissionSetId != null && flagsByPermissionSetId.containsKey(profilePermissionSetId)) {
        snapshot.applyFlags(
          flagsByPermissionSetId.get(profilePermissionSetId),
          sourceNameByPermissionSetId.get(profilePermissionSetId)
        );
      }

      if (assignedPermissionSetsByUser.containsKey(userRow.Id)) {
        for (Id assignedPermissionSetId : assignedPermissionSetsByUser.get(userRow.Id)) {
          if (flagsByPermissionSetId.containsKey(assignedPermissionSetId)) {
            snapshot.applyFlags(
              flagsByPermissionSetId.get(assignedPermissionSetId),
              sourceNameByPermissionSetId.get(assignedPermissionSetId)
            );
          }
        }
      }

      result.put(userRow.Id, snapshot);
    }

    return result;
  }

  private static ShareInsights buildShareInsights(
    Id recordId,
    String objectApiName,
    Map<Id, User> usersById,
    String mode,
    List<String> notes
  ) {
    ShareInsights insights = new ShareInsights();
    insights.directShareReasonsByUser = new Map<Id, List<String>>();
    insights.groupShareReasonsByUser = new Map<Id, List<String>>();

    String shareObjectApiName = getShareObjectApiName(objectApiName);
    insights.shareObjectApiName = shareObjectApiName;

    Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
    if (!globalDescribe.containsKey(shareObjectApiName)) {
      notes.add('No share object was found for ' + objectApiName + '.');
      return insights;
    }

    Schema.DescribeSObjectResult shareDescribe = globalDescribe.get(shareObjectApiName).getDescribe();
    Map<String, Schema.SObjectField> shareFields = shareDescribe.fields.getMap();

    String parentFieldName = shareFields.containsKey('ParentId')
      ? 'ParentId'
      : objectApiName + 'Id';
    if (!shareFields.containsKey(parentFieldName)) {
      notes.add('Unable to resolve the parent field on ' + shareObjectApiName + '.');
      return insights;
    }

    String accessLevelFieldName = shareFields.containsKey('AccessLevel')
      ? 'AccessLevel'
      : objectApiName + 'AccessLevel';
    if (!shareFields.containsKey(accessLevelFieldName)) {
      accessLevelFieldName = null;
    }

    String shareQuery =
      'SELECT UserOrGroupId, RowCause' +
      (accessLevelFieldName == null ? '' : ', ' + accessLevelFieldName) +
      ' FROM ' + shareObjectApiName +
      ' WHERE ' + parentFieldName + ' = :recordId';

    List<SObject> shareRows = Database.query(shareQuery);
    if (shareRows.isEmpty()) {
      return insights;
    }

    Map<Id, List<String>> directReasonsByUser = new Map<Id, List<String>>();
    Map<Id, List<String>> groupReasonsByGroup = new Map<Id, List<String>>();
    Set<Id> groupIdsToResolve = new Set<Id>();

    for (SObject shareRow : shareRows) {
      Id targetId = (Id) shareRow.get('UserOrGroupId');
      if (targetId == null) {
        continue;
      }

      String rowCause = String.valueOf(shareRow.get('RowCause'));
      String accessLevel = accessLevelFieldName == null
        ? null
        : String.valueOf(shareRow.get(accessLevelFieldName));

      if (!isShareRelevantForMode(accessLevel, mode)) {
        continue;
      }

      String reasonCore = buildShareReason(rowCause, accessLevel);

      if (isUserId(targetId)) {
        addReason(directReasonsByUser, targetId, 'Direct share: ' + reasonCore);
        insights.directShareCount++;
      } else if (isGroupId(targetId)) {
        addReason(groupReasonsByGroup, targetId, reasonCore);
        groupIdsToResolve.add(targetId);
        insights.groupShareCount++;
      }
    }

    insights.directShareReasonsByUser = directReasonsByUser;

    if (groupIdsToResolve.isEmpty()) {
      return insights;
    }

    GroupResolution groupResolution = resolveGroupMembers(groupIdsToResolve, usersById);

    for (Id groupId : groupReasonsByGroup.keySet()) {
      Set<Id> memberUsers = groupResolution.userIdsByRootGroup.get(groupId);
      if (memberUsers == null || memberUsers.isEmpty()) {
        continue;
      }

      String groupName = groupResolution.groupDisplayNameById.containsKey(groupId)
        ? groupResolution.groupDisplayNameById.get(groupId)
        : String.valueOf(groupId);

      for (Id userId : memberUsers) {
        for (String baseReason : groupReasonsByGroup.get(groupId)) {
          addReason(
            insights.groupShareReasonsByUser,
            userId,
            'Group share via ' + groupName + ': ' + baseReason
          );
        }
      }
    }

    return insights;
  }

  private static GroupResolution resolveGroupMembers(
    Set<Id> rootGroupIds,
    Map<Id, User> usersById
  ) {
    GroupResolution resolution = new GroupResolution();
    resolution.userIdsByRootGroup = new Map<Id, Set<Id>>();
    resolution.groupDisplayNameById = new Map<Id, String>();

    if (rootGroupIds.isEmpty()) {
      return resolution;
    }

    Set<Id> allDiscoveredGroupIds = new Set<Id>();
    allDiscoveredGroupIds.addAll(rootGroupIds);

    Map<Id, Set<Id>> directUsersByGroupId = new Map<Id, Set<Id>>();
    Map<Id, Set<Id>> directRolesByGroupId = new Map<Id, Set<Id>>();
    Map<Id, Set<Id>> childGroupsByGroupId = new Map<Id, Set<Id>>();

    Set<Id> frontier = new Set<Id>();
    frontier.addAll(rootGroupIds);

    while (!frontier.isEmpty()) {
      List<GroupMember> memberRows = [
        SELECT GroupId,
          UserOrGroupId
        FROM GroupMember
        WHERE GroupId IN :frontier
      ];

      Set<Id> nextFrontier = new Set<Id>();
      for (GroupMember memberRow : memberRows) {
        Id groupId = memberRow.GroupId;
        Id memberId = memberRow.UserOrGroupId;
        if (memberId == null) {
          continue;
        }

        if (isUserId(memberId)) {
          addToSetMap(directUsersByGroupId, groupId, memberId);
        } else if (isGroupId(memberId)) {
          addToSetMap(childGroupsByGroupId, groupId, memberId);
          if (!allDiscoveredGroupIds.contains(memberId)) {
            allDiscoveredGroupIds.add(memberId);
            nextFrontier.add(memberId);
          }
        } else if (isRoleId(memberId)) {
          addToSetMap(directRolesByGroupId, groupId, memberId);
        }
      }

      frontier = nextFrontier;
    }

    Map<Id, Group> groupsById = new Map<Id, Group>();
    if (!allDiscoveredGroupIds.isEmpty()) {
      groupsById = new Map<Id, Group>([
        SELECT Id,
          Name,
          Type,
          RelatedId
        FROM Group
        WHERE Id IN :allDiscoveredGroupIds
      ]);
    }

    Map<Id, Set<Id>> userIdsByRoleId = new Map<Id, Set<Id>>();
    Map<Id, Set<Id>> directReportsByManagerId = new Map<Id, Set<Id>>();
    Set<Id> allCandidateUserIds = new Set<Id>();

    for (User userRow : usersById.values()) {
      allCandidateUserIds.add(userRow.Id);

      if (userRow.UserRoleId != null) {
        addToSetMap(userIdsByRoleId, userRow.UserRoleId, userRow.Id);
      }
      if (userRow.ManagerId != null) {
        addToSetMap(directReportsByManagerId, userRow.ManagerId, userRow.Id);
      }
    }

    Set<Id> relatedRoleIds = new Set<Id>();
    for (Group groupRow : groupsById.values()) {
      if (groupRow.RelatedId != null && isRoleId(groupRow.RelatedId)) {
        relatedRoleIds.add(groupRow.RelatedId);
      }
    }

    Map<Id, Set<Id>> descendantRolesByRoot = buildDescendantRoleMap(relatedRoleIds);

    for (Id rootGroupId : rootGroupIds) {
      Set<Id> resolvedUsers = new Set<Id>();
      collectUsersFromGroup(
        rootGroupId,
        groupsById,
        directUsersByGroupId,
        directRolesByGroupId,
        childGroupsByGroupId,
        userIdsByRoleId,
        descendantRolesByRoot,
        directReportsByManagerId,
        allCandidateUserIds,
        resolvedUsers,
        new Set<Id>()
      );
      resolution.userIdsByRootGroup.put(rootGroupId, resolvedUsers);
    }

    for (Id groupId : groupsById.keySet()) {
      Group groupRow = groupsById.get(groupId);
      String label = String.isBlank(groupRow.Name)
        ? String.valueOf(groupId)
        : groupRow.Name;
      resolution.groupDisplayNameById.put(groupId, label + ' (' + groupRow.Type + ')');
    }

    return resolution;
  }

  private static void collectUsersFromGroup(
    Id groupId,
    Map<Id, Group> groupsById,
    Map<Id, Set<Id>> directUsersByGroupId,
    Map<Id, Set<Id>> directRolesByGroupId,
    Map<Id, Set<Id>> childGroupsByGroupId,
    Map<Id, Set<Id>> userIdsByRoleId,
    Map<Id, Set<Id>> descendantRolesByRoot,
    Map<Id, Set<Id>> directReportsByManagerId,
    Set<Id> allCandidateUserIds,
    Set<Id> collector,
    Set<Id> visitedGroups
  ) {
    if (visitedGroups.contains(groupId)) {
      return;
    }
    visitedGroups.add(groupId);

    Group groupRow = groupsById.get(groupId);

    if (groupRow != null) {
      String groupType = String.isBlank(groupRow.Type) ? '' : groupRow.Type;

      if (groupType == 'Organization') {
        collector.addAll(allCandidateUserIds);
      }

      if ((groupType == 'Role' || groupType == 'RoleAndSubordinates' || groupType == 'RoleAndSubordinatesInternal') &&
          groupRow.RelatedId != null &&
          isRoleId(groupRow.RelatedId)) {
        if (userIdsByRoleId.containsKey(groupRow.RelatedId)) {
          collector.addAll(userIdsByRoleId.get(groupRow.RelatedId));
        }

        if (groupType != 'Role' && descendantRolesByRoot.containsKey(groupRow.RelatedId)) {
          for (Id descendantRoleId : descendantRolesByRoot.get(groupRow.RelatedId)) {
            if (userIdsByRoleId.containsKey(descendantRoleId)) {
              collector.addAll(userIdsByRoleId.get(descendantRoleId));
            }
          }
        }
      }

      if ((groupType == 'Manager' || groupType == 'ManagerAndSubordinatesInternal') &&
          groupRow.RelatedId != null &&
          isUserId(groupRow.RelatedId)) {
        if (groupType == 'ManagerAndSubordinatesInternal') {
          collectManagedUsers(
            groupRow.RelatedId,
            directReportsByManagerId,
            collector,
            new Set<Id>()
          );
        } else {
          if (directReportsByManagerId.containsKey(groupRow.RelatedId)) {
            collector.addAll(directReportsByManagerId.get(groupRow.RelatedId));
          }
        }
      }
    }

    if (directUsersByGroupId.containsKey(groupId)) {
      collector.addAll(directUsersByGroupId.get(groupId));
    }

    if (directRolesByGroupId.containsKey(groupId)) {
      for (Id directRoleId : directRolesByGroupId.get(groupId)) {
        if (userIdsByRoleId.containsKey(directRoleId)) {
          collector.addAll(userIdsByRoleId.get(directRoleId));
        }
        if (descendantRolesByRoot.containsKey(directRoleId)) {
          for (Id descendantRoleId : descendantRolesByRoot.get(directRoleId)) {
            if (userIdsByRoleId.containsKey(descendantRoleId)) {
              collector.addAll(userIdsByRoleId.get(descendantRoleId));
            }
          }
        }
      }
    }

    if (childGroupsByGroupId.containsKey(groupId)) {
      for (Id childGroupId : childGroupsByGroupId.get(groupId)) {
        collectUsersFromGroup(
          childGroupId,
          groupsById,
          directUsersByGroupId,
          directRolesByGroupId,
          childGroupsByGroupId,
          userIdsByRoleId,
          descendantRolesByRoot,
          directReportsByManagerId,
          allCandidateUserIds,
          collector,
          visitedGroups
        );
      }
    }
  }

  private static void collectManagedUsers(
    Id managerId,
    Map<Id, Set<Id>> directReportsByManagerId,
    Set<Id> collector,
    Set<Id> visitedUserIds
  ) {
    if (visitedUserIds.contains(managerId)) {
      return;
    }
    visitedUserIds.add(managerId);

    if (!directReportsByManagerId.containsKey(managerId)) {
      return;
    }

    for (Id directReportId : directReportsByManagerId.get(managerId)) {
      collector.add(directReportId);
      collectManagedUsers(
        directReportId,
        directReportsByManagerId,
        collector,
        visitedUserIds
      );
    }
  }

  private static Map<Id, Set<Id>> buildDescendantRoleMap(Set<Id> rootRoleIds) {
    Map<Id, Set<Id>> descendantsByRoot = new Map<Id, Set<Id>>();
    if (rootRoleIds.isEmpty()) {
      return descendantsByRoot;
    }

    List<UserRole> roleRows = [
      SELECT Id,
        ParentRoleId
      FROM UserRole
    ];

    Map<Id, Set<Id>> childRolesByParent = new Map<Id, Set<Id>>();
    for (UserRole roleRow : roleRows) {
      if (roleRow.ParentRoleId != null) {
        addToSetMap(childRolesByParent, roleRow.ParentRoleId, roleRow.Id);
      }
    }

    for (Id rootRoleId : rootRoleIds) {
      Set<Id> descendants = new Set<Id>();
      collectDescendantRoles(rootRoleId, childRolesByParent, descendants);
      descendantsByRoot.put(rootRoleId, descendants);
    }

    return descendantsByRoot;
  }

  private static void collectDescendantRoles(
    Id roleId,
    Map<Id, Set<Id>> childRolesByParent,
    Set<Id> collector
  ) {
    if (!childRolesByParent.containsKey(roleId)) {
      return;
    }

    for (Id childRoleId : childRolesByParent.get(roleId)) {
      if (!collector.contains(childRoleId)) {
        collector.add(childRoleId);
        collectDescendantRoles(childRoleId, childRolesByParent, collector);
      }
    }
  }

  private static List<String> buildAccessPaths(
    User candidate,
    Id ownerId,
    SharingModelInfo sharingModelInfo,
    PermissionSnapshot permissionSnapshot,
    ShareInsights shareInsights,
    String mode
  ) {
    List<String> paths = new List<String>();
    Set<String> seenPaths = new Set<String>();

    if (ownerId != null && ownerId == candidate.Id) {
      addPath(paths, seenPaths, 'Record owner.');
    }

    appendPermissionPaths(paths, seenPaths, permissionSnapshot, mode);

    if (owdGrantsMode(sharingModelInfo.internalModel, mode)) {
      addPath(
        paths,
        seenPaths,
        'Org-wide default grants ' + humanizeAccessMode(mode).toLowerCase() +
        ' (' + friendlySharingModelName(sharingModelInfo.internalModel) + ').'
      );
    }

    if (shareInsights.directShareReasonsByUser.containsKey(candidate.Id)) {
      for (String reason : shareInsights.directShareReasonsByUser.get(candidate.Id)) {
        addPath(paths, seenPaths, reason);
      }
    }

    if (shareInsights.groupShareReasonsByUser.containsKey(candidate.Id)) {
      for (String reason : shareInsights.groupShareReasonsByUser.get(candidate.Id)) {
        addPath(paths, seenPaths, reason);
      }
    }

    return paths;
  }

  private static void appendPermissionPaths(
    List<String> paths,
    Set<String> seenPaths,
    PermissionSnapshot permissionSnapshot,
    String mode
  ) {
    if (mode == 'read') {
      if (!permissionSnapshot.readSources.isEmpty()) {
        addPath(
          paths,
          seenPaths,
          'Object Read permission via ' + summarizeSources(permissionSnapshot.readSources) + '.'
        );
      }
      if (permissionSnapshot.canViewAllRecords || permissionSnapshot.canModifyAllRecords) {
        Set<String> allRecordSources = new Set<String>();
        allRecordSources.addAll(permissionSnapshot.viewAllSources);
        allRecordSources.addAll(permissionSnapshot.modifyAllSources);
        if (!allRecordSources.isEmpty()) {
          addPath(
            paths,
            seenPaths,
            'Global record visibility via ' + summarizeSources(allRecordSources) + '. '
              + '(View All / Modify All Records)'
          );
        }
      }
      return;
    }

    if (mode == 'edit') {
      if (!permissionSnapshot.editSources.isEmpty()) {
        addPath(
          paths,
          seenPaths,
          'Object Edit permission via ' + summarizeSources(permissionSnapshot.editSources) + '.'
        );
      }
      if (permissionSnapshot.canModifyAllRecords && !permissionSnapshot.modifyAllSources.isEmpty()) {
        addPath(
          paths,
          seenPaths,
          'Modify All Records via ' + summarizeSources(permissionSnapshot.modifyAllSources) + '.'
        );
      }
      return;
    }

    if (!permissionSnapshot.deleteSources.isEmpty()) {
      addPath(
        paths,
        seenPaths,
        'Object Delete permission via ' + summarizeSources(permissionSnapshot.deleteSources) + '.'
      );
    }
    if (permissionSnapshot.canModifyAllRecords && !permissionSnapshot.modifyAllSources.isEmpty()) {
      addPath(
        paths,
        seenPaths,
        'Modify All Records via ' + summarizeSources(permissionSnapshot.modifyAllSources) + '.'
      );
    }
  }

  private static String summarizeSources(Set<String> sources) {
    List<String> sortedSources = new List<String>();
    sortedSources.addAll(sources);
    sortedSources.sort();

    Integer maxToShow = 3;
    List<String> shownSources = new List<String>();
    for (Integer index = 0; index < sortedSources.size() && index < maxToShow; index++) {
      shownSources.add(sortedSources[index]);
    }

    String summary = String.join(shownSources, ', ');
    if (sortedSources.size() > maxToShow) {
      summary += ' +' + (sortedSources.size() - maxToShow) + ' more';
    }
    return summary;
  }

  private static Boolean owdGrantsMode(String internalSharingModel, String mode) {
    if (String.isBlank(internalSharingModel) || mode == 'delete') {
      return false;
    }

    String model = internalSharingModel;

    if (mode == 'read') {
      return model == 'Read' ||
        model == 'ReadWrite' ||
        model == 'ReadWriteTransfer' ||
        model == 'FullAccess';
    }

    return model == 'ReadWrite' ||
      model == 'ReadWriteTransfer' ||
      model == 'FullAccess';
  }

  private static String friendlySharingModelName(String sharingModel) {
    if (sharingModel == 'Read') {
      return 'Public Read Only';
    }
    if (sharingModel == 'ReadWrite') {
      return 'Public Read/Write';
    }
    if (sharingModel == 'ReadWriteTransfer') {
      return 'Public Read/Write/Transfer';
    }
    if (sharingModel == 'Private') {
      return 'Private';
    }
    if (sharingModel == 'ControlledByParent') {
      return 'Controlled by Parent';
    }
    return sharingModel;
  }

  private static Boolean isShareRelevantForMode(String accessLevel, String mode) {
    if (mode == 'delete') {
      return false;
    }

    if (String.isBlank(accessLevel)) {
      return true;
    }

    String normalized = accessLevel.trim().toLowerCase();
    if (mode == 'read') {
      return normalized != 'none';
    }

    return normalized == 'edit' ||
      normalized == 'all' ||
      normalized == 'full' ||
      normalized == 'readwrite';
  }

  private static String buildShareReason(String rowCause, String accessLevel) {
    String rowCauseLabel = friendlyRowCause(rowCause);
    if (String.isBlank(accessLevel)) {
      return rowCauseLabel;
    }
    return rowCauseLabel + ' (' + accessLevel + ')';
  }

  private static String friendlyRowCause(String rowCause) {
    if (String.isBlank(rowCause)) {
      return 'Shared';
    }

    String normalized = rowCause.toLowerCase();
    if (normalized == 'owner') {
      return 'Owner-based access';
    }
    if (normalized == 'manual') {
      return 'Manual share';
    }
    if (normalized == 'rule') {
      return 'Sharing rule';
    }
    if (normalized == 'team') {
      return 'Team access';
    }
    if (normalized == 'territory' || normalized == 'territorymanual' || normalized == 'territoryrule') {
      return 'Territory access';
    }
    if (normalized == 'implicitparent') {
      return 'Implicit parent access';
    }
    if (normalized == 'implicitchild') {
      return 'Implicit child access';
    }
    if (normalized == 'apex') {
      return 'Apex managed share';
    }

    return splitCamelCase(rowCause);
  }

  private static String splitCamelCase(String value) {
    if (String.isBlank(value)) {
      return value;
    }

    String output = '';
    for (Integer index = 0; index < value.length(); index++) {
      String current = value.substring(index, index + 1);
      if (index > 0 && current.toUpperCase() == current && current.toLowerCase() != current) {
        output += ' ';
      }
      output += current;
    }
    return output;
  }

  private static String getShareObjectApiName(String objectApiName) {
    if (objectApiName.endsWith('__c')) {
      return objectApiName.substring(0, objectApiName.length() - 3) + '__Share';
    }
    return objectApiName + 'Share';
  }

  private static String humanizeAccessMode(String mode) {
    if (mode == 'edit') {
      return 'Write';
    }
    if (mode == 'delete') {
      return 'Delete';
    }
    return 'Read';
  }

  private static Boolean isUserId(Id recordId) {
    return recordId != null && recordId.getSObjectType() == User.SObjectType;
  }

  private static Boolean isGroupId(Id recordId) {
    return recordId != null && recordId.getSObjectType() == Group.SObjectType;
  }

  private static Boolean isRoleId(Id recordId) {
    return recordId != null && recordId.getSObjectType() == UserRole.SObjectType;
  }

  private static void addPath(List<String> paths, Set<String> seenPaths, String value) {
    if (String.isBlank(value) || seenPaths.contains(value)) {
      return;
    }
    paths.add(value);
    seenPaths.add(value);
  }

  private static void addReason(Map<Id, List<String>> mapById, Id keyId, String reason) {
    if (!mapById.containsKey(keyId)) {
      mapById.put(keyId, new List<String>());
    }

    List<String> reasons = mapById.get(keyId);
    if (!reasons.contains(reason)) {
      reasons.add(reason);
    }
  }

  private static void addToSetMap(Map<Id, Set<Id>> mapById, Id keyId, Id valueId) {
    if (!mapById.containsKey(keyId)) {
      mapById.put(keyId, new Set<Id>());
    }
    mapById.get(keyId).add(valueId);
  }

  public class AccessResponse {
    @AuraEnabled public String objectApiName;
    @AuraEnabled public String objectLabel;
    @AuraEnabled public String selectedAccessType;
    @AuraEnabled public String internalSharingModel;
    @AuraEnabled public String externalSharingModel;
    @AuraEnabled public String shareObjectApiName;
    @AuraEnabled public Integer totalActiveUsers;
    @AuraEnabled public Integer scannedUsers;
    @AuraEnabled public Integer usersWithAccess;
    @AuraEnabled public Integer directShareCount;
    @AuraEnabled public Integer groupShareCount;
    @AuraEnabled public List<String> notes;
    @AuraEnabled public List<UserAccessRow> users;
  }

  public class UserAccessRow {
    @AuraEnabled public Id userId;
    @AuraEnabled public String userName;
    @AuraEnabled public String loginName;
    @AuraEnabled public String profileName;
    @AuraEnabled public Id profileId;
    @AuraEnabled public String roleName;
    @AuraEnabled public String userType;
    @AuraEnabled public Boolean hasRead;
    @AuraEnabled public Boolean hasEdit;
    @AuraEnabled public Boolean hasDelete;
    @AuraEnabled public String maxAccessLevel;
    @AuraEnabled public Integer pathCount;
    @AuraEnabled public List<String> accessPaths;
  }

  private class PermissionFlags {
    public Boolean canRead = false;
    public Boolean canEdit = false;
    public Boolean canDelete = false;
    public Boolean canViewAll = false;
    public Boolean canModifyAll = false;
  }

  private class PermissionSnapshot {
    public Boolean canRead = false;
    public Boolean canEdit = false;
    public Boolean canDelete = false;
    public Boolean canViewAllRecords = false;
    public Boolean canModifyAllRecords = false;

    public Set<String> readSources = new Set<String>();
    public Set<String> editSources = new Set<String>();
    public Set<String> deleteSources = new Set<String>();
    public Set<String> viewAllSources = new Set<String>();
    public Set<String> modifyAllSources = new Set<String>();

    public void applyFlags(PermissionFlags flags, String sourceName) {
      if (flags == null) {
        return;
      }

      if (flags.canRead) {
        canRead = true;
        if (!String.isBlank(sourceName)) {
          readSources.add(sourceName);
        }
      }
      if (flags.canEdit) {
        canEdit = true;
        if (!String.isBlank(sourceName)) {
          editSources.add(sourceName);
        }
      }
      if (flags.canDelete) {
        canDelete = true;
        if (!String.isBlank(sourceName)) {
          deleteSources.add(sourceName);
        }
      }
      if (flags.canViewAll) {
        canViewAllRecords = true;
        if (!String.isBlank(sourceName)) {
          viewAllSources.add(sourceName);
        }
      }
      if (flags.canModifyAll) {
        canModifyAllRecords = true;
        if (!String.isBlank(sourceName)) {
          modifyAllSources.add(sourceName);
        }
      }
    }
  }

  private class SharingModelInfo {
    public String internalModel;
    public String externalModel;
  }

  private class ShareInsights {
    public String shareObjectApiName;
    public Integer directShareCount = 0;
    public Integer groupShareCount = 0;
    public Map<Id, List<String>> directShareReasonsByUser;
    public Map<Id, List<String>> groupShareReasonsByUser;
  }

  private class GroupResolution {
    public Map<Id, Set<Id>> userIdsByRootGroup;
    public Map<Id, String> groupDisplayNameById;
  }
}
