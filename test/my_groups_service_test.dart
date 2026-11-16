// Tests for issue #251: `MyGroupsService`, the user's own mail groups
// ("Mijn groepen", `/?module=Profile&file=mygroups`) and their members,
// against a fake Smartschool.
//
// The fake answers the list of own groups and the members page of a group
// with hand-written pages (`get/profile/mygroups/`), and, like Smartschool,
// sets the member picker's selection of a group (`usc` `mygroups_{id}`) in
// its session when the group's members page is loaded; the picker's
// `userSelect` / `get Items Selected` then answers that selection
// (`post/userselect/`). The fixtures are written by hand with the fakes of
// test/fixtures/lvs/FAKES.md, never trimmed from a live answer: the members
// of a real group are mostly pupils.
//
// What Smartschool answers was seen live on 2026-11-16 (see the issue): the
// list does not escape a name or a description; the members page of an ID
// the user has no group of is the list with the feedback "De actie werd
// niet correct uitgevoerd!"; the picker answers a dispatcher request without
// `X-Requested-With` with `302 Location: /?module=Homepage`.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';

String _fixture(String name) =>
    File('test/fixtures/smartschool/requests/$name').readAsStringSync();

final _list = _fixture('get/profile/mygroups/list.html');
final _listEmpty = _fixture('get/profile/mygroups/list-empty.html');
final _listNotFound = _fixture('get/profile/mygroups/list-not-found.html');
final _members = _fixture('get/profile/mygroups/members.html');
final _membersEmpty = _fixture('get/profile/mygroups/members-empty.html');
final _selected = _fixture('post/userselect/get-items-selected.xml');
final _selectedEmpty = _fixture('post/userselect/get-items-selected-empty.xml');

/// The groups of [_list].
const _withMembers = MyGroup(id: 900501, name: 'Testgroep 5');
const _withoutMembers = MyGroup(id: 900502, name: 'testgroep zorg');

/// The requests, as the fake logs them.
const _listRequest = 'GET list';
String _membersRequest(int id) => 'GET members $id';
String _pickerRequest(String action, String usc) => 'POST picker $action $usc';

/// The `get Items Selected` of the picker for own group [id], as logged.
String _selectedRequest(int id) =>
    _pickerRequest('get Items Selected', 'mygroups_$id');

const _loginPage = '''
<html><body>
<form class="form" name="login_form" method="post">
<input type="text" name="login_form[_username]" />
<input type="password" name="login_form[_password]" />
<input type="hidden" name="login_form[_token]" value="csrf" />
<button type="submit">Aanmelden</button>
</form>
</body></html>
''';

/// An answer of the fake.
ResponseBody _answer(
  String body, {
  int status = 200,
  String contentType = 'text/html; charset=UTF-8',
  Map<String, List<String>> headers = const {},
  String? at,
}) {
  final response = ResponseBody.fromString(
    body,
    status,
    headers: {
      Headers.contentTypeHeader: [contentType],
      ...headers,
    },
  );
  if (at != null) {
    response.redirects = [
      RedirectRecord(303, 'GET', Uri.parse('https://$_host$at')),
    ];
  }
  return response;
}

ResponseBody _xml(String body) =>
    _answer(body, contentType: 'text/xml; charset=UTF-8');

/// A Smartschool with own groups: [pages] are the members pages by group,
/// [selections] the picker's selection of a group, which loading its members
/// page sets in the session.
class _Smartschool implements HttpClientAdapter {
  _Smartschool({
    this.list,
    Map<int, String>? pages,
    Map<int, String>? selections,
  }) : pages = pages ?? {900501: _members, 900502: _membersEmpty},
       selections = selections ?? {900501: _selected, 900502: _selectedEmpty};

  /// The list of own groups; [_list] when `null`.
  final String? list;
  final Map<int, String> pages;
  final Map<int, String> selections;

  /// Answers to the list and the members pages instead of the above.
  ResponseBody Function()? pageAnswer;

