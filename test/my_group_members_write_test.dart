// Tests for issue #253: the changes of the members of an own mail group
// ("Mijn groepen", `/?module=Profile&file=mygroups`) by `MyGroupsService`:
// addMembers, setMembers, clearMembers and removeMember, against a fake
// Smartschool.
//
// The fake keeps the members of its groups and a PHP session, and answers
// like Smartschool (seen live on 2026-11-16, see the issue): loading a
// group's members page (`function=users&mID={id}`) sets the member picker's
// selection of the group (`usc` `mygroups_{id}`) in the session to the
// current members, and hands out a new token in the page's form; the
// picker's `get Items Selected` answers that selection; its `confirm
// Selection` replaces it with the selection sent and answers `closeUsc`,
// saving nothing; a POST of the members form with that token saves the
// selection as the members (replacing them) and answers the members page,
// a new one, with them; `POST /Profile/Mygroups/deleteUser` removes one
// member and answers `true`, also for someone who is not a member. The
// picker answers a request without `X-Requested-With` with `302` to the
// start page. Pages and answers in the shape of the hand-written fixtures
// of get/profile/mygroups/ and post/userselect/ (built by
// test/support/my_group_pages.dart), with made-up people of
// test/fixtures/lvs/FAKES.md: the members of a real group are mostly
// pupils.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/my_group_pages.dart';
import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';

String _fixture(String name) =>
    File('test/fixtures/smartschool/requests/$name').readAsStringSync();

final _list = _fixture('get/profile/mygroups/list.html');
final _listNotFound = _fixture('get/profile/mygroups/list-not-found.html');
final _composeForm = _fixture('get/composemessage/new-message.html');

/// The groups of list.html: 900501 with the three people of members.html,
/// 900502 without members.
const _withMembers = MyGroup(id: 900501, name: 'Testgroep 5');
const _withoutMembers = MyGroup(id: 900502, name: 'testgroep zorg');

/// People of the own school (platform 4069) who are no member of a group.
const _piet = FakeMyGroupPerson(900011, 'Peeters Piet');
const _celine = FakeMyGroupPerson(900012, 'Dupré Céline');

/// A person of another school of the school group (platform 4070).
const _koen = FakeMyGroupPerson(
  900021,
  'Wouters Koen',
  ssId: 4070,
  schoolName: 'Springfield Academy 2',
);

/// [person] as the compose search of Messages finds them: of the own school
/// unless [otherSchool] says otherwise.
MessageSearchUser _user(
  FakeMyGroupPerson person, {
  bool? otherSchool = false,
}) => MessageSearchUser(
  userId: person.userId,
  displayName: person.name,
  ssId: person.ssId,
  schoolName: person.schoolName,
  otherSchool: otherSchool,
);

/// The requests, as the fake logs them.
String _page(int id) => 'GET members $id';
String _read(int id) => 'POST picker get Items Selected mygroups_$id';
String _confirm(int id) => 'POST picker confirm Selection mygroups_$id';
String _save(int id) => 'POST members $id';
const _remove = 'POST deleteUser';

/// The four requests of a change of the members of group [id].
List<String> _change(int id) => [_page(id), _read(id), _confirm(id), _save(id)];

/// The names of the fake people: an error must not quote them.
const _names = ['Janssens', 'Peeters', 'Dupont', 'Dupré', 'Wouters'];

/// An answer of the fake.
ResponseBody _answer(
  String body, {
  int status = 200,
  String contentType = 'text/html; charset=UTF-8',
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [contentType],
    ...headers,
  },
);

ResponseBody _xml(String body) =>
    _answer(body, contentType: 'text/xml; charset=UTF-8');

/// The connection dropping after a request went out.
Object _dropped(RequestOptions options) => DioException.connectionError(
  requestOptions: options,
  reason: 'Connection closed before full header was received',
  error: const SocketException('Connection reset by peer'),
);

/// A Smartschool with own groups and their members, and a session with the
/// member picker's selections, which it changes as Smartschool does.
class _Smartschool implements HttpClientAdapter {
  /// The members of each own group, by its ID.
  final Map<int, List<FakeMyGroupPerson>> members = {
    900501: myGroupPeopleOfMembersFixture(),
    900502: [],
  };

  /// Everyone a selection can name, by user ID.
  final Map<int, FakeMyGroupPerson> people = {
    for (final person in [
      ...myGroupPeopleOfMembersFixture(),
      _piet,
      _celine,
      _koen,
    ])
      person.userId: person,
  };

