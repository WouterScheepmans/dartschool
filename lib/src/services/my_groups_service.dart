import 'package:dio/dio.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import '../exceptions.dart';
import '../models/message_models.dart';
import '../models/my_group_models.dart';
import '../session.dart';
import '../xml_answer.dart';
import '../xml_interface.dart';
import 'messages_service.dart';

export '../models/my_group_models.dart';

/// Reads the user's own mail groups (#251): the groups of "Mijn groepen" in
/// the profile (`/?module=Profile&file=mygroups`), and the members of one.
///
/// Every user keeps their own groups of people there; the compose form of
/// Messages finds such a group by its name, as a group, so that a message to
/// it goes to all its members ([findRecipient]).
///
/// ```dart
/// final groups = MyGroupsService(client);
/// final all = await groups.list();                        // List<MyGroup>
/// final members = await groups.members(all.first);        // List<MyGroupMember>
/// print('${all.first.name}: ${members.length} members');
///
/// // The group as a recipient of a message.
/// final recipient = await groups.findRecipient(all.first); // MessageSearchGroup?
/// ```
///
/// What Smartschool answers (seen live, 2026-11-16):
/// - **The list** (`GET /?module=Profile&file=mygroups`) is an HTML table
///   with a row per group, sorted by name: its name, its description, and
///   links that carry its ID (`mID`). It does not escape a name or a
///   description: see [MyGroup.name].
/// - **The members page** (`GET ...&function=users&mID={id}`) has a row per
///   member, sorted by name, with the member's user ID and name, but not the
///   member's platform (`ssId`). For an ID the user has no group of, it is
///   the list with the feedback "De actie werd niet correct uitgevoerd!".
/// - **The member picker** ("Personen toevoegen", Smartschool's general
///   user picker) gives the platform: loading the members page sets the
///   picker's selection for the group (`usc` `mygroups_{id}`) in the PHP
///   session to the current members, and the picker's dispatcher command
///   `userSelect` / `get Items Selected` (`POST
///   /?module=Userselect&file=dispatcher`) answers that selection, each
///   member with its `type`, `id`, `ssId`, `name` and `schoolname`.
///
/// [members] reads both, in one session, and checks that they list the same
/// members. A change of the members (Smartschool's picker steps, which
/// replace the selection) must not have a read of the group's members page
/// between its steps on the same session: the calls of [members] on one
/// [SmartschoolClient] take turns, also those through another
/// [MyGroupsService] of it. (Clients that share one session, through one
/// cache folder, do not take turns.)
///
/// The service only reads: it creates, renames or deletes no group and
/// changes no members. The models never print a name ([MyGroup.toString],
/// [MyGroupMember.toString]): the members of a group are mostly pupils.
///
/// ### Errors
/// - [SmartschoolMyGroupsError]: Smartschool answered with something the
///   service cannot use: another status than `200` (its
///   [SmartschoolMyGroupsError.statusCode]; a redirect of the picker's
///   request too), another page than the list or the members page, a picker
///   answer that is not `ok` or holds no selection, a row or item without
///   its ID, or a members page and a picker selection that do not list the
///   same members. Never an empty result. Its message names a group by its
///   ID only.
/// - [SmartschoolMyGroupNotFoundError] (a [SmartschoolMyGroupsError]):
///   [members] for a group the user does not have (any more).
/// - [SmartschoolUnexpectedPageError] (a [SmartschoolAuthenticationError]):
///   the picker answered with an HTML page instead of XML, as for every XML
///   command (see `SmartschoolClient.postXml`); a [SmartschoolParsingError]
///   for another answer that is not XML, malformed XML included.
/// - [SmartschoolSessionExpiredError]: Smartschool did not accept the
///   session, also after the client logged in again and retried once.
/// - Another [SmartschoolAuthenticationError]: logging in again failed.
/// - [SmartschoolConnectionError]: Smartschool could not be reached.
class MyGroupsService {
  final SmartschoolClient _client;

  MyGroupsService(SmartschoolClient client) : _client = client;

  /// The list of own groups.
  static const _listPath = '/?module=Profile&file=mygroups';

  /// The members page of own group [groupId].
  static String _membersPath(int groupId) =>
      '$_listPath&function=users&mID=$groupId';

  /// The dispatcher of Smartschool's user picker.
  static const _pickerPath = '/?module=Userselect&file=dispatcher';