  /// Answers to the picker's requests instead of the selection.
  ResponseBody Function()? pickerAnswer;

  /// The compose form of Messages, and the answer to its recipient search.
  String? composeForm;
  String? searchAnswer;

  /// The texts the recipient search was asked for.
  final List<String> searches = [];

  /// How many picker requests are refused with an empty `401`, as
  /// Smartschool does on an expired session; the session is then gone until
  /// the client logs in again.
  int refusePickers = 0;

  bool _session = true;
  bool _passwordDone = false;

  /// The picker's selections set in the session, by `usc`.
  final Map<String, String> _inSession = {};

  /// Every request: [_listRequest], [_membersRequest], [_pickerRequest], or
  /// `METHOD path` for any other.
  final List<String> log = [];

  /// The picker's requests, as they went out.
  final List<RequestOptions> pickerRequests = [];

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
    final path = uri.path;

    if (options.method == 'POST' && path == '/login') {
      log.add('POST /login');
      _passwordDone = true;
      return _answer(
        '',
        status: 302,
        headers: {
          'location': ['/'],
        },
      );
    }
    if (path == '/2fa/api/v1/config') {
      log.add('GET $path');
      return _answer(
        '{"possibleAuthenticationMechanisms":["googleAuthenticator"]}',
        contentType: Headers.jsonContentType,
      );
    }
    if (path == '/2fa/api/v1/google-authenticator') {
      log.add('POST $path');
      _session = _passwordDone;
      return _answer(
        '{"success":true,"redirectTo":"/"}',
        contentType: Headers.jsonContentType,
      );
    }

    if (options.method == 'POST' &&
        query['module'] == 'Userselect' &&
        query['file'] == 'dispatcher') {
      return _picker(options);
    }

    if (!_session) {
      log.add('GET $path (login chain)');
      if (!_passwordDone) {
        return _answer(_loginPage, at: path == '/login' ? null : '/login');
      }
      return _answer('<html><body>2fa</body></html>', at: '/2fa');
    }

    if (options.method == 'GET' &&
        query['module'] == 'Profile' &&
        query['file'] == 'mygroups') {
      if (query['function'] == 'users') {
        final id = int.parse(query['mID']!);
        log.add(_membersRequest(id));
        final override = pageAnswer;
        if (override != null) return override();
        final page = pages[id];
        if (page == null) return _answer(_listNotFound);
        _inSession['mygroups_$id'] = selections[id] ?? _selectedEmpty;
        return _answer(page);
      }
      log.add(_listRequest);
      final override = pageAnswer;
      if (override != null) return override();
      return _answer(list ?? _list);
    }

    if (options.method == 'GET' &&
        query['module'] == 'Messages' &&
        query['file'] == 'composeMessage' &&
        composeForm != null) {
      log.add('GET compose');
      return _answer(composeForm!);
    }
    if (options.method == 'POST' &&
        query['module'] == 'Messages' &&
        query['file'] == 'searchUsers' &&
        !query.containsKey('function') &&
        searchAnswer != null) {
      final text = '${(options.data as Map)['val']}';
      log.add('POST search');
      searches.add(text);
      return _xml(searchAnswer!);
    }

