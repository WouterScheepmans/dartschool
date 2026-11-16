// Tests for issue #252: the writes of `MyGroupsService`, creating, renaming
// and deleting an own mail group ("Mijn groepen",
// `/?module=Profile&file=mygroups`), against a fake Smartschool.
//
// The fake keeps its groups, and answers like Smartschool (seen live on
// 2026-11-16, see the issue): the list of own groups in the shape of the
// hand-written list.html (`get/profile/mygroups/`), sorted by name and not
// escaped; the form for a new group and the edit form of one in the shape of
// addedit.html, with a new token for every load and the values escaped; a
// save (`POST` of the form to its own URL) with `302` to the list
// (`function=main`), keeping its feedback in the session until the list
// shows it: "not done" (type 2) for a save it refuses, none for one that
// went through; a delete (a GET) with the list itself, with "done" (type
// 1), or "not done" for an ID it has no group of. It strips tags from a
// saved name and description. Made-up groups and IDs.
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
final _listEmpty = _fixture('get/profile/mygroups/list-empty.html');
final _listNotFound = _fixture('get/profile/mygroups/list-not-found.html');
final _listDeleted = _fixture('get/profile/mygroups/list-deleted.html');
final _form = _fixture('get/profile/mygroups/addedit.html');
final _form900503 = _fixture('get/profile/mygroups/addedit-900503.html');

/// The requests, as the fake logs them.
const _listRequest = 'GET list';
const _listAfterSave = 'GET list main';
const _newForm = 'GET form';
String _editForm(int id) => 'GET form $id';
const _create = 'POST save';
String _saveOf(int id) => 'POST save $id';
String _deleteOf(int id) => 'GET delete $id';

/// An answer of the fake.
ResponseBody _answer(
  String body, {
  int status = 200,
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
    ...headers,
  },
);

/// Smartschool's answer to a save: `302` to the list.
ResponseBody _redirectToList() => _answer(
  '',
  status: 302,
  headers: {
    'location': [myGroupListAfterSave],
  },
);

/// The connection dropping after a request went out.
Object _dropped(RequestOptions options) => DioException.connectionError(
  requestOptions: options,
  reason: 'Connection closed before full header was received',
  error: const SocketException('Connection reset by peer'),
);

/// A Smartschool with own groups, which it changes as Smartschool does.
class _Smartschool implements HttpClientAdapter {
  _Smartschool([List<FakeMyGroup>? groups])
    : groups = groups ?? myGroupsOfListFixture();

  /// The groups, as saved.
  final List<FakeMyGroup> groups;

  /// The ID of the next group made.
  int nextId = 900504;

  /// The token of the form loaded last in the session, and how many were
  /// handed out.
  String? _token;
  int _tokens = 0;

  /// The type of the feedback kept in the session until a page shows it.
  int? _feedback;

  /// Every request: [_listRequest], [_listAfterSave], [_newForm],
  /// [_editForm], [_create], [_saveOf], [_deleteOf], or `METHOD path?query`
  /// for any other.
  final List<String> log = [];

  /// The saves, as they went out.
  final List<RequestOptions> saves = [];

  /// Answers to a form instead of the form, by the group's ID (`null` for
  /// the form for a new group).
  String Function(int? groupId)? formAnswer;

  /// Answers to a save instead of handling it.
  ResponseBody Function()? saveAnswer;

  /// Whether a save is refused as Smartschool refuses one (nothing changed,
  /// "not done" kept for the list after it).
  bool refuseSaves = false;

  /// Whether a save changes nothing and says nothing.
  bool ignoreSaves = false;

  /// Whether the connection drops once a save was handled.
  bool dropAfterSave = false;

  /// What happens in Smartschool just before a save is handled (another
  /// tab of the user, say).
  void Function()? beforeSave;

  /// Answers to the list after a save instead of the list.
  ResponseBody Function()? listAfterSaveAnswer;

  /// Answers to a delete instead of handling it.
  ResponseBody Function()? deleteAnswer;

  /// Whether the connection drops once a delete was handled.
  bool dropAfterDelete = false;