  /// The picker's subsystem, as its web client names it in a command.
  static const _pickerSubsystem = 'userSelect';

  /// The picker's command that answers its current selection.
  static const _selectedItems = 'get Items Selected';

  /// The command of the picker's answer to [_selectedItems].
  static const _selectedItemsAnswer = 'handle selected items';

  /// The picker's key (`usc`) of the members of own group [groupId].
  static String _usc(int groupId) => 'mygroups_$groupId';

  /// The ID of a group in the URL of a link of its row.
  static final _mId = RegExp(r'[?&]mID=(\d+)');

  /// Returns the user's own mail groups, sorted by name as Smartschool lists
  /// them (#251); an empty list when the user has none.
  ///
  /// Sends `GET /?module=Profile&file=mygroups`. Throws a
  /// [SmartschoolMyGroupsError] for another status than `200`, for a page
  /// without the list of own groups, and for a row without a name or without
  /// one ID.
  Future<List<MyGroup>> list() async {
    const what = 'the list of own groups';
    final page = await _client.getResponse(_listPath);
    final table = _groupTable(_document(page, what));
    if (table == null) {
      throw const SmartschoolMyGroupsError(
        'Smartschool did not answer the list of own groups with that list.',
      );
    }
    return _groups(table);
  }

  /// Returns the members of the own group [group] (#251), in the order of
  /// its members page (by name); an empty list for a group without members.
  ///
  /// Reads the group's members page (`GET
  /// /?module=Profile&file=mygroups&function=users&mID={id}`), and then, in
  /// the session of that page, the member picker's selection for the group
  /// (`userSelect` / `get Items Selected` with `usc` `mygroups_{id}`), which
  /// the page set to the current members. Each [MyGroupMember] has the
  /// picker's `ssId` and school, which a change of the members needs. The
  /// picker's request is not retried after logging in again, nor sent in
  /// another session than the page's: when Smartschool refuses its session,
  /// or the client logged in again since the page was loaded, this loads
  /// the page again (logging in first) and reads the picker once more; when
  /// that fails too, it throws a [SmartschoolSessionExpiredError].
  ///
  /// The calls on one [SmartschoolClient] take turns (see the class doc).
  ///
  /// Throws a [SmartschoolMyGroupNotFoundError] when the user has no own
  /// group with [group]'s ID (Smartschool answers the list instead), and a
  /// [SmartschoolMyGroupsError] when the page or the picker answer cannot be
  /// used, or when they do not list the same members.
  Future<List<MyGroupMember>> members(MyGroup group) =>
      _onePickerReadAtATime(() async {
        for (var attempt = 1; ; attempt++) {
          final page = await _client.getResponse(_membersPath(group.id));
          final listed = _memberIds(page, group.id);
          final Response<String> answer;
          try {
            answer = await _client.postFormResponse(
              _pickerPath,
              {
                'command': XmlInterface.buildCommand(
                  _pickerSubsystem,
                  _selectedItems,
                  {'usc': _usc(group.id)},
                ),
              },
              retryAfterLogin: false,
              sameSessionAs: page,
            );
          } on SmartschoolSessionExpiredError {
            if (attempt >= 2) rethrow;
            continue;
          }
          return _join(listed, _selection(answer, group.id), group.id);
        }
      });