    log.add('${options.method} $path?${uri.query}');
    return _answer('<html><body>Not here</body></html>', status: 404);
  }

  ResponseBody _picker(RequestOptions options) {
    pickerRequests.add(options);
    final command = XmlDocument.parse(
      '${(options.data as Map)['command']}',
    ).rootElement.getElement('command')!;
    final action = command.getElement('action')!.innerText;
    final usc = command
        .findAllElements('param')
        .firstWhere((p) => p.getAttribute('name') == 'usc')
        .innerText;
    log.add(_pickerRequest(action, usc));

    if (!_session) return _answer('', status: 401);
    if (refusePickers > 0) {
      refusePickers--;
      _session = false;
      _passwordDone = false;
      _inSession.clear();
      return _answer('', status: 401);
    }
    if (options.headers['X-Requested-With'] != 'XMLHttpRequest') {
      return _answer(
        '',
        status: 302,
        headers: {
          'location': ['/?module=Homepage'],
        },
      );
    }
    final override = pickerAnswer;
    if (override != null) return override();
    final selection = _inSession[usc];
    return _xml(
      selection ??
          '<server><response><status>ok</status><actions><action>'
              '<subsystem>userselect</subsystem>'
              '<command>handle selected items</command>'
              '<data><items /></data></action></actions></response></server>',
    );
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

/// A [SmartschoolMyGroupsError] (not its subtype) with [statusCode], whose
/// message holds every one of [parts].
Matcher _myGroupsError(List<String> parts, {int? statusCode}) => allOf(
  isA<SmartschoolMyGroupsError>()
      .having((e) => e.statusCode, 'statusCode', statusCode)
      .having(
        (e) => e.message,
        'message',
        allOf([for (final p in parts) contains(p)]),
      ),
  isNot(isA<SmartschoolMyGroupNotFoundError>()),
);

/// The fake people of the fixtures: an error must not name them.
const _names = ['Janssens', 'Peeters', 'Dupont'];

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

  group('list', () {
    test('several groups, sorted by name as Smartschool lists them: each '
        'with its ID, its name and description as the page shows them, a '
        'bare & and " included, and "" for no description', () async {
      await serve(_Smartschool());

      final all = await groups.list();

      expect(server.log, [_listRequest]);
      expect(all.map((g) => g.id), [900503, 900501, 900502]);
      expect(all.map((g) => g.name), [
        'Testgroep & "co"',
        'Testgroep 5',
        'testgroep zorg',
      ]);
      expect(all.map((g) => g.description), [
        'Testvak & "meer"',
        '',
        'Testvak 2B',
      ]);
    });

    test('one group', () async {
      await serve(_Smartschool(list: _listNotFound));

      final all = await groups.list();

      expect(all.map((g) => g.id), [900501]);
      expect(all.single.name, 'Testgroep 5');
      expect(all.single.description, '');
    });

    test('no groups: an empty list', () async {
      await serve(_Smartschool(list: _listEmpty));

      expect(await groups.list(), isEmpty);
    });

    test('another page than the list is a SmartschoolMyGroupsError', () async {
      await serve(_Smartschool(list: '<html><body>Startpagina</body></html>'));

      await expectLater(
        groups.list(),
        throwsA(_myGroupsError(['list of own groups'])),
      );
    });

    test('another status than 200 is a SmartschoolMyGroupsError with that '
        'status', () async {
      await serve(_Smartschool());
      server.pageAnswer = () => _answer('<html>Oeps</html>', status: 500);

      await expectLater(
        groups.list(),
        throwsA(_myGroupsError(['HTTP 500'], statusCode: 500)),
      );
    });

    test('a row without a group ID, or with two, is a '
        'SmartschoolMyGroupsError', () async {
      await serve(_Smartschool(list: _list.replaceAll('&mID=900501', '&mID=')));
      await expectLater(
        groups.list(),
        throwsA(_myGroupsError(['Row 2', 'not one group ID'])),
      );

      await serve(
        _Smartschool(
          list: _list.replaceFirst(
            'function=users&mID=900501',
            'function=users&mID=900502',
          ),
        ),
      );
      await expectLater(
        groups.list(),
        throwsA(_myGroupsError(['Row 2', 'not one group ID'])),
      );
    });

    test('toString names a group by its ID only', () async {
      await serve(_Smartschool());

      final all = await groups.list();

      expect('${all.first}', 'MyGroup(900503)');
    });
  });

  group('members', () {
    test('reads the members page, then the picker\'s selection in its '
        'session: each member with the picker\'s platform and school, in '
        'the order of the page', () async {
      await serve(_Smartschool());

      final members = await groups.members(_withMembers);

      expect(server.log, [_membersRequest(900501), _selectedRequest(900501)]);
      expect(members.map((m) => m.userId), [900003, 900001, 900002]);
      expect(members.map((m) => m.name), [
        'Dupont Chloé',
        'Janssens Jan',
        'Peeters Marie',
      ]);
      expect(members.map((m) => m.ssId), everyElement(4069));
      expect(members.map((m) => m.schoolName), [
        null,
        'Springfield Academy',
        'Springfield Academy',
      ]);
      expect(members.map((m) => m.type), everyElement('U'));
      expect(members.every((m) => m.isUser), isTrue);
    });

    test(
      'the picker\'s request is the command userSelect / get Items '
      'Selected with only the group\'s usc, sent with X-Requested-With',
      () async {
        await serve(_Smartschool());

        await groups.members(_withMembers);

        final request = server.pickerRequests.single;
        expect(request.uri.path, '/');
        expect(request.uri.queryParameters, {
          'module': 'Userselect',
          'file': 'dispatcher',
        });
        expect(request.headers['X-Requested-With'], 'XMLHttpRequest');
        expect(request.data, isA<Map<dynamic, dynamic>>());
        expect((request.data as Map).keys, ['command']);
        final command = XmlDocument.parse(
          '${(request.data as Map)['command']}',
        ).rootElement.getElement('command')!;
        expect(command.getElement('subsystem')!.innerText, 'userSelect');
        expect(command.getElement('action')!.innerText, 'get Items Selected');
        final params = command.findAllElements('param').toList();
        expect(params.map((p) => p.getAttribute('name')), ['usc']);
        expect(params.single.innerText, 'mygroups_900501');
      },
    );

    test('a group without members: an empty list (<items />)', () async {
      await serve(_Smartschool());

      final members = await groups.members(_withoutMembers);

      expect(members, isEmpty);
      expect(server.log, [_membersRequest(900502), _selectedRequest(900502)]);
    });

    test('a group the user does not have is a '
        'SmartschoolMyGroupNotFoundError with its ID; the picker is not '
        'asked', () async {
      await serve(_Smartschool());

      await expectLater(
        groups.members(const MyGroup(id: 900599, name: 'weg')),
        throwsA(
          isA<SmartschoolMyGroupNotFoundError>()
              .having((e) => e.groupId, 'groupId', 900599)
              .having((e) => e.statusCode, 'statusCode', isNull)
              .having((e) => e.message, 'message', contains('900599')),
        ),
      );
      expect(server.log, [_membersRequest(900599)]);
    });

    test('a page that is not the members page is a SmartschoolMyGroupsError; '
        'the picker is not asked', () async {
      await serve(_Smartschool());
      server.pageAnswer = () =>
          _answer('<html><body>Startpagina</body></html>');

      await expectLater(
        groups.members(_withMembers),
        throwsA(_myGroupsError(['members page of own group 900501'])),
      );
      expect(server.log, [_membersRequest(900501)]);
    });

    test('a member row without an ID, or of another group, is a '
        'SmartschoolMyGroupsError', () async {
      await serve(
        _Smartschool(
          pages: {900501: _members.replaceFirst(' id="900001"', '')},
        ),
      );
      await expectLater(
        groups.members(_withMembers),
        throwsA(_myGroupsError(['Row 2', 'no member ID'])),
      );

      await serve(
        _Smartschool(
          pages: {
            900501: _members.replaceFirst(
              'data-userid="900002" data-groupid="900501"',
              'data-userid="900002" data-groupid="900502"',
            ),
          },
        ),
      );
      await expectLater(
        groups.members(_withMembers),
        throwsA(_myGroupsError(['Row 3', 'another member or group'])),
      );
    });

    test('the picker\'s redirect to the start page (its answer to a request '
        'without X-Requested-With) is a SmartschoolMyGroupsError with the '
        'status', () async {
      await serve(_Smartschool());
      server.pickerAnswer = () => _answer(
        '',
        status: 302,
        headers: {
          'location': ['/?module=Homepage'],
        },
      );

      await expectLater(
        groups.members(_withMembers),
        throwsA(
          _myGroupsError([
            'get Items Selected',
            'redirected',
            '/?module=Homepage',
            'HTTP 302',
          ], statusCode: 302),
        ),
      );
    });

    test('a picker answer with another status, an answer that is not ok, '
        'one without the selection, and an item without its platform are a '
        'SmartschoolMyGroupsError', () async {
      await serve(_Smartschool());
      for (final (answer, parts, status) in [
        (() => _answer('', status: 500), ['HTTP 500'], 500),
        (
          () => _xml(
            _selected.replaceFirst(
              '<status>ok</status>',
              '<status>error</status>',
            ),
          ),
          ['status "error"'],
          null,
        ),
        (
          () => _xml(
            _selected.replaceFirst('handle selected items', 'handle items'),
          ),
          ['no selection'],
          null,
        ),
        (
          () => _xml(
            _selected.replaceFirst('<ssId>4069</ssId>', '<ssId></ssId>'),
          ),
          ['Item 1', 'platform'],
          null,
        ),
      ]) {
        server.pickerAnswer = answer;
        await expectLater(
          groups.members(_withMembers),
          throwsA(_myGroupsError(parts, statusCode: status)),
        );
      }
    });

    test(
      'an HTML page from the picker is a SmartschoolUnexpectedPageError, '
      'malformed XML a SmartschoolParsingError, as for every XML command',
      () async {
        await serve(_Smartschool());
        server.pickerAnswer = () => _answer(
          '<!DOCTYPE html><html><head><title>Fout</title></head>'
          '<body><h1>Er is een fout opgetreden</h1></body></html>',
        );
        await expectLater(
          groups.members(_withMembers),
          throwsA(isA<SmartschoolUnexpectedPageError>()),
        );

        server.pickerAnswer = () => _xml('<server><response><status>ok');
        await expectLater(
          groups.members(_withMembers),
          throwsA(
            isA<SmartschoolParsingError>().having(
              (e) => e.message,
              'message',
              contains('get Items Selected'),
            ),
          ),
        );
      },
    );

    test(
      'a members page and a picker selection that do not list the same '
      'members are a SmartschoolMyGroupsError that names no member',
      () async {
        final selections = [
          // One member fewer.
          _selected.replaceFirst(
            RegExp(r'<item><type>U</type><id>900002.*?</item>\n'),
            '',
          ),
          // Another member instead of one.
          _selected.replaceFirst('<id>900002</id>', '<id>900004</id>'),
          // One member twice.
          _selected.replaceFirst('<id>900002</id>', '<id>900001</id>'),
        ];
        for (final selection in selections) {
          await serve(_Smartschool(selections: {900501: selection}));

          await expectLater(
            groups.members(_withMembers),
            throwsA(
              allOf(
                _myGroupsError(['own group 900501', 'not the same members']),
                isA<SmartschoolMyGroupsError>().having(
                  (e) => e.toString(),
                  'toString()',
                  isNot(anyOf([for (final n in _names) contains(n)])),
                ),
              ),
            ),
          );
        }
      },
    );

    test('toString names a member by type, ID and platform only', () async {
      await serve(_Smartschool());

      final members = await groups.members(_withMembers);

      expect('${members.first}', 'MyGroupMember(U900003, ssId: 4069)');
    });

    test('a picker request that Smartschool refuses the session for is not '
        'retried as it is: the client logs in, loads the members page again '
        'and asks the picker once more in that page\'s session', () async {
      await serve(_Smartschool());
      server.refusePickers = 1;

      final members = await groups.members(_withMembers);

      expect(members.map((m) => m.userId), [900003, 900001, 900002]);
      // The service's requests, and the password step of the login.
      final steps = server.log
          .where(
            (l) =>
                l.startsWith('GET members') ||
                l.startsWith('POST picker') ||
                l == 'POST /login',
          )
          .toList();
      expect(steps, [
        _membersRequest(900501),
        _selectedRequest(900501),
        'POST /login',
        _membersRequest(900501),
        _selectedRequest(900501),
      ]);
    });

    test('refused twice, it throws a SmartschoolSessionExpiredError', () async {
      await serve(_Smartschool());
      server.refusePickers = 2;

      await expectLater(
        groups.members(_withMembers),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
      expect(
        server.log.where((l) => l == _selectedRequest(900501)),
        hasLength(2),
      );
      expect(server.log.where((l) => l == 'POST /login'), hasLength(1));
    });

    test('calls on one client take turns, also through two services: no '
        'members page is loaded between another call\'s page and its picker '
        'request', () async {
      await serve(_Smartschool());
      final other = MyGroupsService(client);

      final results = await Future.wait([
        groups.members(_withMembers),
        other.members(_withoutMembers),
        groups.members(_withMembers),
      ]);

      expect(results.map((r) => r.length), [3, 0, 3]);
      expect(server.log, [
        _membersRequest(900501),
        _selectedRequest(900501),
        _membersRequest(900502),
        _selectedRequest(900502),
        _membersRequest(900501),
        _selectedRequest(900501),
      ]);
    });

    test('a call that fails does not hold up the next one', () async {
      await serve(_Smartschool());

      final failed = groups.members(const MyGroup(id: 900599, name: 'weg'));
      final next = groups.members(_withoutMembers);

      await expectLater(
        failed,
        throwsA(isA<SmartschoolMyGroupNotFoundError>()),
      );
      expect(await next, isEmpty);
    });
  });

  group('findRecipient', () {
    /// A compose form and its recipient search, which finds [found].
    void compose(_Smartschool smartschool, String found) {
      smartschool.composeForm = _fixture('get/composemessage/new-message.html');
      smartschool.searchAnswer = found;
    }

    test('finds the group with its ID and name among the groups the compose '
        'search finds for its name', () async {
      await serve(_Smartschool());
      compose(
        server,
        _searchAnswer([
          (900777, 'Testgroep 5'), // another group with the same name
          (900501, 'Testgroep 5 extra'), // the ID, another name
          (900501, 'Testgroep 5'),
        ]),
      );

      final found = await groups.findRecipient(_withMembers);

      expect(found, isNotNull);
      expect(found!.groupId, 900501);
      expect(found.displayName, 'Testgroep 5');
      expect(found.ssId, 4069);
      expect(server.searches, ['Testgroep 5']);
    });

    test('null when the search does not find it so', () async {
      await serve(_Smartschool());
      compose(server, _searchAnswer([(900777, 'Testgroep 5')]));

      expect(await groups.findRecipient(_withMembers), isNull);
    });

    test(
      'a group without a name is an ArgumentError; nothing is sent',
      () async {
        await serve(_Smartschool());

        await expectLater(
          groups.findRecipient(const MyGroup(id: 900501, name: '  ')),
          throwsArgumentError,
        );
        expect(server.log, isEmpty);
      },
    );
  });
}

/// A compose search's answer that finds the groups [found] (ID, name).
String _searchAnswer(List<(int, String)> found) =>
    '<results><type>0</type><ssID>4069</ssID>'
    '<parentNodeId>insertSearchFieldContainer_0_0</parentNodeId><groups>'
    '${[for (final (id, name) in found) '<group><groupID>$id</groupID><text>$name</text><value>$name</value><selectable>on</selectable><icon>smsc/img/star/star_16x16.png</icon><ssID>4069</ssID><ssPlName /><description></description></group>'].join()}'
    '</groups><users /><sgrdetails><sgrselect>1</sgrselect>'
    '<dosgrsearch>0</dosgrsearch></sgrdetails></results>';
