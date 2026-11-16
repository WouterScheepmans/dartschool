// The pages of "Mijn groepen" (`/?module=Profile&file=mygroups`) for a fake
// Smartschool that keeps own mail groups and changes them (#252), built from
// the hand-written fixtures of get/profile/mygroups/: the list of own groups
// in the shape of list.html (from list-empty.html, with a row per group and
// the feedback of an action), and the form of a group in the shape of
// addedit.html. And for a change of the members (#253): the members page of
// a group in the shape of members.html (from members-empty.html, with a row
// per member and the token of its form), the member picker's answer to
// `get Items Selected` in the shape of get-items-selected.xml, its answer to
// `confirm Selection` (confirm-selection.xml), and the selection a
// `confirm Selection` sends. Made-up groups, people and IDs only, with the
// fakes of test/fixtures/lvs/FAKES.md: the members of a real group are
// mostly pupils.
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

/// A made-up own mail group of a fake Smartschool, with its name and
/// description as Smartschool saved them.
class FakeMyGroup {
  FakeMyGroup(this.id, this.name, [this.description = '']);

  final int id;
  String name;
  String description;
}

/// The groups of list.html.
List<FakeMyGroup> myGroupsOfListFixture() => [
  FakeMyGroup(900503, 'Testgroep & "co"', 'Testvak & "meer"'),
  FakeMyGroup(900501, 'Testgroep 5'),
  FakeMyGroup(900502, 'testgroep zorg', 'Testvak 2B'),
];

/// Where Smartschool redirects a save of the form of an own group to (seen
/// live, 2026-11-16).
const myGroupListAfterSave = '/?module=Profile&file=mygroups&function=main';

/// The `type` of Smartschool's feedback "De actie werd correct uitgevoerd.".
const myGroupFeedbackDone = 1;

/// The `type` of Smartschool's feedback "De actie werd niet correct
/// uitgevoerd!".
const myGroupFeedbackNotDone = 2;

/// The tags Smartschool strips from a saved name or description.
final myGroupTags = RegExp(r'<[^>]*>');

String _fixture(String name) => File(
  'test/fixtures/smartschool/requests/get/profile/mygroups/$name',
).readAsStringSync();

final _listEmpty = _fixture('list-empty.html');
final _form = _fixture('addedit.html');

/// The last part of the list's header, after which its rows come.
const _headerEnd =
    '<div class="smsc-table__cell smsc-table__cell--text-right '
    'mygroup-actions"></div>\n\t</div>\n';

/// The list of own groups with [groups], sorted by name, unescaped as
/// Smartschool sends them, with Smartschool's feedback of type [feedback]
/// in a script when given.
String myGroupListPage(List<FakeMyGroup> groups, {int? feedback}) {
  if (!_listEmpty.contains(_headerEnd)) {
    throw StateError('list-empty.html does not end its header as expected');
  }
  final sorted = [...groups]
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  final rows = [
    for (final group in sorted)
      '<div class="smsc-table__row">\n'
          '\t<div class="smsc-table__cell mygroup-icon star-icon"></div>\n'
          '\t<div class="smsc-table__cell mygroup-name">${group.name}</div>\n'
          '\t<div class="smsc-table__cell">${group.description}</div>\n'
          '\t<div class="smsc-table__cell smsc-table__cell--text-right mygroup-actions">\n'
          '\t\t<a href="/?module=Profile&file=mygroups&function=addedit&mID=${group.id}" class="edit" title=\'Wijzigen\'></a>\n'
          '\t\t<a href="/?module=Profile&file=mygroups&function=users&mID=${group.id}" class="add" title=\'Personen toevoegen\'></a>\n'
          '\t\t<a onClick="confirmDelete(\'/?module=Profile&file=mygroups&function=delete&mID=${group.id}\');" class="delete" title=\'Verwijderen\'></a>\n'
          '\t</div>\n'
          '</div>\n',
  ].join();
  final message = switch (feedback) {
    null => null,
    myGroupFeedbackDone => 'De actie werd correct uitgevoerd.',
    _ => 'De actie werd niet correct uitgevoerd!',
  };
  final script = message == null
      ? ''
      : '<script type="text/javascript">\$(document).ready(function() '
            '{var msg = "$message", type = $feedback;var show = function() '
            '{if (window.notificationShowFeedback) { '
            'window.notificationShowFeedback(msg, type); return true; }'
            'return false;};if (show()) { return; }});</script>\n';
  return _listEmpty
      .replaceFirst(_headerEnd, '$_headerEnd$rows')
      .replaceFirst('</body>', '$script</body>');
}

/// The form for a new own group with the token [token]; with [group], the
/// edit form of that group, its name and description escaped in their
/// `value`.
String myGroupFormPage(String token, [FakeMyGroup? group]) {
  const escape = HtmlEscape(HtmlEscapeMode.attribute);
  var page = _form.replaceFirst('made-up-token-new', token);
  if (group != null) {
    page = page
        .replaceFirst(
          'name="name" value=""',
          'name="name" value="${escape.convert(group.name)}"',
        )
        .replaceFirst(
          'name="desc" value=""',
          'name="desc" value="${escape.convert(group.description)}"',
        );
  }
  return page;
}