  /// Finds the own group [group] as a recipient of a message (#251): the
  /// [MessageSearchGroup] that the compose form's recipient search
  /// (`MessagesService.searchRecipientsForCompose`) finds for its name, with
  /// the group's ID as its `groupId` and its name as its `displayName`; or
  /// `null` when the search does not find it so.
  ///
  /// Pass it to `SendMessageParams.toGroups` (or `ccGroups`, `bccGroups`):
  /// a message to it goes to all the group's members. Throws an
  /// [ArgumentError], without sending anything, for a group whose name is
  /// blank. Throws what `searchRecipientsForCompose` throws.
  Future<MessageSearchGroup?> findRecipient(MyGroup group) async {
    final name = group.name.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(group, 'group', 'has no name to search for');
    }
    final (_, groups) = await MessagesService(
      _client,
    ).searchRecipientsForCompose(name);
    for (final found in groups) {
      if (found.groupId == group.id && found.displayName.trim() == name) {
        return found;
      }
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // The member picker's turns
  // -------------------------------------------------------------------------

  /// The last read of each client through the member picker, which the next
  /// one waits for: see [_onePickerReadAtATime].
  static final _pickerReads = Expando<Future<void>>('my groups picker');

  /// Runs [read] once the reads through the member picker on the same
  /// [SmartschoolClient] that came before it are done, also those through
  /// another [MyGroupsService] of it: the picker's selection lives in the
  /// session, and a change of a group's members must not have a load of its
  /// members page between its steps. Whether one before it failed does not
  /// matter.
  Future<T> _onePickerReadAtATime<T>(Future<T> Function() read) {
    final before = _pickerReads[_client] ?? Future<void>.value();
    final done = before.then((_) => read());
    _pickerReads[_client] = done.then<void>((_) {}, onError: (Object _) {});
    return done;
  }

  // -------------------------------------------------------------------------
  // The pages
  // -------------------------------------------------------------------------

  /// The HTML document of [page], Smartschool's answer to [what]; throws a
  /// [SmartschoolMyGroupsError] for another status than `200`.
  static html_dom.Document _document(Response<String> page, String what) {
    final status = page.statusCode ?? 0;
    if (status != 200) {
      throw SmartschoolMyGroupsError(
        'Smartschool answered $what with HTTP $status.',
        statusCode: status,
      );
    }
    return html_parser.parse(page.data ?? '');
  }

  /// The table of own groups of [doc], or `null` when it has none.
  static html_dom.Element? _groupTable(html_dom.Document doc) =>
      doc.querySelector('div.mygroup-table');

  /// The groups of the rows of [table], the table of own groups.
  static List<MyGroup> _groups(html_dom.Element table) {
    final groups = <MyGroup>[];
    final ids = <int>{};
    for (final (index, row)
        in table.querySelectorAll('div.smsc-table__row').indexed) {
      final nameCell = row.querySelector('div.mygroup-name');
      final id = _rowId(row);
      if (nameCell == null || id == null) {
        throw SmartschoolMyGroupsError(
          'Row ${index + 1} of the list of own groups has '
          '${nameCell == null ? 'no name' : 'not one group ID in its links'}.',
        );
      }
      if (!ids.add(id)) {
        throw SmartschoolMyGroupsError(
          'The list of own groups has group $id twice.',
        );
      }
      final next = nameCell.nextElementSibling;
      final description =
          next == null || next.classes.contains('mygroup-actions')
          ? ''
          : next.text.trim();
      groups.add(
        MyGroup(id: id, name: nameCell.text.trim(), description: description),
      );
    }
    return groups;
  }

  /// The group ID that the links of [row] (their `href` and `onclick`)
  /// carry as `mID`, or `null` when they carry none or more than one.
  static int? _rowId(html_dom.Element row) {
    final ids = <int>{};
    for (final link in row.querySelectorAll('a')) {
      for (final url in [link.attributes['href'], link.attributes['onclick']]) {
        for (final match in _mId.allMatches(url ?? '')) {
          ids.add(int.parse(match.group(1)!));
        }
      }
    }
    return ids.length == 1 ? ids.single : null;
  }

  /// The user IDs of the member rows of [page], the members page of own
  /// group [groupId], in its order.
  ///
  /// Throws a [SmartschoolMyGroupNotFoundError] when it is the list of own
  /// groups, and a [SmartschoolMyGroupsError] when it is not the members
  /// page (no form with `mID`), or for a row without a numeric member ID or
  /// of another group.
  static List<int> _memberIds(Response<String> page, int groupId) {
    final what = 'the members page of own group $groupId';
    final doc = _document(page, what);
    if (_groupTable(doc) != null) {
      throw SmartschoolMyGroupNotFoundError(
        'The user has no own group $groupId: Smartschool answered $what with '
        'the list of own groups.',
        groupId: groupId,
      );
    }
    final form = doc.querySelector('form[name="form"]');
    if (form == null || form.querySelector('input[name="mID"]') == null) {
      throw SmartschoolMyGroupsError(
        'Smartschool did not answer $what with that page.',
      );
    }
    final ids = <int>[];
    for (final (index, row)
        in doc.querySelectorAll('div.smsc-table__row').indexed) {
      final cell = row.querySelector('div.smsc-table__cell[id]');
      final remove = row.querySelector('.deleteUserRow');
      final userId = int.tryParse(cell?.id ?? '');
      final removeUser = remove?.attributes['data-userid'];
      final removeGroup = remove?.attributes['data-groupid'];
      if (userId == null ||
          (removeUser != null && removeUser != '$userId') ||
          (removeGroup != null && removeGroup != '$groupId')) {
        throw SmartschoolMyGroupsError(
          'Row ${index + 1} of $what '
          '${userId == null ? 'has no member ID' : 'names another member or group in its delete button'}.',
        );
      }
      ids.add(userId);
    }
    return ids;
  }

  // -------------------------------------------------------------------------
  // The member picker
  // -------------------------------------------------------------------------

  /// The members of the picker's [answer] to [_selectedItems] for own group
  /// [groupId].
  static List<MyGroupMember> _selection(Response<String> answer, int groupId) {
    final what =
        'the member picker\'s selection of own group $groupId '
        '($_selectedItems)';
    final status = answer.statusCode ?? 0;
    if (status >= 300 && status < 400) {
      final location = answer.headers.value('location');
      throw SmartschoolMyGroupsError(
        'Smartschool redirected the read of $what to '
        '${location ?? 'another page'} (HTTP $status).',
        statusCode: status,
      );
    }
    if (status != 200) {
      throw SmartschoolMyGroupsError(
        'Smartschool answered the read of $what with HTTP $status.',
        statusCode: status,
      );
    }
    return readXmlAnswer(
      answer,
      action: _selectedItems,
      parse: (body) => _parseSelection(body, what),
    );
  }

  /// The members of [body], the XML of the picker's answer to [what].
  ///
  /// Throws a [FormatException] for malformed XML (which `readXmlAnswer`
  /// reports), and a [SmartschoolMyGroupsError] for an answer that is not
  /// `ok`, that holds no selection, or an item without its type, ID or
  /// platform.
  static List<MyGroupMember> _parseSelection(String body, String what) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(body);
    } on XmlException catch (e) {
      throw FormatException(e.message);
    }
    final response = doc.rootElement.getElement('response');
    final status = response?.getElement('status')?.innerText.trim();
    if (status != 'ok') {
      throw SmartschoolMyGroupsError(
        'The member picker answered the read of $what with status '
        '${status == null ? '(none)' : '"$status"'}.',
      );
    }
    final selections = [
      for (final action
          in response!.getElement('actions')?.findElements('action') ??
              const <XmlElement>[])
        if (action.getElement('command')?.innerText.trim() ==
            _selectedItemsAnswer)
          action.getElement('data')?.getElement('items'),
    ];
    if (selections.length != 1 || selections.single == null) {
      throw SmartschoolMyGroupsError(
        'The member picker\'s answer to the read of $what holds '
        '${selections.isEmpty ? 'no' : 'not one'} selection '
        '("$_selectedItemsAnswer" with its items).',
      );
    }
    final members = <MyGroupMember>[];
    for (final (index, item)
        in selections.single!.findElements('item').indexed) {
      String? text(String name) => item.getElement(name)?.innerText.trim();
      final type = text('type');
      final userId = int.tryParse(text('id') ?? '');
      final ssId = int.tryParse(text('ssId') ?? '');
      if (type == null || type.isEmpty || userId == null || ssId == null) {
        throw SmartschoolMyGroupsError(
          'Item ${index + 1} of $what has no type, ID or platform (ssId).',
        );
      }
      final school = text('schoolname');
      members.add(
        MyGroupMember(
          userId: userId,
          name: text('name') ?? '',
          ssId: ssId,
          schoolName: school == null || school.isEmpty ? null : school,
          type: type,
        ),
      );
    }
    return members;
  }

  /// The members of own group [groupId] in the order of its members page,
  /// whose rows list the user IDs [listed], from the picker's [selection];
  /// throws a [SmartschoolMyGroupsError] when the two do not list the same
  /// members.
  static List<MyGroupMember> _join(
    List<int> listed,
    List<MyGroupMember> selection,
    int groupId,
  ) {
    final picked = {for (final member in selection) member.userId: member};
    final same =
        picked.length == selection.length &&
        listed.toSet().length == listed.length &&
        listed.length == picked.length &&
        listed.every(picked.containsKey);
    if (!same) {
      throw SmartschoolMyGroupsError(
        'The members page of own group $groupId lists ${listed.length} '
        'members, and the member picker\'s selection ${selection.length}: '
        'they are not the same members. Read them again.',
      );
    }
    return [for (final userId in listed) picked[userId]!];
  }
}