  /// The picker's selections in the session, by `usc`.
  final Map<String, List<FakeMyGroupPerson>> selections = {};

  /// The token of the members page loaded last, and how many were handed
  /// out.
  String? _token;
  int _tokens = 0;

  /// How many members pages were asked for.
  int _loads = 0;

  /// The token that the members pages hand out instead of a new one.
  String? pageToken;

  /// Every request: [_page], [_read], [_confirm], [_save], [_remove], or
  /// `METHOD path?query` for any other.
  final List<String> log = [];

  /// The picker's requests, the posts of the members form and the removals,
  /// as they went out.
  final List<RequestOptions> pickerRequests = [];
  final List<RequestOptions> saves = [];
  final List<RequestOptions> removals = [];

  /// Answers to the [load]th members page (from 1) instead of the page, when
  /// it gives one.
  ResponseBody? Function(int load)? pageAnswer;

  /// Answers to the picker's `get Items Selected` instead of the selection.
  ResponseBody Function()? selectionAnswer;

  /// Answers to the picker's `confirm Selection` instead of handling it.
  ResponseBody Function()? confirmAnswer;

  /// Answers to a post of the members form instead of handling it.
  ResponseBody Function()? saveAnswer;

  /// Whether a post of the members form saves nothing.
  bool ignoreSaves = false;

  /// Whether the connection drops once a post of the members form was
  /// handled.
  bool dropAfterSave = false;

  /// Answers to a removal instead of handling it.
  ResponseBody Function()? removeAnswer;

  /// Whether a removal removes no one (but still answers `true`).
  bool ignoreRemovals = false;

  /// Whether the connection drops once a removal was handled.
  bool dropAfterRemoval = false;

  /// The compose form of Messages, and the answer to its recipient search.
  String? composeForm;
  String? searchAnswer;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // Lets other requests of the test in between, as the network would.
    await Future<void>.delayed(Duration.zero);
    final uri = options.uri;
    final query = uri.queryParameters;
    final post = options.method == 'POST';

    if (post &&
        query['module'] == 'Userselect' &&
        query['file'] == 'dispatcher') {
      return _picker(options);
    }
    if (post && uri.path == '/Profile/Mygroups/deleteUser') {
      return _removal(options);
    }
    if (query['module'] == 'Profile' &&
        query['file'] == 'mygroups' &&
        query['function'] == 'users') {
      final id = int.parse(query['mID']!);
      if (!post) {
        log.add(_page(id));
        final override = pageAnswer?.call(++_loads);
        if (override != null) return override;
        return _membersPage(id);
      }
      log.add(_save(id));
      saves.add(options);
      final override = saveAnswer;
      if (override != null) return override();
      _store(id, options.data as Map);
      if (dropAfterSave) throw _dropped(options);
      return _membersPage(id);
    }
    if (!post && query['module'] == 'Profile' && query['file'] == 'mygroups') {
      log.add('GET list');
      return _answer(_list);
    }
    if (!post &&
        query['module'] == 'Messages' &&
        query['file'] == 'composeMessage' &&
        composeForm != null) {
      log.add('GET compose');
      return _answer(composeForm!);
    }
    if (post &&
        query['module'] == 'Messages' &&
        query['file'] == 'searchUsers' &&
        !query.containsKey('function') &&
        searchAnswer != null) {
      log.add('POST search');
      return _xml(searchAnswer!);
    }
    log.add('${options.method} ${uri.path}?${uri.query}');
    return _answer('<html><body>Not here</body></html>', status: 404);
  }

  /// The members page of group [id], which sets the picker's selection of
  /// the group to its members and hands out a new token; the list with
  /// "not done" for a group it does not have.
  ResponseBody _membersPage(int id) {
    final current = members[id];
    if (current == null) return _answer(_listNotFound);
    final token = _token = pageToken ?? 'made-up-token-${++_tokens}';
    selections['mygroups_$id'] = [...current];
    return _answer(myGroupMembersPage(id, current, token: token));
  }

  /// Saves the picker's selection as the members of group [id], for the
  /// form [fields] with the token of the last members page.
  void _store(int id, Map<dynamic, dynamic> fields) {
    if (ignoreSaves ||
        fields['_csrf_token'] != _token ||
        fields['store'] != '1' ||
        !members.containsKey(id)) {
      return;
    }
    members[id] = [...?selections['mygroups_$id']];
  }

  ResponseBody _picker(RequestOptions options) {
    pickerRequests.add(options);
    final (:action, :params) = myGroupPickerCommand(
      (options.data as Map)['command'],
    );
    final usc = params['usc']!;
    log.add('POST picker $action $usc');
    if (options.headers['X-Requested-With'] != 'XMLHttpRequest') {
      return _answer(
        '',
        status: 302,
        headers: {
          'location': ['/?module=Homepage'],
        },
      );
    }
    if (action == 'confirm Selection') {
      final override = confirmAnswer;
      if (override != null) return override();
      selections[usc] = [
        for (final item in myGroupSelectionSent(params['xml']!))
          if (item.type == 'U' && people[item.userId]?.ssId == item.ssId)
            people[item.userId]!,
      ];
      return _xml(myGroupConfirmAnswer);
    }
    final override = selectionAnswer;
    if (override != null) return override();
    return _xml(myGroupSelectionAnswer(selections[usc] ?? const []));
  }

  ResponseBody _removal(RequestOptions options) {
    log.add(_remove);
    removals.add(options);
    final override = removeAnswer;
    if (override != null) return override();
    final fields = options.data as Map;
    final group = int.parse('${fields['groupID']}');
    final user = int.parse('${fields['userID']}');
    if (!ignoreRemovals) {
      members[group]?.removeWhere((person) => person.userId == user);
    }
    if (dropAfterRemoval) throw _dropped(options);
    return _answer('true', contentType: 'application/json');
  }

  @override
  void close({bool force = false}) {}
}

