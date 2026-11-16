// The pages of "Mijn groepen" (`/?module=Profile&file=mygroups`) for a fake
// Smartschool that keeps own mail groups and changes them (#252), built from
// the hand-written fixtures of get/profile/mygroups/: the list of own groups
// in the shape of list.html (from list-empty.html, with a row per group and
// the feedback of an action), and the form of a group in the shape of
// addedit.html. Made-up groups and IDs only.
import 'dart:convert';
import 'dart:io';

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
