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

/// The user's own mail groups (#251): the groups of "Mijn groepen" in the
/// profile (`/?module=Profile&file=mygroups`), and the members of one;
/// creating, renaming and deleting such a group (#252); and adding,
/// removing and setting its members (#253).
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
///
/// // Create a group, rename it and change its description, delete it (#252).
/// var group = await groups.create(name: 'Projectgroep');
/// group = await groups.update(group, name: 'Projectgroep 5', description: 'reis');
/// await groups.delete(group);
///
/// // Change its members (#253): people as the compose search finds them.
/// final (users, _) =
///     await MessagesService(client).searchRecipientsForCompose('Janssens');
/// await groups.addMembers(group, [users.first]);         // bool
/// await groups.removeMember(group, (await groups.members(group)).first);
/// await groups.setMembers(group, users);                 // replaces them
/// await groups.clearMembers(group);
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
/// - **The form** of a group (`GET ...&function=addedit`, with `&mID={id}`
///   for an existing group, #252) has a token (`_csrf_token`, a new one for
///   every load), `store`, and the inputs `name` and `desc`, filled in (and
///   escaped) for an existing group. For an ID the user has no group of, it
///   is the list with that feedback.
/// - **A save** (`POST` of that form to the URL it was loaded from, #252)
///   answers `302` to the list (`function=main`), without the group's ID.
///   The outcome is only in the list after it: the feedback "De actie werd
///   niet correct uitgevoerd!" (type `2`) for a save Smartschool refused (an
///   empty name), no feedback for one that went through. Smartschool keeps
///   the feedback in the session until a page shows it.
/// - **A delete** (`GET ...&function=delete&mID={id}`, #252; the web client
///   asks first, in a JavaScript `confirm()`) answers the list itself,
///   without the group, with "De actie werd correct uitgevoerd." (type `1`);
///   for an ID the user has no group of, with type `2`.
/// - **A change of the members** (#253) takes three steps in one session:
///   the members page (which sets the picker's selection to the current
///   members, and holds a form `form` with `_csrf_token`, `store` and
///   `mID`); the picker's command `confirm Selection` with the `usc` and
///   the **whole** new selection (an `<item>` of `type` `U`, `ssId` and
///   `id` per member, in `<items>`), which answers `closeUsc` and saves
///   nothing; and a `POST` of the members form to the members page's
///   URL, which saves the selection and answers the members page with the
///   new members. The selection replaces the members. A load of the members
///   page between the second and the third step resets the selection, and
///   the third step then saves the old members.
/// - **The removal of one member** (`POST /Profile/Mygroups/deleteUser`,
///   form-encoded `userID` and `groupID`, #253) answers `true`, also for
///   someone who is not a member.
///
/// [members] reads the members page and the picker's selection, in one
/// session, and checks that they list the same members. A change of the
/// members (Smartschool's picker steps, which replace the selection) must
/// not have a read of the group's members page between its steps on the
/// same session: the calls of [members], [create], [update], [delete],
/// [addMembers], [setMembers], [clearMembers] and [removeMember] on one
/// [SmartschoolClient] take turns, also those through another
/// [MyGroupsService] of it. (Clients that share one session, through one
/// cache folder, do not take turns; nor do the calls of [list].)
///
/// ### Writes (#252)
/// [create] makes a group, [update] changes its name, its description or
/// both, [delete] deletes it (with its member list). Each reads the list
/// first, and only changes a group the list has; [create] and [update]
/// refuse a name that another own group has already (two such groups could
/// not be told apart in the compose search), and a blank one. Each sends its
/// save or delete **once**: a save never again after logging in again; a
/// delete, a GET, again only when Smartschool refused the session for it
/// and so did not handle it. Then it checks Smartschool's feedback and the
/// list it shows: a write it cannot confirm is a
/// [SmartschoolMyGroupSaveUnconfirmedError]. Name and description are plain
/// text: Smartschool strips tags when it saves them (`a <b>b</b>` is saved
/// as `a b`), and the writes return them as the list shows them after the
/// save. A limit on their length was not tried.
///
/// ### The members (#253)
/// [addMembers] adds people to a group, [setMembers] makes people its only
/// members, [clearMembers] removes them all, [removeMember] removes one.
/// They take people as `MessagesService.searchRecipientsForCompose` finds
/// them, of the own school only (adding a person of another school of the
/// school group was not tried), and change only groups with people as their
/// members (a class or a group as a member was not tried). The first three
/// send the picker's steps in the session of the members page, **once**,
/// and check the members page Smartschool answers: exactly the members
/// sent. [removeMember] checks the members page before and after the
/// removal. Each returns `false`, without sending a change, when there is
/// nothing to change.
///
/// The models never print a name ([MyGroup.toString],
/// [MyGroupMember.toString]): the members of a group are mostly pupils.
///
/// ### Errors
/// - [ArgumentError]: [create] or [update] with a blank name (or one that is
///   empty without its tags), or a name that another own group has; [update]
///   with neither a name nor a description. Nothing was saved (for a name
///   another group has, the list was read). [addMembers] and [setMembers]
///   without people, or with a person who is not known to be of the own
///   school; [removeMember] of a member that is not a person (#253).
///   Nothing was sent.
/// - [SmartschoolMyGroupsError]: Smartschool answered a read with something
///   the service cannot use: another status than `200` (its
///   [SmartschoolMyGroupsError.statusCode]; a redirect of the picker's
///   request too), another page than the list, the members page or the form,
///   a form without its token, a picker answer that is not `ok` or holds no
///   selection, a row or item without its ID, or a members page and a
///   picker selection that do not list the same members. Never an empty
///   result. Its message names a group by its ID only. From a write: from a
///   read before its save, so nothing was changed; for a change of the
///   members, also a picker answer to the new selection that does not close
///   on the members form, and a group with a member that is not a person
///   (#253).
/// - [SmartschoolMyGroupNotFoundError] (a [SmartschoolMyGroupsError]):
///   [members], [update], [delete] or a change of the members for a group
///   the user does not have (any more).
/// - [SmartschoolMyGroupSaveUnconfirmedError] (not a
///   [SmartschoolMyGroupsError]): a save, a delete, the members form or the
///   removal of a member went out, but its answer does not confirm it. It
///   may or may not have been made: list the groups (or read the members)
///   before trying again.
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

  /// The form for a new own group, or with [groupId] the edit form of that
  /// group: the page a save is posted to as well (its `action` is `""`).
  static String _formPath([int? groupId]) =>
      '$_listPath&function=addedit${groupId == null ? '' : '&mID=$groupId'}';

  /// The delete of own group [groupId], a GET.
  static String _deletePath(int groupId) =>
      '$_listPath&function=delete&mID=$groupId';

  /// The `type` of Smartschool's feedback for an action that went through:
  /// "De actie werd correct uitgevoerd.".
  static const _feedbackDone = 1;

  /// The `type` of Smartschool's feedback for an action that was not done:
  /// "De actie werd niet correct uitgevoerd!".
  static const _feedbackNotDone = 2;

  /// The feedback in a script of a page: `var msg = "...", type = N`.
  static final _feedbackScript = RegExp(
    r'var\s+msg\s*=\s*"((?:[^"\\]|\\.)*)"\s*,\s*type\s*=\s*(\d+)',
  );

  /// The dispatcher of Smartschool's user picker.
  static const _pickerPath = '/?module=Userselect&file=dispatcher';

  /// The picker's subsystem, as its web client names it in a command.
  static const _pickerSubsystem = 'userSelect';

  /// The picker's command that answers its current selection.
  static const _selectedItems = 'get Items Selected';

  /// The command of the picker's answer to [_selectedItems].
  static const _selectedItemsAnswer = 'handle selected items';

  /// The picker's command that replaces its selection with the one it is
  /// sent (#253), as its button "Bevestigen" sends it. It saves nothing: the
  /// members form, posted after it, saves the selection.
  static const _confirmSelection = 'confirm Selection';

  /// The command of the picker's answer to [_confirmSelection]: close the
  /// picker, and submit the form of the page that opened it.
  static const _confirmSelectionAnswer = 'closeUsc';

  /// The form of the members page that the picker's web client submits once
  /// a selection is confirmed (#253).
  static const _membersFormName = 'form';

  /// The removal of one member from an own group (#253): a form-encoded POST
  /// of `userID` and `groupID`, the cross on a member's row.
  static const _deleteUserPath = '/Profile/Mygroups/deleteUser';

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

  /// Creates an own group named [name], with the description [description],
  /// and returns it as the list of own groups shows it after the save
  /// (#252).
  ///
  /// Reads the list of own groups, loads the form for a new group (`GET
  /// /?module=Profile&file=mygroups&function=addedit`) for its token, and
  /// posts it to the same URL with `_csrf_token`, `store`, `name` and
  /// `desc`. Smartschool answers with a redirect to the list, which the
  /// service follows at once: the new group is the one with the name and
  /// description sent that the list has after the save and did not have
  /// before (Smartschool's answer does not name it). Smartschool strips tags
  /// from a name and a description, so they can differ from what was sent
  /// (see the class doc).
  ///
  /// The save is sent **once**: never again after logging in again (the
  /// token is in the session), nor in another session than the form's. The
  /// calls on one [SmartschoolClient] take turns (see the class doc).
  ///
  /// Throws an [ArgumentError], without sending anything, when [name] is
  /// blank or empty once its tags are stripped (Smartschool refuses it
  /// without saying why); and, once the list was read, when another own
  /// group has that name already (as the list shows it). Throws a
  /// [SmartschoolMyGroupSaveUnconfirmedError] when the save went out but the
  /// answer does not confirm it: list the groups before trying again, a
  /// second save of a create that went through makes a second group (this
  /// method refuses its name then). Throws a [SmartschoolMyGroupsError] when
  /// the list or the form cannot be read, before the save.
  Future<MyGroup> create({
    required String name,
    String description = '',
  }) async {
    _checkName(name);
    return _oneAtATime(() async {
      final before = await list();
      _checkNameFree(before, name);
      final form = await _form(null);
      final what = 'the create of an own group';
      final after = await _save(
        form,
        null,
        name: name,
        description: description,
        what: what,
      );
      final known = {for (final group in before) group.id};
      final added = [
        for (final group in after)
          if (!known.contains(group.id)) group,
      ];
      final listedName = _asListed(name);
      final listedDescription = _asListed(description);
      final made = [
        for (final group in added)
          if (group.name == listedName &&
              group.description == listedDescription)
            group,
      ];
      if (made.length != 1) {
        throw SmartschoolMyGroupSaveUnconfirmedError(
          'Smartschool answered $what with the list of own groups, but that '
          'list has ${made.length} new groups with the name and description '
          'sent, not one (${added.length} new groups in all). List the '
          'groups before trying again.',
        );
      }
      return made.single;
    });
  }

  /// Changes the name, the description or both of the own group [group], and
  /// returns the group as the list of own groups shows it after the save
  /// (#252).
  ///
  /// A `null` [name] or [description] keeps the one the group has: the
  /// value of its edit form, which has it exactly. Both go with every save,
  /// so an empty [description] empties the description.
  ///
  /// Reads the list of own groups (the group must be in it), loads the
  /// group's edit form (`GET
  /// /?module=Profile&file=mygroups&function=addedit&mID={id}`) for its
  /// token and values, and posts it to the same URL with `_csrf_token`,
  /// `store`, `name` and `desc`. Smartschool answers with a redirect to the
  /// list, which the service follows at once: the group must have the name
  /// and description sent there. Smartschool strips tags from both (see the
  /// class doc).
  ///
  /// The save is sent **once**: never again after logging in again, nor in
  /// another session than the form's. The calls on one [SmartschoolClient]
  /// take turns (see the class doc).
  ///
  /// Throws an [ArgumentError], without sending anything, when both [name]
  /// and [description] are `null`, or [name] is blank or empty once its
  /// tags are stripped; and, once the list was read, when another own group
  /// has that name already. Throws a [SmartschoolMyGroupNotFoundError] when
  /// the list does not have [group]'s ID, or Smartschool answers its edit
  /// form with the list (it was deleted meanwhile): nothing was saved.
  /// Throws a [SmartschoolMyGroupSaveUnconfirmedError] when the save went out
  /// but the answer does not confirm it; trying again saves the same values
  /// again. Throws a [SmartschoolMyGroupsError] when the list or the form
  /// cannot be read, before the save.
  Future<MyGroup> update(
    MyGroup group, {
    String? name,
    String? description,
  }) async {
    if (name == null && description == null) {
      throw ArgumentError(
        'Give a name, a description or both: update changes nothing else.',
      );
    }
    if (name != null) _checkName(name);
    return _oneAtATime(() async {
      final before = await list();
      _checkListed(before, group.id, 'update');
      if (name != null) _checkNameFree(before, name, except: group.id);
      final form = await _form(group.id);
      final newName = name ?? form.name;
      final newDescription = description ?? form.description;
      final what = 'the update of own group ${group.id}';
      final after = await _save(
        form,
        group.id,
        name: newName,
        description: newDescription,
        what: what,
      );
      final saved = after.where((g) => g.id == group.id).firstOrNull;
      if (saved == null ||
          saved.name != _asListed(newName) ||
          saved.description != _asListed(newDescription)) {
        throw SmartschoolMyGroupSaveUnconfirmedError(
          'Smartschool answered $what with the list of own groups, but '
          '${saved == null ? 'that list does not have the group' : 'the group does not have the name and description sent there'}. '
          'List the groups to see what was saved.',
          groupId: group.id,
        );
      }
      return saved;
    });
  }

  /// Deletes the own group [group], with its member list (#252).
  ///
  /// Reads the list of own groups (the group must be in it), and sends the
  /// delete, a GET (`/?module=Profile&file=mygroups&function=delete&mID={id}`,
  /// what the web client sends once its `confirm()` is answered).
  /// Smartschool answers it with the list itself: the delete went through
  /// when that list does not have the group, with the feedback "De actie
  /// werd correct uitgevoerd." (type `1`).
  ///
  /// The delete is sent once by the service. (Like every GET, it is sent
  /// again after logging in when Smartschool refused the session for it:
  /// Smartschool did not handle it then.) The calls on one
  /// [SmartschoolClient] take turns (see the class doc).
  ///
  /// Throws a [SmartschoolMyGroupNotFoundError] when the list does not have
  /// [group]'s ID (nothing is deleted), and when Smartschool answers the
  /// delete with the feedback "De actie werd niet correct uitgevoerd!" (type
  /// `2`) and a list without the group: it was gone already. Throws a
  /// [SmartschoolMyGroupSaveUnconfirmedError] for any other answer that does
  /// not confirm the delete, or when the delete failed after it went out:
  /// list the groups before trying again. Throws a
  /// [SmartschoolMyGroupsError] when the list cannot be read, before the
  /// delete.
  Future<void> delete(MyGroup group) => _oneAtATime(() async {
    final before = await list();
    _checkListed(before, group.id, 'delete');
    final what = 'the delete of own group ${group.id}';
    final Response<String> page;
    try {
      page = await _client.getResponse(_deletePath(group.id));
    } on SmartschoolAuthenticationError {
      // Refused before Smartschool handled it: nothing was deleted.
      rethrow;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolMyGroupSaveUnconfirmedError(
          '$what was sent, but no answer came in ($e). List the groups '
          'before trying again.',
          groupId: group.id,
          cause: e,
        ),
        stackTrace,
      );
    }
    final (feedbackType, after) = _listAfter(page, what, group.id);
    final gone = !after.any((g) => g.id == group.id);
    if (gone && feedbackType == _feedbackDone) return;
    if (gone && feedbackType == _feedbackNotDone) {
      throw SmartschoolMyGroupNotFoundError(
        'Smartschool answered $what with its feedback that it was not done '
        '(type $feedbackType) and a list without the group: the user had no '
        'own group ${group.id} any more.',
        groupId: group.id,
      );
    }
    throw SmartschoolMyGroupSaveUnconfirmedError(
      'Smartschool answered $what with the list of own groups, '
      '${gone ? 'without the group' : 'with the group still in it'}, and '
      '${feedbackType == null ? 'no feedback' : 'a feedback of type $feedbackType'}. '
      'List the groups before trying again.',
      groupId: group.id,
    );
  });

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
      _oneAtATime(() async => (await _current(group)).members);

  /// Adds [users] to the members of the own group [group] (#253). Returns
  /// `true` once the change is saved and confirmed, `false` when each of
  /// [users] is a member already: then nothing but the reads was sent.
  ///
  /// [users] are people as `MessagesService.searchRecipientsForCompose`
  /// finds them (or the own account, as
  /// `MessagesService.getCurrentUserAsRecipient` gives it): each must be of
  /// the own school ([MessageSearchUser.otherSchool] `false`), since adding
  /// a person of another school of the school group was not tried. The same
  /// person twice is added once.
  ///
  /// Smartschool's member picker replaces the members with the selection it
  /// is sent, so this sends the current members with the new ones, in the
  /// three steps of the web client, in one session: it loads the group's
  /// members page (which sets the picker's selection to the current
  /// members, and holds the form and its token) and reads the picker's
  /// selection for their platforms (as [members] does); it sends the picker
  /// the whole new selection (`userSelect` / `confirm Selection`, which
  /// saves nothing yet); and it posts the members form (`_csrf_token`,
  /// `store`, `mID`), which saves the selection and is answered with the
  /// members page. The change is confirmed when that page lists exactly the
  /// members sent.
  ///
  /// The picker's command and the form are sent **once**: never again after
  /// logging in again, nor in another session than the members page's. The
  /// calls on one [SmartschoolClient] take turns (see the class doc), so no
  /// other load of the members page comes between the steps.
  ///
  /// Throws an [ArgumentError], without sending anything, when [users] is
  /// empty, or holds a person of another school, one whose school is not
  /// known ([MessageSearchUser.otherSchool] `null`), one without a user ID
  /// or platform, or people of different platforms. Throws a
  /// [SmartschoolMyGroupNotFoundError] when the user has no own group with
  /// [group]'s ID, and a [SmartschoolMyGroupsError] when the members page,
  /// the picker's selection or the picker's answer to the new selection
  /// cannot be used, when the group has a member that is not a person (a
  /// class or a group: not tried), or a member with one of [users]' user
  /// IDs on another platform: nothing was saved then. Throws a
  /// [SmartschoolMyGroupSaveUnconfirmedError] when the form went out but its
  /// answer does not confirm the change: read the members before trying
  /// again.
  Future<bool> addMembers(
    MyGroup group,
    Iterable<MessageSearchUser> users,
  ) async {
    final people = _people(users);
    if (people.isEmpty) {
      throw ArgumentError('Give at least one person to add.', 'users');
    }
    return _oneAtATime(() => _changeMembers(group, people, replace: false));
  }

  /// Makes [users] the members of the own group [group], in place of its
  /// current members (#253). Returns `true` once the change is saved and
  /// confirmed, `false` when [users] are its members already (nothing but
  /// the reads was sent).
  ///
  /// [users] as for [addMembers]: people of the own school, each once. An
  /// empty [users] is refused: [clearMembers] empties a group. Sent and
  /// confirmed as [addMembers] does, with [users] alone as the picker's new
  /// selection; throws what it throws.
  Future<bool> setMembers(
    MyGroup group,
    Iterable<MessageSearchUser> users,
  ) async {
    final people = _people(users);
    if (people.isEmpty) {
      throw ArgumentError(
        'Give at least one person: setMembers does not empty a group, '
            'clearMembers does.',
        'users',
      );
    }
    return _oneAtATime(() => _changeMembers(group, people, replace: true));
  }

  /// Removes every member of the own group [group] (#253). Returns `true`
  /// once the change is saved and confirmed, `false` when the group has no
  /// members (nothing but the reads was sent).
  ///
  /// Sent and confirmed as [addMembers] does, with an empty selection
  /// (`<items></items>`, which left a group without members, seen live);
  /// throws what it throws, but no [ArgumentError].
  Future<bool> clearMembers(MyGroup group) =>
      _oneAtATime(() => _changeMembers(group, const [], replace: true));

  /// Removes [member] from the own group [group] (#253). Returns `true` once
  /// the removal is confirmed, `false` when the group's members page does
  /// not list [member] (nothing but that read was sent).
  ///
  /// Reads the group's members page, sends the removal of the web client's
  /// cross on a member (`POST /Profile/Mygroups/deleteUser`, form-encoded
  /// `userID` and `groupID`, with `X-Requested-With`), and reads the members
  /// page again: Smartschool answers the removal with `true` also for
  /// someone who is not a member (seen live), so the removal is confirmed
  /// when that answer is `true` and the members page after it no longer
  /// lists [member]. A removal sent again removes no one else: like every
  /// request that carries no state of a page, it goes out again after
  /// logging in when Smartschool refused the session for it.
  ///
  /// The calls on one [SmartschoolClient] take turns (see the class doc).
  ///
  /// Throws an [ArgumentError], without sending anything, for a [member]
  /// that is not a person ([MyGroupMember.isUser]; removing a class or a
  /// group was not tried). Throws a [SmartschoolMyGroupNotFoundError] when
  /// the user has no own group with [group]'s ID, and a
  /// [SmartschoolMyGroupsError] when the members page cannot be used, before
  /// the removal. Throws a [SmartschoolMyGroupSaveUnconfirmedError] when the
  /// removal went out but is not confirmed: read the members before trying
  /// again.
  Future<bool> removeMember(MyGroup group, MyGroupMember member) async {
    if (!member.isUser) {
      throw ArgumentError(
        'Member ${member.userId} is not a person (type ${member.type}): '
            'removing a class or a group from an own group was not tried.',
        'member',
      );
    }
    return _oneAtATime(() async {
      final page = await _client.getResponse(_membersPath(group.id));
      if (!_memberIds(page, group.id).contains(member.userId)) return false;
      final what =
          'the removal of member ${member.userId} from own group ${group.id}';
      const tryAgain = 'Read the members before trying again.';
      final Response<String> answer;
      try {
        answer = await _client.postFormResponse(_deleteUserPath, {
          'userID': '${member.userId}',
          'groupID': '${group.id}',
        });
      } on SmartschoolAuthenticationError {
        // Refused before Smartschool handled it: no one was removed.
        rethrow;
      } on Exception catch (e, stackTrace) {
        Error.throwWithStackTrace(
          SmartschoolMyGroupSaveUnconfirmedError(
            '$what was sent, but no answer came in ($e). $tryAgain',
            groupId: group.id,
            cause: e,
          ),
          stackTrace,
        );
      }
      final status = answer.statusCode ?? 0;
      if (status != 200 || (answer.data ?? '').trim() != 'true') {
        throw SmartschoolMyGroupSaveUnconfirmedError(
          'Smartschool answered $what with HTTP $status'
          '${status == 200 ? ' and another answer than true' : ''}. $tryAgain',
          groupId: group.id,
          statusCode: status == 200 ? null : status,
        );
      }
      final List<int> after;
      try {
        after = _memberIds(
          await _client.getResponse(_membersPath(group.id)),
          group.id,
        );
      } on Exception catch (e, stackTrace) {
        Error.throwWithStackTrace(
          SmartschoolMyGroupSaveUnconfirmedError(
            'Smartschool answered $what with true, but the members page '
            'after it could not be read ($e). $tryAgain',
            groupId: group.id,
            statusCode: e is SmartschoolMyGroupsError ? e.statusCode : null,
            cause: e,
          ),
          stackTrace,
        );
      }
      if (after.contains(member.userId)) {
        throw SmartschoolMyGroupSaveUnconfirmedError(
          'Smartschool answered $what with true, but the members page after '
          'it still lists the member. $tryAgain',
          groupId: group.id,
        );
      }
      return true;
    });
  }

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
  // The turns
  // -------------------------------------------------------------------------

  /// The last call of each client that takes turns (a read through the
  /// member picker, a write), which the next one waits for: see
  /// [_oneAtATime].
  static final _turns = Expando<Future<void>>('my groups turns');

  /// Runs [call] once the calls that take turns on the same
  /// [SmartschoolClient] and came before it are done, also those through
  /// another [MyGroupsService] of it: the picker's selection lives in the
  /// session, and a change of a group's members must not have a load of its
  /// members page between its steps; a write reads the list before and
  /// after its save, to tell its own change from another's (#252). Whether
  /// one before it failed does not matter.
  Future<T> _oneAtATime<T>(Future<T> Function() call) {
    final before = _turns[_client] ?? Future<void>.value();
    final done = before.then((_) => call());
    _turns[_client] = done.then<void>((_) {}, onError: (Object _) {});
    return done;
  }

  // -------------------------------------------------------------------------
  // The writes (#252)
  // -------------------------------------------------------------------------

  /// Throws an [ArgumentError] when [name] is blank, or empty once
  /// Smartschool strips its tags: Smartschool refuses such a name, and tells
  /// only that the action was not done.
  static void _checkName(String name) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(
        name,
        'name',
        'is blank: Smartschool refuses an own group without a name',
      );
    }
    if (_asListed(name).isEmpty) {
      throw ArgumentError(
        'The name is empty without its tags, which Smartschool strips: it '
            'refuses an own group without a name.',
        'name',
      );
    }
  }

  /// Throws an [ArgumentError] when a group of [groups] other than [except]
  /// has [name] already, as the list shows it: two such groups could not be
  /// told apart in the compose search of Messages. Names that group by its
  /// ID only.
  static void _checkNameFree(List<MyGroup> groups, String name, {int? except}) {
    final listed = _asListed(name);
    for (final group in groups) {
      if (group.id != except && group.name == listed) {
        throw ArgumentError(
          'Own group ${group.id} has that name already: two own groups with '
              'one name cannot be told apart in the compose search of Messages.',
          'name',
        );
      }
    }
  }

  /// Throws a [SmartschoolMyGroupNotFoundError] when [groups], the list
  /// read before the [write] of own group [groupId], does not have it.
  static void _checkListed(List<MyGroup> groups, int groupId, String write) {
    if (groups.any((group) => group.id == groupId)) return;
    throw SmartschoolMyGroupNotFoundError(
      'The user has no own group $groupId: the list of own groups does not '
      'have it, so the $write was not sent.',
      groupId: groupId,
    );
  }

  /// [text], a name or a description sent in a save, as the list of own
  /// groups shows it after the save: without its tags, which Smartschool
  /// strips when it saves it, and read as the text of HTML, as the list puts
  /// it in its page unescaped (see [MyGroup.name]); trimmed, as [_groups]
  /// reads it.
  static String _asListed(String text) =>
      (html_parser.parseFragment(text).text ?? '').trim();

  /// Loads the form for a new own group, or with [groupId] the edit form of
  /// that group, and returns its page (whose session the save must go out
  /// in), its token, and the name and description it has.
  ///
  /// Throws a [SmartschoolMyGroupNotFoundError] when Smartschool answers the
  /// edit form with the list of own groups (it has no group [groupId]), and
  /// a [SmartschoolMyGroupsError] for another status than `200`, another
  /// page, or a form without its token or its inputs.
  Future<_Form> _form(int? groupId) async {
    final what = groupId == null
        ? 'the form for a new own group'
        : 'the edit form of own group $groupId';
    final page = await _client.getResponse(_formPath(groupId));
    final doc = _document(page, what);
    if (_groupTable(doc) != null) {
      if (groupId != null) {
        throw SmartschoolMyGroupNotFoundError(
          'The user has no own group $groupId: Smartschool answered $what '
          'with the list of own groups.',
          groupId: groupId,
        );
      }
      throw SmartschoolMyGroupsError(
        'Smartschool answered $what with the list of own groups.',
      );
    }
    final form = doc.querySelector('form[name="form"]');
    html_dom.Element? input(String name) =>
        form?.querySelector('input[name="$name"]');
    final token = input('_csrf_token')?.attributes['value'] ?? '';
    final name = input('name');
    final description = input('desc');
    if (token.isEmpty || name == null || description == null) {
      throw SmartschoolMyGroupsError(
        'Smartschool did not answer $what with that form (with its token, '
        'a name and a description).',
      );
    }
    return (
      page: page,
      token: token,
      name: name.attributes['value'] ?? '',
      description: description.attributes['value'] ?? '',
    );
  }

  /// Posts [form], the form for a new own group or (with [groupId]) the edit
  /// form of that group, with [name] and [description], once, in the session
  /// of the form; follows Smartschool's redirect to the list of own groups;
  /// and returns the groups of that list.
  ///
  /// A session that Smartschool refuses for the save is thrown as it is (a
  /// [SmartschoolAuthenticationError]): nothing was saved. Throws a
  /// [SmartschoolMyGroupSaveUnconfirmedError] for any other failure of the
  /// save, an answer that is not the redirect to the list, a list that
  /// cannot be read, and a list whose feedback is not that the action was
  /// done.
  Future<List<MyGroup>> _save(
    _Form form,
    int? groupId, {
    required String name,
    required String description,
    required String what,
  }) async {
    const tryAgain = 'List the groups before trying again.';
    final Response<String> answer;
    try {
      answer = await _client.postFormResponse(
        _formPath(groupId),
        {
          '_csrf_token': form.token,
          'store': '1',
          'name': name,
          'desc': description,
        },
        retryAfterLogin: false,
        sameSessionAs: form.page,
      );
    } on SmartschoolAuthenticationError {
      // Refused before Smartschool handled it, and not sent again: nothing
      // was saved.
      rethrow;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolMyGroupSaveUnconfirmedError(
          '$what was sent, but no answer came in ($e). $tryAgain',
          groupId: groupId,
          cause: e,
        ),
        stackTrace,
      );
    }
    final status = answer.statusCode ?? 0;
    final location = answer.headers.value('location')?.trim() ?? '';
    final target = status >= 300 && status < 400 && location.isNotEmpty
        ? answer.realUri.resolve(location)
        : null;
    if (target == null ||
        target.host != answer.realUri.host ||
        !_isListUri(target)) {
      throw SmartschoolMyGroupSaveUnconfirmedError(
        'Smartschool answered $what with HTTP $status'
        '${target == null ? '' : ' to ${target.path}?${target.query}'}, not '
        'with the redirect to the list of own groups. $tryAgain',
        groupId: groupId,
        statusCode: status,
      );
    }
    final Response<String> page;
    try {
      page = await _client.getResponse('${target.path}?${target.query}');
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolMyGroupSaveUnconfirmedError(
          'Smartschool answered $what with the redirect to the list of own '
          'groups, but the list could not be read ($e). $tryAgain',
          groupId: groupId,
          cause: e,
        ),
        stackTrace,
      );
    }
    final (feedbackType, groups) = _listAfter(page, what, groupId);
    if (feedbackType != null && feedbackType != _feedbackDone) {
      throw SmartschoolMyGroupSaveUnconfirmedError(
        'Smartschool answered $what with the list of own groups and its '
        'feedback that it was not done (type $feedbackType). $tryAgain',
        groupId: groupId,
      );
    }
    return groups;
  }

  /// Whether [uri] is the list of own groups (the target of the redirect
  /// after a save: `function=main`).
  static bool _isListUri(Uri uri) {
    final query = uri.queryParameters;
    final function = query['function'];
    return uri.path == '/' &&
        query['module'] == 'Profile' &&
        query['file'] == 'mygroups' &&
        (function == null || function == 'main') &&
        !query.containsKey('mID');
  }

  /// The `type` of the feedback of [page], the list of own groups that
  /// Smartschool answered [what] with (`null` when it shows none), and its
  /// groups.
  ///
  /// Throws a [SmartschoolMyGroupSaveUnconfirmedError] for another status
  /// than `200`, another page, or a list that cannot be read: [what] went
  /// out already.
  static (int?, List<MyGroup>) _listAfter(
    Response<String> page,
    String what,
    int? groupId,
  ) {
    const tryAgain = 'List the groups before trying again.';
    final html_dom.Document doc;
    final List<MyGroup> groups;
    try {
      doc = _document(page, 'the list of own groups after $what');
      final table = _groupTable(doc);
      if (table == null) {
        throw SmartschoolMyGroupsError(
          'Smartschool did not answer $what with the list of own groups.',
        );
      }
      groups = _groups(table);
    } on SmartschoolMyGroupsError catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolMyGroupSaveUnconfirmedError(
          '${e.message} $tryAgain',
          groupId: groupId,
          statusCode: e.statusCode,
          cause: e,
        ),
        stackTrace,
      );
    }
    return (_feedbackType(doc), groups);
  }

  /// The `type` of Smartschool's feedback on [doc], the message it shows
  /// once after an action (`var msg = "...", type = N` in a script):
  /// [_feedbackDone], [_feedbackNotDone], or `null` when it shows none.
  static int? _feedbackType(html_dom.Document doc) {
    for (final script in doc.querySelectorAll('script')) {
      final match = _feedbackScript.firstMatch(script.text);
      if (match != null) {
        // The message itself (match 1, a JavaScript string) is not used.
        return int.parse(match.group(2)!);
      }
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // The members (#251, #253)
  // -------------------------------------------------------------------------

  /// Loads the members page of the own group [group] and reads the member
  /// picker's selection in its session (#251), and returns that page (whose
  /// session a change of the members must go out in, #253) and the members.
  ///
  /// The picker's request is not retried after logging in again, nor sent
  /// in another session than the page's: when Smartschool refuses its
  /// session, or the client logged in again since the page was loaded, this
  /// loads the page again (logging in first) and reads the picker once
  /// more; when that fails too, it throws a [SmartschoolSessionExpiredError].
  Future<({Response<String> page, List<MyGroupMember> members})> _current(
    MyGroup group,
  ) async {
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
      return (
        page: page,
        members: _join(listed, _selection(answer, group.id), group.id),
      );
    }
  }

  /// The people of [users] as the member picker takes them, each once, in
  /// their order (#253).
  ///
  /// Throws an [ArgumentError] for a user of another school
  /// ([MessageSearchUser.otherSchool] `true`: not tried, #238), one whose
  /// school is not known (`null`), one without a user ID or platform, and
  /// users of different platforms. Names a user by its ID only.
  static List<_Person> _people(Iterable<MessageSearchUser> users) {
    final people = <_Person>[];
    final seen = <int>{};
    int? platform;
    for (final user in users) {
      final id = user.userId;
      if (user.otherSchool == true) {
        throw ArgumentError(
          'User $id is of another school of the school group (otherSchool): '
              'adding a person of another school to an own group was not '
              'tried.',
          'users',
        );
      }
      if (user.otherSchool == null) {
        throw ArgumentError(
          'Whether user $id is of the own school is not known (otherSchool '
              'is null): take people from '
              'MessagesService.searchRecipientsForCompose, or the own account '
              'from MessagesService.getCurrentUserAsRecipient.',
          'users',
        );
      }
      if (id <= 0 || user.ssId <= 0) {
        throw ArgumentError(
          'User $id has no user ID or platform (ssId ${user.ssId}).',
          'users',
        );
      }
      if (platform != null && user.ssId != platform) {
        throw ArgumentError(
          'The users are of different platforms (ssId $platform and '
              '${user.ssId}), though each is of the own school.',
          'users',
        );
      }
      platform = user.ssId;
      if (seen.add(id)) people.add((ssId: user.ssId, userId: id));
    }
    return people;
  }

  /// Changes the members of the own group [group] (#253): to its current
  /// members and [people], or with [replace] to [people] alone. Returns
  /// `false`, without sending the change, when the group has those members
  /// already. See [addMembers].
  Future<bool> _changeMembers(
    MyGroup group,
    List<_Person> people, {
    required bool replace,
  }) async {
    final (:page, :members) = await _current(group);
    final form = _membersForm(page, group.id);
    final others = members.where((member) => !member.isUser).length;
    if (others > 0) {
      throw SmartschoolMyGroupsError(
        'Own group ${group.id} has $others members that are not people (a '
        'class or a group): changing the members of such a group was not '
        'tried. Nothing was sent.',
      );
    }
    final current = {for (final member in members) member.userId: member.ssId};
    for (final person in people) {
      final ssId = current[person.userId];
      if (ssId != null && ssId != person.ssId) {
        throw SmartschoolMyGroupsError(
          'Own group ${group.id} has a member with user ID ${person.userId} '
          'of another platform (ssId $ssId): its members page could not tell '
          'the two apart. Nothing was sent.',
        );
      }
    }
    final selection = <_Person>[
      if (!replace)
        for (final member in members)
          (ssId: member.ssId, userId: member.userId),
      for (final person in people)
        if (replace || !current.containsKey(person.userId)) person,
    ];
    final next = {for (final person in selection) person.userId};
    if (next.length == current.length && next.every(current.containsKey)) {
      return false;
    }
    await _sendSelection(group.id, selection, page);
    await _saveMembers(group.id, form, page, next);
    return true;
  }

  /// The members form of [page], the members page of own group [groupId]:
  /// its token (`_csrf_token`), `store` and `mID`, as the page has them.
  ///
  /// Throws a [SmartschoolMyGroupsError] for a form without them.
  static _MembersForm _membersForm(Response<String> page, int groupId) {
    final form = html_parser
        .parse(page.data ?? '')
        .querySelector('form[name="$_membersFormName"]');
    String? value(String name) =>
        form?.querySelector('input[name="$name"]')?.attributes['value'];
    final token = value('_csrf_token') ?? '';
    final store = value('store');
    final mId = value('mID');
    if (token.isEmpty || store == null || mId == null) {
      throw SmartschoolMyGroupsError(
        'The members page of own group $groupId has no members form with its '
        'token, store and mID. Nothing was sent.',
      );
    }
    return (token: token, store: store, mId: mId);
  }

  /// Sends the member picker [selection] as the new selection of own group
  /// [groupId] (`userSelect` / `confirm Selection`), once, in the session of
  /// [page], the group's members page (#253). It saves nothing.
  ///
  /// Throws a [SmartschoolMyGroupsError] for an answer that does not close
  /// the picker on the members form (`closeUsc`), what the
  /// picker's read throws for an answer that is not XML, and a
  /// [SmartschoolSessionExpiredError] when Smartschool refused the session
  /// or the client logged in again since [page] was loaded.
  Future<void> _sendSelection(
    int groupId,
    List<_Person> selection,
    Response<String> page,
  ) async {
    final what =
        'the member picker\'s new selection of own group $groupId '
        '($_confirmSelection)';
    // The values are numbers: the CDATA of the param cannot hold `]]>`.
    final items = StringBuffer('<items>');
    for (final person in selection) {
      items.write(
        '<item><type>U</type><ssId>${person.ssId}</ssId>'
        '<id>${person.userId}</id></item>',
      );
    }
    items.write('</items>');
    final answer = await _client.postFormResponse(
      _pickerPath,
      {
        'command': XmlInterface.buildCommand(
          _pickerSubsystem,
          _confirmSelection,
          {'usc': _usc(groupId), 'xml': '$items'},
        ),
      },
      retryAfterLogin: false,
      sameSessionAs: page,
    );
    _checkPickerStatus(answer, 'the sending of $what');
    readXmlAnswer(
      answer,
      action: _confirmSelection,
      parse: (body) {
        final closes = [
          for (final action in _pickerActions(body, 'the sending of $what'))
            if (action.getElement('command')?.innerText.trim() ==
                _confirmSelectionAnswer)
              action,
        ];
        final form = closes.length == 1
            ? closes.single
                  .getElement('data')
                  ?.getElement('close')
                  ?.getElement('formname')
                  ?.innerText
                  .trim()
            : null;
        if (form != _membersFormName) {
          throw SmartschoolMyGroupsError(
            'The member picker did not answer $what by closing on the members '
            'form ("$_confirmSelectionAnswer" with the form name '
            '"$_membersFormName"). Nothing was saved.',
          );
        }
      },
    );
  }

  /// Posts [form], the members form of own group [groupId], once, in the
  /// session of [page], the members page it is from (#253): Smartschool
  /// saves the picker's selection then, and answers with the members page.
  /// Throws a [SmartschoolMyGroupSaveUnconfirmedError] unless that page
  /// lists exactly the members [expected].
  ///
  /// A session that Smartschool refuses for it is thrown as it is (a
  /// [SmartschoolAuthenticationError]): nothing was saved.
  Future<void> _saveMembers(
    int groupId,
    _MembersForm form,
    Response<String> page,
    Set<int> expected,
  ) async {
    final what = 'the save of the members of own group $groupId';
    const tryAgain = 'Read the members before trying again.';
    final Response<String> answer;
    try {
      answer = await _client.postFormResponse(
        _membersPath(groupId),
        {'_csrf_token': form.token, 'store': form.store, 'mID': form.mId},
        retryAfterLogin: false,
        sameSessionAs: page,
      );
    } on SmartschoolAuthenticationError {
      // Refused before Smartschool handled it, and not sent again: nothing
      // was saved.
      rethrow;
    } on Exception catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolMyGroupSaveUnconfirmedError(
          '$what was sent, but no answer came in ($e). $tryAgain',
          groupId: groupId,
          cause: e,
        ),
        stackTrace,
      );
    }
    final List<int> listed;
    try {
      listed = _memberIds(answer, groupId);
    } on SmartschoolMyGroupsError catch (e, stackTrace) {
      Error.throwWithStackTrace(
        SmartschoolMyGroupSaveUnconfirmedError(
          'After $what: ${e.message} $tryAgain',
          groupId: groupId,
          statusCode: e.statusCode,
          cause: e,
        ),
        stackTrace,
      );
    }
    final saved = listed.toSet();
    if (saved.length != listed.length ||
        saved.length != expected.length ||
        !saved.containsAll(expected)) {
      throw SmartschoolMyGroupSaveUnconfirmedError(
        'Smartschool answered $what with the members page, but it does not '
        'list the members sent: it lists ${listed.length}, '
        '${listed.where(expected.contains).length} of the ${expected.length} '
        'sent. $tryAgain',
        groupId: groupId,
      );
    }
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
    _checkPickerStatus(answer, 'the read of $what');
    return readXmlAnswer(
      answer,
      action: _selectedItems,
      parse: (body) => _parseSelection(body, what),
    );
  }

  /// Throws a [SmartschoolMyGroupsError] when the picker's [answer] to
  /// [request] has another status than `200`, a redirect included (such as
  /// its `302` to the start page for a request without `X-Requested-With`).
  static void _checkPickerStatus(Response<String> answer, String request) {
    final status = answer.statusCode ?? 0;
    if (status >= 300 && status < 400) {
      final location = answer.headers.value('location');
      throw SmartschoolMyGroupsError(
        'Smartschool redirected $request to '
        '${location ?? 'another page'} (HTTP $status).',
        statusCode: status,
      );
    }
    if (status != 200) {
      throw SmartschoolMyGroupsError(
        'Smartschool answered $request with HTTP $status.',
        statusCode: status,
      );
    }
  }

  /// The actions of [body], the XML of the picker's answer to [request].
  ///
  /// Throws a [FormatException] for malformed XML (which `readXmlAnswer`
  /// reports), and a [SmartschoolMyGroupsError] for an answer that is not
  /// `ok`.
  static List<XmlElement> _pickerActions(String body, String request) {
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
        'The member picker answered $request with status '
        '${status == null ? '(none)' : '"$status"'}.',
      );
    }
    return [...?response!.getElement('actions')?.findElements('action')];
  }

  /// The members of [body], the XML of the picker's answer to the read of
  /// [what].
  ///
  /// Throws a [FormatException] for malformed XML (which `readXmlAnswer`
  /// reports), and a [SmartschoolMyGroupsError] for an answer that is not
  /// `ok`, that holds no selection, or an item without its type, ID or
  /// platform.
  static List<MyGroupMember> _parseSelection(String body, String what) {
    final selections = [
      for (final action in _pickerActions(body, 'the read of $what'))
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

/// The form for a new own group, or the edit form of one (#252): its page,
/// whose session the save goes out in; its token (`_csrf_token`); and the
/// name and description it has (empty for a new group).
typedef _Form = ({
  Response<String> page,
  String token,
  String name,
  String description,
});

/// A person as the member picker takes one in a selection (#253): the
/// platform and the user ID of an `<item>` of type `U`.
typedef _Person = ({int ssId, int userId});

/// The members form of a group's members page (#253), which a change of the
/// members posts: its token (`_csrf_token`), `store` and `mID`, as the page
/// has them.
typedef _MembersForm = ({String token, String store, String mId});