  FakeMyGroup? _group(int? id) => groups.where((g) => g.id == id).firstOrNull;

  String _listShown() {
    final page = myGroupListPage(groups, feedback: _feedback);
    _feedback = null;
    return page;
  }

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
    final mine =
        uri.path == '/' &&
        query['module'] == 'Profile' &&
        query['file'] == 'mygroups';
    final function = query['function'];
    final id = int.tryParse(query['mID'] ?? '');

    if (mine && options.method == 'GET' && function == null) {
      log.add(_listRequest);
      return _answer(_listShown());
    }
    if (mine && options.method == 'GET' && function == 'main') {
      log.add(_listAfterSave);
      final override = listAfterSaveAnswer;
      if (override != null) return override();
      return _answer(_listShown());
    }
    if (mine && options.method == 'GET' && function == 'addedit') {
      log.add(id == null ? _newForm : _editForm(id));
      final override = formAnswer;
      final page = override != null
          ? override(id)
          : id != null && _group(id) == null
          ? myGroupListPage(groups, feedback: 2)
          : myGroupFormPage('made-up-token-${++_tokens}', _group(id));
      _token =
          RegExp(r'name="_csrf_token" value="([^"]*)"').firstMatch(page)?[1] ??
          _token;
      return _answer(page);
    }
    if (mine && options.method == 'POST' && function == 'addedit') {
      log.add(id == null ? _create : _saveOf(id));
      saves.add(options);
      final override = saveAnswer;
      if (override != null) return override();
      beforeSave?.call();
      _store(options.data as Map, id);
      if (dropAfterSave) throw _dropped(options);
      return _redirectToList();
    }
    if (mine && options.method == 'GET' && function == 'delete') {
      log.add(_deleteOf(id!));
      final override = deleteAnswer;
      if (override != null) return override();
      final group = _group(id);
      if (group != null) groups.remove(group);
      if (dropAfterDelete) throw _dropped(options);
      return _answer(myGroupListPage(groups, feedback: group == null ? 2 : 1));
    }