class _Credentials extends Credentials {
  @override
  String get username => 'user';
  @override
  String get password => 'pass';
  @override
  String get mainUrl => _host;
  @override
  String? get mfa => 'JBSWY3DPEHPK3PXP';
}

/// The fields of the form [options], as they went out.
Map<String, String> _fields(RequestOptions options) => {
  for (final MapEntry(:key, :value) in (options.data as Map).entries)
    '$key': '$value',
};

/// The selection that the `confirm Selection` [options] sent: the user IDs,
/// in its order.
List<int> _sent(RequestOptions options) => [
  for (final item in myGroupSelectionSent(
    myGroupPickerCommand((options.data as Map)['command']).params['xml']!,
  ))
    item.userId,
];

/// The `confirm Selection` requests of [server].
List<RequestOptions> _confirms(_Smartschool server) => [
  for (final request in server.pickerRequests)
    if (myGroupPickerCommand((request.data as Map)['command']).action ==
        'confirm Selection')
      request,
];

/// A [SmartschoolMyGroupSaveUnconfirmedError] of group [groupId] with
/// [statusCode], whose message holds every one of [parts] and quotes no
/// name of a fake person.
Matcher _unconfirmed(
  List<String> parts, {
  required int groupId,
  int? statusCode,
  Object? cause = isNull,
}) => isA<SmartschoolMyGroupSaveUnconfirmedError>()
    .having((e) => e.groupId, 'groupId', groupId)
    .having((e) => e.statusCode, 'statusCode', statusCode)
    .having((e) => e.cause, 'cause', cause)
    .having(
      (e) => e.message,
      'message',
      allOf([
        for (final p in parts) contains(p),
        for (final name in _names) isNot(contains(name)),
      ]),
    );

/// A [SmartschoolMyGroupsError] (not its subtype), whose message holds every
/// one of [parts] and quotes no name of a fake person.
Matcher _myGroupsError(List<String> parts, {int? statusCode}) => allOf(
  isA<SmartschoolMyGroupsError>()
      .having((e) => e.statusCode, 'statusCode', statusCode)
      .having(
        (e) => e.message,
        'message',
        allOf([
          for (final p in parts) contains(p),
          for (final name in _names) isNot(contains(name)),
        ]),
      ),
  isNot(isA<SmartschoolMyGroupNotFoundError>()),
);

/// An [ArgumentError] whose message holds every one of [parts] and quotes
/// no name of a fake person.
Matcher _argumentError(List<String> parts) => isA<ArgumentError>().having(
  (e) => '${e.message}',
  'message',
  allOf([
    for (final p in parts) contains(p),
    for (final name in _names) isNot(contains(name)),
  ]),
);

/// A compose search's answer that finds the people [found].
String _searchUsers(List<FakeMyGroupPerson> found) =>
    '<results><type>0</type><ssID>4069</ssID>'
    '<parentNodeId>insertSearchFieldContainer_0_0</parentNodeId><groups />'
    '<users>${[for (final p in found) '<user><userID>${p.userId}</userID><text>${p.name}</text><value>${p.name}</value><selectable>on</selectable><ssID>${p.ssId}</ssID><ssPlName /><userLT>0</userLT><coaccountname /><classname /><schoolname>${p.schoolName}</schoolname><picture /></user>'].join()}</users>'
    '<sgrdetails><sgrselect>1</sgrselect><dosgrsearch>0</dosgrsearch>'
    '</sgrdetails></results>';

