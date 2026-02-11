@IsTest
private class RecordAccessInspectorControllerTest {
  @IsTest
  static void getRecordAccess_returnsReadData() {
    Account testAccount = new Account(Name = 'Access Inspector Test');
    insert testAccount;

    Test.startTest();
    RecordAccessInspectorController.AccessResponse response =
      RecordAccessInspectorController.getRecordAccess(testAccount.Id, 'read');
    Test.stopTest();

    System.assertNotEquals(null, response, 'Response should be present.');
    System.assertEquals('Account', response.objectApiName, 'Object API name should be Account.');
    System.assertNotEquals(null, response.users, 'Users list should be initialized.');
    System.assertNotEquals(null, response.notes, 'Notes list should be initialized.');
    System.assert(response.usersWithAccess >= 0, 'Access count should be a non-negative number.');
  }

  @IsTest
  static void getRecordAccess_acceptsWriteAlias() {
    Account testAccount = new Account(Name = 'Write Alias Test');
    insert testAccount;

    Test.startTest();
    RecordAccessInspectorController.AccessResponse response =
      RecordAccessInspectorController.getRecordAccess(testAccount.Id, 'write');
    Test.stopTest();

    System.assertEquals('edit', response.selectedAccessType, 'write should normalize to edit.');
  }

  @IsTest
  static void getRecordAccess_requiresRecordId() {
    Boolean threwException = false;

    try {
      RecordAccessInspectorController.getRecordAccess(null, 'read');
    } catch (Exception ex) {
      threwException = true;
    }

    System.assert(threwException, 'Method should throw AuraHandledException for null record id.');
  }
}