/// A made-up person of a fake Smartschool, as the member picker lists one
/// (#253): user ID, name (last name first), platform and school (`''` for
/// none).
class FakeMyGroupPerson {
  const FakeMyGroupPerson(
    this.userId,
    this.name, {
    this.ssId = 4069,
    this.schoolName = 'Springfield Academy',
  });

  final int userId;
  final String name;
  final int ssId;
  final String schoolName;
}

/// The members of own group 900501 in members.html and
/// get-items-selected.xml.
List<FakeMyGroupPerson> myGroupPeopleOfMembersFixture() => [
  const FakeMyGroupPerson(900001, 'Janssens Jan'),
  const FakeMyGroupPerson(900002, 'Peeters Marie'),
  const FakeMyGroupPerson(900003, 'Dupont Chloé', schoolName: ''),
];

final _membersEmpty = _fixture('members-empty.html');

/// The member picker's answer to `confirm Selection` (#253).
final myGroupConfirmAnswer = File(
  'test/fixtures/smartschool/requests/post/userselect/confirm-selection.xml',
).readAsStringSync();

/// The start of the table of members of members-empty.html, after which the
/// rows come.
const _membersTable = '<div class="smsc-table profile-users-table">\n';

/// The members page of own group [groupId] with [members], sorted by name as
/// Smartschool sorts them, and the token [token] in its form.
String myGroupMembersPage(
  int groupId,
  List<FakeMyGroupPerson> members, {
  required String token,
}) {
  if (!_membersEmpty.contains(_membersTable) ||
      !_membersEmpty.contains('made-up-token-900502')) {
    throw StateError('members-empty.html does not have its table and token');
  }
  const escape = HtmlEscape();
  final sorted = [...members]
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  final rows = [
    for (final person in sorted)
      '<div class="smsc-table__row">\n'
          '\t<div class="smsc-table__cell profile-users-table-icon"></div>\n'
          '\t<div class="smsc-table__cell" id="${person.userId}">'
          '${escape.convert(person.name)}</div>\n'
          '\t<div class="smsc-table__cell smsc-table__cell--text-right '
          'profile-users-table-action">\n'
          '\t\t<div class="delete2-icon deleteUserRow" '
          'data-userid="${person.userId}" data-groupid="$groupId" '
          'title="Verwijderen"></div>\n'
          '\t</div>\n'
          '</div>\n',
  ].join();
  return _membersEmpty
      .replaceFirst('made-up-token-900502', token)
      .replaceFirst(_membersTable, '$_membersTable$rows');
}

/// The member picker's answer to `get Items Selected` with [people] as its
/// selection, in the shape of get-items-selected.xml.
String myGroupSelectionAnswer(List<FakeMyGroupPerson> people) {
  const escape = HtmlEscape(HtmlEscapeMode.element);
  final items = [
    for (final person in people)
      '<item><type>U</type><id>${person.userId}</id>'
          '<ssId>${person.ssId}</ssId><parentId>0</parentId>'
          '<name>${escape.convert(person.name)}</name><icon>user</icon>'
          '<sortField>${escape.convert(person.name.toLowerCase())}</sortField>'
          '<selectable>1</selectable><forbidden>0</forbidden>'
          '<tooltip>Niet geselecteerd</tooltip>'
          '<schoolname>${escape.convert(person.schoolName)}</schoolname>'
          '</item>\n',
  ].join();
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<server><response><status>ok</status><actions><action>\n'
      '<subsystem>userselect</subsystem>'
      '<command>handle selected items</command>\n'
      '<data>${items.isEmpty ? '<items />' : '<items>\n$items</items>'}'
      '</data>\n'
      '</action></actions></response></server>\n';
}

/// A command of the member picker's dispatcher, the form field `command`:
/// its action and params by name.
({String action, Map<String, String> params}) myGroupPickerCommand(
  Object? command,
) {
  final element = XmlDocument.parse(
    '$command',
  ).rootElement.getElement('command')!;
  return (
    action: element.getElement('action')!.innerText,
    params: {
      for (final param in element.findAllElements('param'))
        param.getAttribute('name')!: param.innerText,
    },
  );
}

/// The items of [xml], the selection that a `confirm Selection` sends: each
/// item's type, platform and user ID, in its order.
List<({String type, int ssId, int userId})> myGroupSelectionSent(String xml) {
  final items = XmlDocument.parse(xml).rootElement;
  if (items.name.local != 'items') {
    throw FormatException('not a selection: $xml');
  }
  return [
    for (final item in items.findElements('item'))
      (
        type: item.getElement('type')!.innerText,
        ssId: int.parse(item.getElement('ssId')!.innerText),
        userId: int.parse(item.getElement('id')!.innerText),
      ),
  ];
}