    log.add('${options.method} ${uri.path}?${uri.query}');
    return _answer('<html><body>Not here</body></html>', status: 404);
  }

  /// Handles a save of [fields], of group [id] (a new one when `null`).
  void _store(Map<dynamic, dynamic> fields, int? id) {
    if (ignoreSaves) return;
    final name = '${fields['name']}'.replaceAll(myGroupTags, '');
    final description = '${fields['desc']}'.replaceAll(myGroupTags, '');
    final group = _group(id);
    if (refuseSaves ||
        fields['_csrf_token'] != _token ||
        fields['store'] != '1' ||
        name.trim().isEmpty ||
        (id != null && group == null)) {
      _feedback = 2;
      return;
    }
    if (group == null) {
      groups.add(FakeMyGroup(nextId++, name, description));
    } else {
      group
        ..name = name
        ..description = description;
    }
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

/// The fields of the save [options], as they went out.
Map<String, String> _fields(RequestOptions options) => {
  for (final MapEntry(:key, :value) in (options.data as Map).entries)
    '$key': '$value',
};

/// A [SmartschoolMyGroupSaveUnconfirmedError] of group [groupId] with
/// [statusCode], whose message holds every one of [parts] and names no
/// group of the fake by its name.
Matcher _unconfirmed(
  List<String> parts, {
  int? groupId,
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

/// Names of the groups of the tests: an error must not quote them.
const _names = ['Testgroep', 'testgroep', 'Projectgroep'];

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

  /// The group [id] of the list.
  Future<MyGroup> listed(int id) async {
    final group = (await groups.list()).firstWhere((g) => g.id == id);
    server.log.clear();
    return group;
  }

  group('create', () {
    test('reads the list, loads the form for its token, posts it once to '
        'its own URL with the token, store, name and desc, follows the '
        'redirect to the list at once, and returns the new group as the '
        'list shows it', () async {
      await serve(_Smartschool());

      final made = await groups.create(
        name: 'Projectgroep',
        description: 'reis',
      );

      expect(server.log, [_listRequest, _newForm, _create, _listAfterSave]);
      final save = server.saves.single;
      expect(save.uri.path, '/');
      expect(save.uri.queryParameters, {
        'module': 'Profile',
        'file': 'mygroups',
        'function': 'addedit',
      });
      expect(save.contentType, Headers.formUrlEncodedContentType);
      expect(_fields(save), {
        '_csrf_token': 'made-up-token-1',
        'store': '1',
        'name': 'Projectgroep',
        'desc': 'reis',
      });
      expect(made.id, 900504);
      expect(made.name, 'Projectgroep');
      expect(made.description, 'reis');
      expect('$made', 'MyGroup(900504)');
      expect(
        (await groups.list()).map((g) => g.id),
        containsAll([900501, 900502, 900503, 900504]),
      );
    });

    test('an empty description when none is given', () async {
      await serve(_Smartschool());

      final made = await groups.create(name: 'Projectgroep');

      expect(_fields(server.saves.single)['desc'], '');
      expect(made.description, '');
    });

    test('a name and a description with &, " and é are sent and returned as '
        'they are', () async {
      await serve(_Smartschool());

      final made = await groups.create(
        name: 'Projectgroep & "5" é',
        description: 'reis & "zo"',
      );

      expect(_fields(server.saves.single)['name'], 'Projectgroep & "5" é');
      expect(made.name, 'Projectgroep & "5" é');
      expect(made.description, 'reis & "zo"');
    });

    test('Smartschool strips tags: the group is returned as it was saved, '
        'without them', () async {
      await serve(_Smartschool());

      final made = await groups.create(
        name: 'Projectgroep <b>5</b>',
        description: 'gewijzigd <i>vet</i>',
      );

      expect(_fields(server.saves.single)['name'], 'Projectgroep <b>5</b>');
      expect(made.name, 'Projectgroep 5');
      expect(made.description, 'gewijzigd vet');
    });

    test('a blank name, or one that is empty without its tags, is an '
        'ArgumentError; nothing is sent', () async {
      await serve(_Smartschool());

      for (final name in ['', '   ', '<b></b>', ' <i> </i> ']) {
        await expectLater(
          groups.create(name: name),
          throwsArgumentError,
          reason: '"$name"',
        );
      }
      expect(server.log, isEmpty);
    });

    test(
      'a name that another own group has, as the list shows it, is an '
      'ArgumentError that names that group by its ID; nothing is saved',
      () async {
        await serve(_Smartschool());

        for (final (name, id) in [
          ('Testgroep 5', 900501),
          ('  Testgroep 5 ', 900501),
          ('Testgroep <b>5</b>', 900501),
          ('Testgroep & "co"', 900503),
        ]) {
          server.log.clear();
          await expectLater(
            groups.create(name: name),
            throwsA(
              isA<ArgumentError>()
                  .having((e) => e.name, 'name', 'name')
                  .having(
                    (e) => '${e.message}',
                    'message',
                    allOf(contains('$id'), isNot(contains('Testgroep'))),
                  ),
            ),
            reason: name,
          );
          expect(server.log, [_listRequest], reason: name);
        }
        expect(server.saves, isEmpty);
      },
    );

    test('a save that Smartschool refuses (the list after it shows "not '
        'done", type 2) is a SmartschoolMyGroupSaveUnconfirmedError; it is '
        'sent once', () async {
      await serve(_Smartschool()..refuseSaves = true);

      await expectLater(
        groups.create(name: 'Projectgroep'),
        throwsA(_unconfirmed(['not done (type 2)'])),
      );
      expect(server.log, [_listRequest, _newForm, _create, _listAfterSave]);
    });

    test('a save answered without the redirect to the list (200, a redirect '
        'elsewhere, 500) is unconfirmed with that status; the list is not '
        'read', () async {
      for (final (answer, status) in [
        (() => _answer(myGroupFormPage('made-up-token-9')), 200),
        (
          () => _answer(
            '',
            status: 302,
            headers: {
              'location': ['/?module=Homepage'],
            },
          ),
          302,
        ),
        (
          () => _answer(
            '',
            status: 302,
            headers: {
              'location': [
                '/?module=Profile&file=mygroups&function=addedit&mID=900501',
              ],
            },
          ),
          302,
        ),
        (() => _answer('<html>Oeps</html>', status: 500), 500),
      ]) {
        await serve(_Smartschool()..saveAnswer = answer);

        await expectLater(
          groups.create(name: 'Projectgroep'),
          throwsA(_unconfirmed(['not with the redirect'], statusCode: status)),
        );
        expect(server.log, [_listRequest, _newForm, _create]);
      }
    });

    test('a list after the save without the new group (Smartschool saved '
        'nothing and said nothing) is unconfirmed', () async {
      await serve(_Smartschool()..ignoreSaves = true);

      await expectLater(
        groups.create(name: 'Projectgroep'),
        throwsA(_unconfirmed(['0 new groups with the name and description'])),
      );
    });

    test(
      'a list after the save that cannot be read (HTTP 500, another page) '
      'is unconfirmed, with its status and the read\'s error as its cause',
      () async {
        await serve(
          _Smartschool()
            ..listAfterSaveAnswer = () =>
                _answer('<html>Oeps</html>', status: 500),
        );
        await expectLater(
          groups.create(name: 'Projectgroep'),
          throwsA(
            _unconfirmed(
              ['HTTP 500'],
              statusCode: 500,
              cause: isA<SmartschoolMyGroupsError>(),
            ),
          ),
        );

        await serve(
          _Smartschool()
            ..listAfterSaveAnswer = () => _answer('<html>Startpagina</html>'),
        );
        await expectLater(
          groups.create(name: 'Projectgroep'),
          throwsA(
            _unconfirmed([
              'not answer',
              'list of own groups',
            ], cause: isA<SmartschoolMyGroupsError>()),
          ),
        );
      },
    );

    test('the connection dropping after the save went out is unconfirmed, '
        'with the connection error as its cause; no second create is sent, '
        'and calling create again with the name refuses it, since the '
        'group was made', () async {
      await serve(_Smartschool()..dropAfterSave = true);

      await expectLater(
        groups.create(name: 'Projectgroep'),
        throwsA(
          _unconfirmed([
            'no answer came in',
          ], cause: isA<SmartschoolConnectionError>()),
        ),
      );
      expect(server.log, [_listRequest, _newForm, _create]);
      expect(server.groups.map((g) => g.id), contains(900504));

      server.dropAfterSave = false;
      await expectLater(
        groups.create(name: 'Projectgroep'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('900504'),
          ),
        ),
      );
      expect(server.saves, hasLength(1));
    });

    test('a session that Smartschool refuses for the save is a '
        'SmartschoolSessionExpiredError, not an unconfirmed save: it is not '
        'sent again', () async {
      await serve(_Smartschool()..saveAnswer = () => _answer('', status: 401));

      await expectLater(
        groups.create(name: 'Projectgroep'),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
      expect(server.saves, hasLength(1));
      expect(server.log, [_listRequest, _newForm, _create]);
    });

    test('another group made meanwhile (in another tab): the new one with the '
        'name and description sent is returned; two such groups are '
        'unconfirmed', () async {
      await serve(_Smartschool());
      server.beforeSave = () =>
          server.groups.add(FakeMyGroup(server.nextId++, 'Andere groep'));

      final made = await groups.create(name: 'Projectgroep');

      expect(made.id, 900505);
      expect(made.name, 'Projectgroep');

      server.beforeSave = () =>
          server.groups.add(FakeMyGroup(server.nextId++, 'Projectgroep 2'));
      await expectLater(
        groups.create(name: 'Projectgroep 2'),
        throwsA(_unconfirmed(['2 new groups with the name and description'])),
      );
    });

    test(
      'a form that is not the form (the list, a form without its token or '
      'its inputs) is a SmartschoolMyGroupsError; nothing is saved',
      () async {
        for (final page in [
          _list,
          myGroupFormPage(''),
          _form.replaceFirst(
            RegExp(r'<input[^>]*name="_csrf_token"[^>]*>'),
            '',
          ),
          _form.replaceFirst(RegExp(r'<input[^>]*name="desc"[^>]*>'), ''),
          '<html><body>Startpagina</body></html>',
        ]) {
          await serve(_Smartschool()..formAnswer = (_) => page);

          await expectLater(
            groups.create(name: 'Projectgroep'),
            throwsA(
              allOf(
                isA<SmartschoolMyGroupsError>(),
                isNot(isA<SmartschoolMyGroupNotFoundError>()),
              ),
            ),
          );
          expect(server.saves, isEmpty);
        }
      },
    );

    test('two creates at once, through two services of one client, take '
        'turns: each reads the list, loads the form and saves before the '
        'next one starts', () async {
      await serve(_Smartschool());
      final other = MyGroupsService(client);

      final made = await Future.wait([
        groups.create(name: 'Projectgroep A'),
        other.create(name: 'Projectgroep B'),
      ]);

      expect(made.map((g) => g.id), [900504, 900505]);
      expect(made.map((g) => g.name), ['Projectgroep A', 'Projectgroep B']);
      expect(server.log, [
        for (var i = 0; i < 2; i++) ...[
          _listRequest,
          _newForm,
          _create,
          _listAfterSave,
        ],
      ]);
      expect(server.saves.map((s) => _fields(s)['_csrf_token']), [
        'made-up-token-1',
        'made-up-token-2',
      ]);
    });
  });

  group('update', () {
    test('reads the list, loads the group\'s edit form for its token, posts '
        'it to its own URL with the name and description, follows the '
        'redirect, and returns the group as the list shows it', () async {
      await serve(_Smartschool());
      final zorg = await listed(900502);

      final saved = await groups.update(
        zorg,
        name: 'testgroep zorg 2',
        description: 'Testvak 3B',
      );

      expect(server.log, [
        _listRequest,
        _editForm(900502),
        _saveOf(900502),
        _listAfterSave,
      ]);
      final save = server.saves.single;
      expect(save.uri.queryParameters, {
        'module': 'Profile',
        'file': 'mygroups',
        'function': 'addedit',
        'mID': '900502',
      });
      expect(_fields(save), {
        '_csrf_token': 'made-up-token-1',
        'store': '1',
        'name': 'testgroep zorg 2',
        'desc': 'Testvak 3B',
      });
      expect(saved.id, 900502);
      expect(saved.name, 'testgroep zorg 2');
      expect(saved.description, 'Testvak 3B');
    });

    test('only a name: the description of the edit form, escaped in its '
        'value, is sent back exactly; only a description: its name', () async {
      await serve(_Smartschool()..formAnswer = (_) => _form900503);
      final group = await listed(900503);

      final renamed = await groups.update(group, name: 'Testgroep 7');

      expect(_fields(server.saves.single), {
        '_csrf_token': 'made-up-token-900503',
        'store': '1',
        'name': 'Testgroep 7',
        'desc': 'Testvak & "meer"',
      });
      expect(renamed.name, 'Testgroep 7');
      expect(renamed.description, 'Testvak & "meer"');

      await serve(_Smartschool()..formAnswer = (_) => _form900503);
      final described = await groups.update(
        await listed(900503),
        description: 'Testvak 4',
      );

      expect(_fields(server.saves.single)['name'], 'Testgroep & "co"');
      expect(_fields(server.saves.single)['desc'], 'Testvak 4');
      expect(described.name, 'Testgroep & "co"');
      expect(described.description, 'Testvak 4');
    });

    test('an empty description empties it', () async {
      await serve(_Smartschool());

      final saved = await groups.update(await listed(900502), description: '');

      expect(_fields(server.saves.single)['name'], 'testgroep zorg');
      expect(_fields(server.saves.single)['desc'], '');
      expect(saved.description, '');
    });

    test(
      'neither a name nor a description, a blank name, or one that is '
      'empty without its tags, is an ArgumentError; nothing is sent',
      () async {
        await serve(_Smartschool());
        const group = MyGroup(id: 900502, name: 'testgroep zorg');

        await expectLater(groups.update(group), throwsArgumentError);
        for (final name in ['', '  ', '<b></b>']) {
          await expectLater(
            groups.update(group, name: name, description: 'x'),
            throwsArgumentError,
            reason: '"$name"',
          );
        }
        expect(server.log, isEmpty);
      },
    );

    test('a name that another own group has is an ArgumentError once the '
        'list was read; nothing is saved. Its own name is fine', () async {
      await serve(_Smartschool());
      final zorg = await listed(900502);

      await expectLater(
        groups.update(zorg, name: 'Testgroep 5'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('900501'),
          ),
        ),
      );
      expect(server.log, [_listRequest]);

      final saved = await groups.update(
        zorg,
        name: 'testgroep zorg',
        description: 'Testvak 2C',
      );
      expect(saved.description, 'Testvak 2C');
    });

    test('a group the list does not have is a '
        'SmartschoolMyGroupNotFoundError; nothing more is sent', () async {
      await serve(_Smartschool());

      await expectLater(
        groups.update(
          const MyGroup(id: 900599, name: 'weg'),
          name: 'Projectgroep',
        ),
        throwsA(
          isA<SmartschoolMyGroupNotFoundError>().having(
            (e) => e.groupId,
            'groupId',
            900599,
          ),
        ),
      );
      expect(server.log, [_listRequest]);
    });

    test('a group deleted between the list and its edit form (Smartschool '
        'answers the form with the list and "not done") is a '
        'SmartschoolMyGroupNotFoundError; nothing is saved', () async {
      await serve(_Smartschool()..formAnswer = (_) => _listNotFound);

      await expectLater(
        groups.update(await listed(900502), name: 'Projectgroep'),
        throwsA(
          isA<SmartschoolMyGroupNotFoundError>().having(
            (e) => e.groupId,
            'groupId',
            900502,
          ),
        ),
      );
      expect(server.log, [_listRequest, _editForm(900502)]);
      expect(server.saves, isEmpty);
    });

    test('a save that Smartschool refuses is unconfirmed, with the group\'s '
        'ID; it is sent once', () async {
      await serve(_Smartschool()..refuseSaves = true);

      await expectLater(
        groups.update(await listed(900502), name: 'Projectgroep'),
        throwsA(_unconfirmed(['not done (type 2)'], groupId: 900502)),
      );
      expect(server.saves, hasLength(1));
    });

    test('a list after the save without the change, or without the group, is '
        'unconfirmed', () async {
      await serve(_Smartschool()..ignoreSaves = true);
      await expectLater(
        groups.update(await listed(900502), name: 'Projectgroep'),
        throwsA(
          _unconfirmed([
            'does not have the name and description sent',
          ], groupId: 900502),
        ),
      );

      await serve(
        _Smartschool()..listAfterSaveAnswer = () => _answer(_listEmpty),
      );
      await expectLater(
        groups.update(await listed(900502), name: 'Projectgroep'),
        throwsA(_unconfirmed(['does not have the group'], groupId: 900502)),
      );
    });

    test('the connection dropping after the save went out is unconfirmed, '
        'with its cause; not sent again', () async {
      await serve(_Smartschool()..dropAfterSave = true);

      await expectLater(
        groups.update(await listed(900502), name: 'Projectgroep'),
        throwsA(
          _unconfirmed(
            ['no answer came in'],
            groupId: 900502,
            cause: isA<SmartschoolConnectionError>(),
          ),
        ),
      );
      expect(server.saves, hasLength(1));
    });
  });

  group('delete', () {
    test('reads the list and sends the delete once; Smartschool answers with '
        'the list without the group and "done" (type 1)', () async {
      await serve(_Smartschool());

      await groups.delete(await listed(900503));

      expect(server.log, [_listRequest, _deleteOf(900503)]);
      expect(server.groups.map((g) => g.id), [900501, 900502]);
    });

    test('the answer as seen live (list-deleted.html) confirms it', () async {
      await serve(_Smartschool()..deleteAnswer = () => _answer(_listDeleted));

      await groups.delete(await listed(900503));

      expect(server.log, [_listRequest, _deleteOf(900503)]);
    });

    test('a group the list does not have is a '
        'SmartschoolMyGroupNotFoundError; no delete is sent', () async {
      await serve(_Smartschool());

      await expectLater(
        groups.delete(const MyGroup(id: 900599, name: 'weg')),
        throwsA(
          isA<SmartschoolMyGroupNotFoundError>().having(
            (e) => e.groupId,
            'groupId',
            900599,
          ),
        ),
      );
      expect(server.log, [_listRequest]);
    });

    test('"not done" (type 2) and a list without the group: it was gone '
        'already, a SmartschoolMyGroupNotFoundError', () async {
      await serve(_Smartschool());
      server.deleteAnswer = () => _answer(
        myGroupListPage(
          server.groups.where((g) => g.id != 900503).toList(),
          feedback: 2,
        ),
      );

      await expectLater(
        groups.delete(await listed(900503)),
        throwsA(
          isA<SmartschoolMyGroupNotFoundError>().having(
            (e) => e.groupId,
            'groupId',
            900503,
          ),
        ),
      );
      expect(server.log, [_listRequest, _deleteOf(900503)]);
    });

    test('"not done" with the group still listed, "done" with the group still '
        'listed, or no feedback: unconfirmed', () async {
      for (final (answer, parts) in [
        (() => _answer(_listNotFound), ['still in it', 'type 2']),
        (
          () => _answer(myGroupListPage(myGroupsOfListFixture(), feedback: 1)),
          ['still in it', 'type 1'],
        ),
        (
          () => _answer(
            myGroupListPage(
              myGroupsOfListFixture().where((g) => g.id != 900501).toList(),
            ),
          ),
          ['without the group', 'no feedback'],
        ),
      ]) {
        await serve(_Smartschool()..deleteAnswer = answer);

        await expectLater(
          groups.delete(await listed(900501)),
          throwsA(_unconfirmed(parts, groupId: 900501)),
        );
        expect(server.log, [_listRequest, _deleteOf(900501)]);
      }
    });

    test('another status or another page is unconfirmed, with its status; '
        'the delete is sent once', () async {
      for (final (answer, status) in [
        (() => _answer('<html>Oeps</html>', status: 500), 500),
        (() => _answer('<html><body>Startpagina</body></html>'), null),
      ]) {
        await serve(_Smartschool()..deleteAnswer = answer);

        await expectLater(
          groups.delete(await listed(900501)),
          throwsA(
            _unconfirmed(
              [],
              groupId: 900501,
              statusCode: status,
              cause: isA<SmartschoolMyGroupsError>(),
            ),
          ),
        );
        expect(server.log, [_listRequest, _deleteOf(900501)]);
      }
    });

    test('the connection dropping after the delete went out is unconfirmed, '
        'with its cause; not sent again', () async {
      await serve(_Smartschool()..dropAfterDelete = true);

      await expectLater(
        groups.delete(await listed(900501)),
        throwsA(
          _unconfirmed(
            ['no answer came in'],
            groupId: 900501,
            cause: isA<SmartschoolConnectionError>(),
          ),
        ),
      );
      expect(server.log, [_listRequest, _deleteOf(900501)]);
    });
  });

  test('SmartschoolMyGroupSaveUnconfirmedError is not a '
      'SmartschoolMyGroupsError, and carries the group, the status and the '
      'cause', () {
    // "Nothing was saved" and "may have been saved" must not share a type.
    const cause = SmartschoolConnectionError('dropped');
    const error = SmartschoolMyGroupSaveUnconfirmedError(
      'unconfirmed',
      groupId: 900501,
      statusCode: 500,
      cause: cause,
    );
    expect(error, isA<SmartschoolException>());
    expect(error, isNot(isA<SmartschoolMyGroupsError>()));
    expect(error.groupId, 900501);
    expect(error.cause, same(cause));
    expect(
      '$error',
      'SmartschoolMyGroupSaveUnconfirmedError(500): unconfirmed',
    );
    expect(
      '${const SmartschoolMyGroupSaveUnconfirmedError('unconfirmed')}',
      'SmartschoolMyGroupSaveUnconfirmedError: unconfirmed',
    );
  });
}