void main() {
  forbidRealNetwork();

  late _Smartschool server;
  late SmartschoolClient client;
  late MyGroupsService groups;

  Future<void> serve(_Smartschool smartschool) async {
    server = smartschool;
    client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    client.dio.httpClientAdapter = server;
    groups = MyGroupsService(client);
  }

  /// The user IDs of the members of [group], as [MyGroupsService.members]
  /// reads them; clears the log.
  Future<List<int>> memberIds(MyGroup group) async {
    final ids = [for (final m in await groups.members(group)) m.userId];
    server.log.clear();
    return ids;
  }

  test('a person the compose search finds is added and removed again; one '
      'of another school is refused (the flow of the issue)', () async {
    await serve(
      _Smartschool()
        ..composeForm = _composeForm
        ..searchAnswer = _searchUsers([_piet, _koen]),
    );

    final (users, _) = await MessagesService(
      client,
    ).searchRecipientsForCompose('Pe');
    final piet = users.firstWhere((u) => u.userId == _piet.userId);
    final koen = users.firstWhere((u) => u.userId == _koen.userId);
    expect(piet.otherSchool, isFalse);
    expect(koen.otherSchool, isTrue);

    expect(await groups.addMembers(_withMembers, [piet]), isTrue);
    final now = await groups.members(_withMembers);
    // Sorted by name, as the members page lists them.
    expect(now.map((m) => m.userId), [900003, 900001, 900002, 900011]);
    final added = now.last;
    expect(added.ssId, 4069);
    expect(added.isUser, isTrue);

    expect(await groups.removeMember(_withMembers, added), isTrue);
    expect(await memberIds(_withMembers), [900003, 900001, 900002]);

    await expectLater(
      groups.addMembers(_withMembers, [koen]),
      throwsA(_argumentError(['900021', 'another school'])),
    );
    expect(server.log, isEmpty);
  });

  group('addMembers', () {
    test('loads the members page, reads the picker\'s selection, sends the '
        'current members and the new one as the new selection, and posts the '
        'members form with the page\'s token, in that order and nothing in '
        'between; the members page answered lists them', () async {
      await serve(_Smartschool());

      expect(await groups.addMembers(_withMembers, [_user(_piet)]), isTrue);

      expect(server.log, _change(900501));
      final confirm = _confirms(server).single;
      expect(confirm.uri.queryParameters, {
        'module': 'Userselect',
        'file': 'dispatcher',
      });
      expect(confirm.headers['X-Requested-With'], 'XMLHttpRequest');
      expect(confirm.contentType, Headers.formUrlEncodedContentType);
      expect((confirm.data as Map).keys, ['command']);
      final command = myGroupPickerCommand((confirm.data as Map)['command']);
      expect(command.params, {
        'usc': 'mygroups_900501',
        // The current members in the page's order, then the new one.
        'xml':
            '<items>'
            '<item><type>U</type><ssId>4069</ssId><id>900003</id></item>'
            '<item><type>U</type><ssId>4069</ssId><id>900001</id></item>'
            '<item><type>U</type><ssId>4069</ssId><id>900002</id></item>'
            '<item><type>U</type><ssId>4069</ssId><id>900011</id></item>'
            '</items>',
      });
      final save = server.saves.single;
      expect(save.uri.path, '/');
      expect(save.uri.queryParameters, {
        'module': 'Profile',
        'file': 'mygroups',
        'function': 'users',
        'mID': '900501',
      });
      expect(save.contentType, Headers.formUrlEncodedContentType);
      expect(_fields(save), {
        '_csrf_token': 'made-up-token-1',
        'store': '1',
        'mID': '',
      });
      expect(server.members[900501]!.map((p) => p.userId), [
        900003,
        900001,
        900002,
        900011,
      ]);
    });

    test('to a group without members: the new people alone, each once, in '
        'their order', () async {
      await serve(_Smartschool());

      expect(
        await groups.addMembers(_withoutMembers, [
          _user(_piet),
          _user(_celine),
          _user(_piet),
        ]),
        isTrue,
      );

      expect(server.log, _change(900502));
      expect(_sent(_confirms(server).single), [900011, 900012]);
      expect(await memberIds(_withoutMembers), [900012, 900011]);
    });

    test('people who are members already are not sent twice; when all are, '
        'it returns false and sends no change', () async {
      await serve(_Smartschool());
      final jan = _user(myGroupPeopleOfMembersFixture().first);

      expect(
        await groups.addMembers(_withMembers, [jan, _user(_piet)]),
        isTrue,
      );
      expect(_sent(_confirms(server).single), [900003, 900001, 900002, 900011]);

      server.log.clear();
      expect(
        await groups.addMembers(_withMembers, [jan, _user(_piet)]),
        isFalse,
      );
      expect(server.log, [_page(900501), _read(900501)]);
      expect(server.saves, hasLength(1));
    });

    test('no people, a person of another school, one whose school is not '
        'known, one without an ID or platform, or people of two platforms: an '
        'ArgumentError that names no one; nothing is sent', () async {
      await serve(_Smartschool());

      for (final (users, parts) in [
        (<MessageSearchUser>[], ['at least one person']),
        (
          [_user(_piet), _user(_koen, otherSchool: true)],
          ['900021', 'another school'],
        ),
        ([_user(_piet, otherSchool: null)], ['900011', 'not known']),
        (
          [
            const MessageSearchUser(
              userId: 0,
              displayName: 'Peeters Piet',
              ssId: 4069,
              otherSchool: false,
            ),
          ],
          ['no user ID or platform'],
        ),
        ([_user(_piet), _user(_koen)], ['different platforms', '4069', '4070']),
      ]) {
        await expectLater(
          groups.addMembers(_withMembers, users),
          throwsA(_argumentError(parts)),
          reason: '$parts',
        );
      }
      expect(server.log, isEmpty);
    });

    test('a group the user does not have is a '
        'SmartschoolMyGroupNotFoundError; no change is sent', () async {
      await serve(_Smartschool());

      await expectLater(
        groups.addMembers(const MyGroup(id: 900599, name: 'weg'), [
          _user(_piet),
        ]),
        throwsA(
          isA<SmartschoolMyGroupNotFoundError>().having(
            (e) => e.groupId,
            'groupId',
            900599,
          ),
        ),
      );
      expect(server.log, [_page(900599)]);
    });

    test('a group with a member that is not a person (a class): a '
        'SmartschoolMyGroupsError; no change is sent', () async {
      await serve(_Smartschool());
      server.selectionAnswer = () => _xml(
        myGroupSelectionAnswer(
          myGroupPeopleOfMembersFixture(),
        ).replaceFirst('<type>U</type><id>900002', '<type>K</type><id>900002'),
      );

      await expectLater(
        groups.addMembers(_withMembers, [_user(_piet)]),
        throwsA(_myGroupsError(['900501', 'not people', 'Nothing was sent'])),
      );
      expect(server.log, [_page(900501), _read(900501)]);
    });

    test('a member with the user ID of a person to add on another platform: '
        'a SmartschoolMyGroupsError; no change is sent', () async {
      await serve(_Smartschool());
      server.members[900501]!.add(
        const FakeMyGroupPerson(900011, 'Peeters Piet', ssId: 4070),
      );

      await expectLater(
        groups.addMembers(_withMembers, [_user(_piet)]),
        throwsA(_myGroupsError(['900011', 'another platform (ssId 4070)'])),
      );
      expect(server.log, [_page(900501), _read(900501)]);
    });

    test('a members page without its form\'s token: a '
        'SmartschoolMyGroupsError; no change is sent', () async {
      await serve(_Smartschool());
      server.pageToken = '';

      await expectLater(
        groups.addMembers(_withMembers, [_user(_piet)]),
        throwsA(_myGroupsError(['no members form with its token'])),
      );
      expect(server.log, [_page(900501), _read(900501)]);
    });

    test('a picker answer to the new selection that does not close on the '
        'members form (another command or form, not ok, a redirect, another '
        'status) is a SmartschoolMyGroupsError; the form is not posted, and '
        'nothing was saved', () async {
      const envelope =
          '<server><response><status>ok</status><actions><action>'
          '<subsystem>userselect</subsystem>%s</action></actions>'
          '</response></server>';
      for (final (answer, parts, status) in [
        (
          () => _xml(
            envelope.replaceFirst(
              '%s',
              '<command>handle selected items</command><data><items />'
                  '</data>',
            ),
          ),
          ['closing on the members form'],
          null,
        ),
        (
          () => _xml(
            myGroupConfirmAnswer.replaceFirst(
              '<formname>form</formname>',
              '<formname>other</formname>',
            ),
          ),
          ['closing on the members form'],
          null,
        ),
        (
          () => _xml(
            myGroupConfirmAnswer.replaceFirst(
              '<status>ok</status>',
              '<status>error</status>',
            ),
          ),
          ['status "error"'],
          null,
        ),
        (
          () => _answer(
            '',
            status: 302,
            headers: {
              'location': ['/?module=Homepage'],
            },
          ),
          ['redirected', '/?module=Homepage'],
          302,
        ),
        (() => _answer('Oeps', status: 500), ['HTTP 500'], 500),
      ]) {
        await serve(_Smartschool()..confirmAnswer = answer);

        await expectLater(
          groups.addMembers(_withMembers, [_user(_piet)]),
          throwsA(_myGroupsError(parts, statusCode: status)),
          reason: '$parts',
        );
        expect(server.log, [_page(900501), _read(900501), _confirm(900501)]);
        expect(server.members[900501], hasLength(3));
      }
    });

    test('an HTML page or malformed XML from the picker is a '
        'SmartschoolUnexpectedPageError or a SmartschoolParsingError; the '
        'form is not posted', () async {
      await serve(
        _Smartschool()
          ..confirmAnswer = () =>
              _answer('<html><body>Startpagina</body></html>'),
      );
      await expectLater(
        groups.addMembers(_withMembers, [_user(_piet)]),
        throwsA(isA<SmartschoolUnexpectedPageError>()),
      );
      expect(server.saves, isEmpty);

      await serve(
        _Smartschool()..confirmAnswer = () => _xml('<server><response>'),
      );
      await expectLater(
        groups.addMembers(_withMembers, [_user(_piet)]),
        throwsA(isA<SmartschoolParsingError>()),
      );
      expect(server.saves, isEmpty);
    });

    test('a session Smartschool refuses for the new selection is a '
        'SmartschoolSessionExpiredError: it is not sent again, nor is the '
        'form posted', () async {
      await serve(
        _Smartschool()..confirmAnswer = () => _answer('', status: 401),
      );

      await expectLater(
        groups.addMembers(_withMembers, [_user(_piet)]),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
      expect(server.log, [_page(900501), _read(900501), _confirm(900501)]);
      expect(server.members[900501], hasLength(3));
    });

    test('a members page answered after the post without the members sent '
        '(Smartschool saved nothing) is a '
        'SmartschoolMyGroupSaveUnconfirmedError with the group; the form is '
        'posted once', () async {
      await serve(_Smartschool()..ignoreSaves = true);

      await expectLater(
        groups.addMembers(_withMembers, [_user(_piet)]),
        throwsA(
          _unconfirmed([
            'does not list the members sent',
            'it lists 3, 3 of the 4 sent',
          ], groupId: 900501),
        ),
      );
      expect(server.log, _change(900501));
    });

    test('a post answered with another status or another page (the list: the '
        'group is gone) is unconfirmed, with its status and the read\'s '
        'error as its cause', () async {
      await serve(
        _Smartschool()..saveAnswer = () => _answer('Oeps', status: 500),
      );
      await expectLater(
        groups.addMembers(_withMembers, [_user(_piet)]),
        throwsA(
          _unconfirmed(
            ['HTTP 500'],
            groupId: 900501,
            statusCode: 500,
            cause: isA<SmartschoolMyGroupsError>(),
          ),
        ),
      );

      await serve(_Smartschool()..saveAnswer = () => _answer(_listNotFound));
      await expectLater(
        groups.addMembers(_withMembers, [_user(_piet)]),
        throwsA(
          _unconfirmed(
            ['no own group 900501'],
            groupId: 900501,
            cause: isA<SmartschoolMyGroupNotFoundError>(),
          ),
        ),
      );
      expect(server.saves, hasLength(1));
    });

    test('the connection dropping after the post went out is unconfirmed, '
        'with the connection error as its cause; not sent again', () async {
      await serve(_Smartschool()..dropAfterSave = true);

      await expectLater(
        groups.addMembers(_withMembers, [_user(_piet)]),
        throwsA(
          _unconfirmed(
            ['no answer came in'],
            groupId: 900501,
            cause: isA<SmartschoolConnectionError>(),
          ),
        ),
      );
      expect(server.saves, hasLength(1));
      // It was saved all the same: reading the members tells.
      server.dropAfterSave = false;
      expect(await memberIds(_withMembers), contains(900011));
    });

    test('a session Smartschool refuses for the post is a '
        'SmartschoolSessionExpiredError, not an unconfirmed change: it is not '
        'sent again', () async {
      await serve(_Smartschool()..saveAnswer = () => _answer('', status: 401));

      await expectLater(
        groups.addMembers(_withMembers, [_user(_piet)]),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
      expect(server.log, _change(900501));
    });

    test('a change and a read of the members at once, through two services '
        'of one client, take turns: no load of the members page comes '
        'between the steps of the change, so the post saves the new '
        'selection', () async {
      await serve(_Smartschool());
      final other = MyGroupsService(client);

      final (changed, read) = await (
        groups.addMembers(_withMembers, [_user(_piet)]),
        other.members(_withMembers),
      ).wait;

      expect(changed, isTrue);
      expect(read.map((m) => m.userId), [900003, 900001, 900002, 900011]);
      expect(server.log, [..._change(900501), _page(900501), _read(900501)]);
    });

    test('the fake resets the selection when the members page is loaded '
        'between the steps, as Smartschool does: then the post saves the old '
        'members, and the change is unconfirmed', () async {
      // What the turns above prevent, done by hand: a load of the page
      // between the new selection and the post.
      await serve(_Smartschool());
      server.confirmAnswer = () {
        server.selections['mygroups_900501'] = [
          ...server.members[900501]!,
          _piet,
        ];
        return _xml(myGroupConfirmAnswer);
      };
      server.saveAnswer = () {
        server.selections['mygroups_900501'] = [...server.members[900501]!];
        server.members[900501] = [...server.selections['mygroups_900501']!];
        return _answer(
          myGroupMembersPage(900501, server.members[900501]!, token: 't'),
        );
      };

      await expectLater(
        groups.addMembers(_withMembers, [_user(_piet)]),
        throwsA(_unconfirmed(['3 of the 4 sent'], groupId: 900501)),
      );
    });
  });

  group('setMembers', () {
    test('sends the people alone as the new selection: they replace the '
        'members', () async {
      await serve(_Smartschool());
      final marie = _user(myGroupPeopleOfMembersFixture()[1]);

      expect(
        await groups.setMembers(_withMembers, [_user(_piet), marie]),
        isTrue,
      );

      expect(server.log, _change(900501));
      expect(_sent(_confirms(server).single), [900011, 900002]);
      expect(await memberIds(_withMembers), [900002, 900011]);
    });

    test('the members the group has already, in any order: false, no change '
        'is sent', () async {
      await serve(_Smartschool());
      final fixture = myGroupPeopleOfMembersFixture();

      expect(
        await groups.setMembers(_withMembers, [
          for (final person in fixture.reversed) _user(person),
        ]),
        isFalse,
      );
      expect(server.log, [_page(900501), _read(900501)]);
    });

    test('no people is an ArgumentError that points to clearMembers; nothing '
        'is sent', () async {
      await serve(_Smartschool());

      await expectLater(
        groups.setMembers(_withMembers, const []),
        throwsA(_argumentError(['clearMembers'])),
      );
      await expectLater(
        groups.setMembers(_withMembers, [_user(_koen, otherSchool: true)]),
        throwsA(_argumentError(['another school'])),
      );
      expect(server.log, isEmpty);
    });

    test('a page after the post without exactly those members is '
        'unconfirmed', () async {
      await serve(_Smartschool()..ignoreSaves = true);

      await expectLater(
        groups.setMembers(_withMembers, [_user(_piet)]),
        throwsA(_unconfirmed(['it lists 3, 0 of the 1 sent'], groupId: 900501)),
      );
    });
  });

  group('clearMembers', () {
    test('sends an empty selection (<items></items>) and posts the form: the '
        'group has no members', () async {
      await serve(_Smartschool());

      expect(await groups.clearMembers(_withMembers), isTrue);

      expect(server.log, _change(900501));
      final command = myGroupPickerCommand(
        (_confirms(server).single.data as Map)['command'],
      );
      expect(command.params['xml'], '<items></items>');
      expect(await memberIds(_withMembers), isEmpty);
    });

    test('a group without members: false, no change is sent', () async {
      await serve(_Smartschool());

      expect(await groups.clearMembers(_withoutMembers), isFalse);
      expect(server.log, [_page(900502), _read(900502)]);
    });

    test(
      'a page after the post that still lists members is unconfirmed',
      () async {
        await serve(_Smartschool()..ignoreSaves = true);

        await expectLater(
          groups.clearMembers(_withMembers),
          throwsA(
            _unconfirmed(['it lists 3, 0 of the 0 sent'], groupId: 900501),
          ),
        );
      },
    );
  });

  group('removeMember', () {
    test('reads the members page, sends the removal once with userID and '
        'groupID, and reads the page again: the member is gone', () async {
      await serve(_Smartschool());
      final jan = (await groups.members(
        _withMembers,
      )).firstWhere((m) => m.userId == 900001);
      server.log.clear();

      expect(await groups.removeMember(_withMembers, jan), isTrue);

      expect(server.log, [_page(900501), _remove, _page(900501)]);
      final removal = server.removals.single;
      expect(removal.uri.path, '/Profile/Mygroups/deleteUser');
      expect(removal.uri.query, isEmpty);
      expect(removal.contentType, Headers.formUrlEncodedContentType);
      expect(removal.headers['X-Requested-With'], 'XMLHttpRequest');
      expect(_fields(removal), {'userID': '900001', 'groupID': '900501'});
      expect(server.members[900501]!.map((p) => p.userId), [900002, 900003]);
    });

    test('someone who is not a member: false; only the members page is '
        'read', () async {
      await serve(_Smartschool());

      expect(
        await groups.removeMember(
          _withMembers,
          const MyGroupMember(userId: 900011, name: 'Peeters Piet', ssId: 4069),
        ),
        isFalse,
      );
      expect(server.log, [_page(900501)]);
    });

    test('a member that is not a person is an ArgumentError; nothing is '
        'sent', () async {
      await serve(_Smartschool());

      await expectLater(
        groups.removeMember(
          _withMembers,
          const MyGroupMember(
            userId: 900002,
            name: '2B',
            ssId: 4069,
            type: 'K',
          ),
        ),
        throwsA(_argumentError(['900002', 'not a person'])),
      );
      expect(server.log, isEmpty);
    });

    test('a group the user does not have is a '
        'SmartschoolMyGroupNotFoundError; no removal is sent', () async {
      await serve(_Smartschool());

      await expectLater(
        groups.removeMember(
          const MyGroup(id: 900599, name: 'weg'),
          const MyGroupMember(userId: 900001, name: 'Janssens Jan', ssId: 4069),
        ),
        throwsA(isA<SmartschoolMyGroupNotFoundError>()),
      );
      expect(server.log, [_page(900599)]);
    });

    const jan = MyGroupMember(userId: 900001, name: 'Janssens Jan', ssId: 4069);

    test('true from Smartschool, but the member still listed after it: '
        'unconfirmed (true does not say that anyone was removed)', () async {
      await serve(_Smartschool()..ignoreRemovals = true);

      await expectLater(
        groups.removeMember(_withMembers, jan),
        throwsA(_unconfirmed(['still lists the member'], groupId: 900501)),
      );
      expect(server.log, [_page(900501), _remove, _page(900501)]);
    });

    test('an answer other than true, or another status: unconfirmed, with '
        'that status; the page is not read again', () async {
      for (final (answer, status) in [
        (() => _answer('false', contentType: 'application/json'), null),
        (() => _answer('<html>Oeps</html>', status: 500), 500),
      ]) {
        await serve(_Smartschool()..removeAnswer = answer);

        await expectLater(
          groups.removeMember(_withMembers, jan),
          throwsA(
            _unconfirmed(
              ['900001', 'HTTP'],
              groupId: 900501,
              statusCode: status,
            ),
          ),
        );
        expect(server.log, [_page(900501), _remove]);
      }
    });

    test('a members page after the removal that cannot be read (the list, '
        'another status): unconfirmed, with its cause', () async {
      for (final (page, status) in [
        (_answer(_listNotFound), null),
        (_answer('Oeps', status: 500), 500),
      ]) {
        await serve(
          _Smartschool()..pageAnswer = (load) => load == 2 ? page : null,
        );

        await expectLater(
          groups.removeMember(_withMembers, jan),
          throwsA(
            _unconfirmed(
              ['could not be read'],
              groupId: 900501,
              statusCode: status,
              cause: isA<SmartschoolMyGroupsError>(),
            ),
          ),
        );
      }
    });

    test('the connection dropping after the removal went out is unconfirmed, '
        'with its cause; not sent again', () async {
      await serve(_Smartschool()..dropAfterRemoval = true);

      await expectLater(
        groups.removeMember(_withMembers, jan),
        throwsA(
          _unconfirmed(
            ['no answer came in'],
            groupId: 900501,
            cause: isA<SmartschoolConnectionError>(),
          ),
        ),
      );
      expect(server.removals, hasLength(1));
    });
  });
}
