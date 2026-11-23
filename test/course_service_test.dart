// Tests for `CourseService`: the courses of the course menu, the documents
// of a course, its upload zones and its news, against a fake Smartschool.
//
// The fake answers in the shapes seen live on 2026-11-23 (see
// doc/courses.md): the course menu as JSON, the management pages of the
// documents and the news with a `ul#list` of `li[itemID]` items (the
// visibility icon `ico visible` or `ico not_visible`), the news page with
// each item's message, the tree of the upload zones as JSON, a saved form
// with `302`, and the upload zone's dispatcher command with
// `<status>ok</status>`. Made-up courses, items and IDs.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';

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

class _Doc {
  _Doc(this.id, this.name, {this.folder = false, this.visible = true});
  final int id;
  final String name;
  final bool folder;
  final bool visible;
  String? from;
  String? until;
}

class _News {
  _News(this.id, this.title, this.html, {this.visible = true});
  final int id;
  final String title;
  final String html;
  final bool visible;
}

ResponseBody _html(String body, {int status = 200, String? location}) =>
    ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
        'location': ?(location == null ? null : [location]),
      },
    );

String _visibleIcon(int id, bool visible) =>
    '<div class="ico ${visible ? 'visible' : 'not_visible'}" '
    'id="visibleImg$id" onclick="visible(\'/x\');"></div>';

/// A Smartschool with one course (813 on platform 6161) to manage.
class _Smartschool implements HttpClientAdapter {
  final Map<int, List<_Doc>> folders = {
    0: [_Doc(900001, 'Hoofdstuk 1', folder: true), _Doc(900002, 'les1.pdf')],
    900001: [],
  };
  final List<(int, String, List<String>)> zones = [
    (900010, 'Taak 1', <String>[]),
  ];
  final List<_News> news = [
    _News(900020, 'Welkom', '<p>Hallo <strong>allemaal</strong></p>'),
    _News(900021, 'Verborgen', '<p>x</p>', visible: false),
  ];
  int _next = 900100;

  final List<String> log = [];
  final List<RequestOptions> writes = [];
  final List<String> uploaded = [];

  /// Whether a write is answered without changing anything.
  bool ignoreWrites = false;

  /// Whether the connection drops before a write is answered.
  bool dropWrites = false;

  String _documentsPage(int parent) {
    final items = folders[parent]!.map((d) {
      final href = d.folder
          ? '/Documents/Admin/Index/courseID/813/parentID/${d.id}/ssID/6161'
          : '/Documents/Download/Index/htm/0/courseID/813/docID/${d.id}/ssID/6161';
      return '<li itemID="${d.id}" id="row_${d.id}"><div class="smsc_cm_body_row">'
          '<div class="name"><a class="smsc_cm_link" name="link" '
          'docID="${d.id}" href="$href">${d.name}</a></div>'
          '${_visibleIcon(d.id, d.visible)}'
          '<div class="until"> ${d.until ?? '-'} </div>'
          '<div class="from"> ${d.from ?? '-'} </div></div></li>';
    }).join();
    return '<html><body><form name="form"><div class="smsc_cm_body">'
        '<ul id="list" courseid="813" parentid="$parent" ssid="6161">$items'
        '</ul></div></form></body></html>';
  }

  String _newsAdmin() =>
      '<html><body><ul id="list" courseid="813" parentid="0" ssid="6161">'
      '${news.map((n) => '<li itemID="${n.id}" id="row_${n.id}">'
          '<div class="name tekst " title="${n.title}">\n${n.title}\n</div>'
          '${_visibleIcon(n.id, n.visible)}'
          '<div class="until">-</div><div class="from">-</div></li>').join()}'
      '</ul></body></html>';

  String _newsPage() =>
      '<html><body><div class="smsc_cm_body">'
      '${news.where((n) => n.visible).map((n) => '<div class="smsc_cm_body_row">'
          '<div class="smsc_cm_body_row_block"><div class="name">${n.title}</div>'
          '<div class="smsc_quick_edit" onclick="window.location=\'/?module=News&file=addNews&newsID=${n.id}&courseID=813&ssID=6161\';">Snel wijzigen</div>'
          '</div><div class="smsc_cm_body_row_block_desc">${n.html}</div></div>').join()}'
      '</div></body></html>';

  String _tree() {
    final children = zones
        .map(
          (z) =>
              '{"attributes":{"id":"uploadmap_${z.$1}","rel":"uploadmap"},'
              '"data":{"title":"${z.$2}"},"hasChildren":false}',
        )
        .join(',');
    return '[{"attributes":{"id":"tree_0","rel":"tree","class":"root"},'
        '"data":{"title":"Uploadzone"},"children":[$children]}]';
  }

  Future<ResponseBody> _write(
    RequestOptions options,
    ResponseBody Function() apply,
  ) async {
    writes.add(options);
    if (dropWrites) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Connection closed',
        error: const SocketException('reset'),
      );
    }
    if (ignoreWrites) {
      return _html('', status: 302, location: '/Documents/Admin/Index');
    }
    return apply();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final path = uri.path;
    final query = uri.queryParameters;
    final method = options.method;
    log.add('$method $path${uri.hasQuery ? '?${uri.query}' : ''}');
    final fields = options.data is Map
        ? (options.data as Map).map((k, v) => MapEntry('$k', '$v'))
        : <String, String>{};

    if (path == '/Topnav/getCourseConfig') {
      return _html(
        '{"own":[{"id":813,"platformId":6161,"name":"testvak","descr":"",'
        '"teacher":"Leerkracht A"},{"id":"x"}],'
        '"titu":[{"id":814,"platformId":6161,"name":"Klas 5A","descr":"5A",'
        '"teacher":"Leerkracht A"}],"community":[]}',
      );
    }
    final admin = RegExp(
      r'^/Documents/Admin/Index/courseID/813/parentID/(\d+)/ssID/6161$',
    ).firstMatch(path);
    if (admin != null) {
      final parent = int.parse(admin[1]!);
      if (!folders.containsKey(parent)) {
        return _html('<html>Geen toegang</html>');
      }
      return _html(_documentsPage(parent));
    }
    if (path == '/Documents/Map/Save/courseID/813/ssID/6161') {
      return _write(options, () {
        final doc = _Doc(
          _next++,
          fields['name']!,
          folder: true,
          visible: fields['visible'] == '1',
        );
        folders[int.parse(fields['parentID']!)]!.add(doc);
        folders[doc.id] = [];
        return _html('', status: 302, location: '/Documents/Admin/Index');
      });
    }
    final multi = RegExp(
      r'^/Documents/Multiupload/(Index|Save)/courseID/813/parentID/(\d+)/ssID/6161$',
    ).firstMatch(path);
    if (multi != null && multi[1] == 'Index') {
      return _html(
        '<form><input type="hidden" name="randomDir" value="madeUpDir123">'
        '</form>',
      );
    }
    if (multi != null) {
      return _write(options, () {
        for (final name in uploaded) {
          folders[int.parse(multi[2]!)]!.add(
            _Doc(_next++, name, visible: fields['visible'] == '1')
              ..from = fields['fromdatecheck'] == '1'
                  ? fields['fromdate']
                  : null
              ..until = fields['untildatecheck'] == '1'
                  ? fields['untildate']
                  : null,
          );
        }
        uploaded.clear();
        return _html('', status: 302, location: '/Documents/Admin/Index');
      });
    }
    if (path == '/Upload/Upload/Index') {
      final form = options.data as FormData;
      uploaded.add(form.files.single.value.filename!);
      return _html('true');
    }
    if (path.startsWith('/Documents/Download/')) {
      return ResponseBody.fromString('inhoud', 200);
    }
    if (path == '/' && query['module'] == 'Uploadzone') {
      if (query['file'] == 'tree') return _html(_tree());
      return _write(options, () {
        final command = fields['command']!;
        final name = RegExp(
          r'<param name="naam"><!\[CDATA\[(.*?)\]\]>',
        ).firstMatch(command)![1]!;
        zones.add((_next++, name, <String>[]));
        return _html(
          '<?xml version="1.0"?><server><response><status>ok</status>'
          '</response></server>',
        );
      });
    }
    if (path == '/' && query['module'] == 'News') {
      switch (query['file']) {
        case 'coursenews_admin':
          return _html(_newsAdmin());
        case 'coursenews':
          return _html(_newsPage());
        case 'addNews':
          return _write(options, () {
            news.add(
              _News(
                _next++,
                fields['title']!,
                fields['message']!,
                visible: fields['visible'] == '1',
              ),
            );
            return _html('', status: 302, location: '/?module=News');
          });
      }
    }
    return _html('not found', status: 404);
  }

  @override
  void close({bool force = false}) {}
}

Map<String, String> _fieldsOf(RequestOptions options) =>
    (options.data as Map).map((k, v) => MapEntry('$k', '$v'));

void main() {
  forbidRealNetwork();

  late _Smartschool server;
  late CourseService courses;
  const course = ManagedCourse(id: 813, platformId: 6161, name: 'testvak');

  setUp(() async {
    server = _Smartschool();
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    client.dio.httpClientAdapter = server;
    courses = CourseService(client);
  });

  test('getCourses reads the own, titular and community courses of the '
      'course menu, skipping one without a numeric id', () async {
    final list = await courses.getCourses();
    expect(list.map((c) => (c.id, c.platformId, c.name, c.kind)), [
      (813, 6161, 'testvak', ManagedCourseKind.own),
      (814, 6161, 'Klas 5A', ManagedCourseKind.titular),
    ]);
    expect(list.last.description, '5A');
    expect(list.first.teacher, 'Leerkracht A');
  });

  group('documents', () {
    test('getDocuments reads a folder\'s items: folders, files with their '
        'download path, visibility and dates', () async {
      final docs = await courses.getDocuments(course);
      expect(docs.map((d) => (d.id, d.name, d.kind)), [
        (900001, 'Hoofdstuk 1', CourseDocumentKind.folder),
        (900002, 'les1.pdf', CourseDocumentKind.file),
      ]);
      expect(docs.first.downloadPath, isNull);
      expect(
        docs.last.downloadPath,
        '/Documents/Download/Index/htm/0/courseID/813/docID/900002/ssID/6161',
      );
      expect(docs.map((d) => d.isVisible), [true, true]);
      expect(docs.first.visibleFrom, isNull);
      expect(await courses.getDocuments(course, folderId: 900001), isEmpty);
    });

    test('getDocuments throws a SmartschoolCourseError for a page without a '
        'list', () async {
      await expectLater(
        courses.getDocuments(course, folderId: 5),
        throwsA(isA<SmartschoolCourseError>()),
      );
    });

    test('createFolder posts the form once and returns the new folder from '
        'the list after it', () async {
      final folder = await courses.createFolder(
        course,
        name: ' Hoofdstuk 2 ',
        parentId: 900001,
        visible: false,
        visibleFrom: DateTime(2026, 12, 1, 8, 5),
      );
      expect(
        (folder.name, folder.kind, folder.isVisible),
        ('Hoofdstuk 2', CourseDocumentKind.folder, false),
      );
      expect(_fieldsOf(server.writes.single), {
        'parentID': '900001',
        'name': 'Hoofdstuk 2',
        'description': '',
        'visible': '0',
        'fromdatecheck': '1',
        'fromdate': '2026-12-01 08:05',
        'untildate': '',
      });
    });

    test('createFolder refuses a name Smartschool does not allow, before '
        'anything is sent', () async {
      for (final name in [' ', 'a/b', '.verborgen']) {
        await expectLater(
          courses.createFolder(course, name: name),
          throwsArgumentError,
        );
      }
      expect(server.log, isEmpty);
    });

    test('a save that is not seen in the list after it is unconfirmed, and '
        'a dropped connection too; neither is sent again', () async {
      server.ignoreWrites = true;
      await expectLater(
        courses.createFolder(course, name: 'X'),
        throwsA(isA<SmartschoolCourseWriteUnconfirmedError>()),
      );
      server
        ..ignoreWrites = false
        ..dropWrites = true;
      await expectLater(
        courses.createFolder(course, name: 'X'),
        throwsA(
          isA<SmartschoolCourseWriteUnconfirmedError>().having(
            (e) => e.cause,
            'cause',
            isA<SmartschoolConnectionError>(),
          ),
        ),
      );
      expect(server.writes, hasLength(2));
    });

    test('uploadDocuments uploads into the form\'s directory, saves it with '
        'the visibility, and returns the new files in order', () async {
      final dir = Directory.systemTemp.createTempSync('course_upload_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = File('${dir.path}/b.txt')..writeAsStringSync('b');
      final b = File('${dir.path}/a.txt')..writeAsStringSync('a');

      final docs = await courses.uploadDocuments(
        course,
        [a.path, b.path],
        folderId: 900001,
        visibleUntil: DateTime(2026, 12, 31, 18),
        notify: true,
      );
      expect(docs.map((d) => (d.name, d.kind, d.visibleUntil)), [
        ('b.txt', CourseDocumentKind.file, '2026-12-31 18:00'),
        ('a.txt', CourseDocumentKind.file, '2026-12-31 18:00'),
      ]);
      expect(_fieldsOf(server.writes.single), {
        'randomDir': 'madeUpDir123',
        'parentID': '900001',
        'visible': '1',
        'fromdate': '',
        'untildatecheck': '1',
        'untildate': '2026-12-31 18:00',
        'sendNotification': '1',
      });
    });

    test('uploadDocuments refuses no files, a missing file and two files of '
        'the same name, before anything is sent', () async {
      final dir = Directory.systemTemp.createTempSync('course_upload_');
      addTearDown(() => dir.deleteSync(recursive: true));
      Directory('${dir.path}/x').createSync();
      final one = File('${dir.path}/a.txt')..writeAsStringSync('a');
      final two = File('${dir.path}/x/a.txt')..writeAsStringSync('a');
      await expectLater(
        courses.uploadDocuments(course, []),
        throwsArgumentError,
      );
      await expectLater(
        courses.uploadDocuments(course, ['${dir.path}/nope.txt']),
        throwsArgumentError,
      );
      await expectLater(
        courses.uploadDocuments(course, [one.path, two.path]),
        throwsArgumentError,
      );
      expect(server.log, isEmpty);
    });

    test('downloadDocument downloads a file, and refuses a folder', () async {
      final docs = await courses.getDocuments(course);
      expect(
        String.fromCharCodes(await courses.downloadDocument(docs.last)),
        'inhoud',
      );
      expect(() => courses.downloadDocument(docs.first), throwsArgumentError);
    });
  });

  group('upload zones', () {
    test('getUploadZones reads the tree', () async {
      expect(
        (await courses.getUploadZones(course)).map((z) => (z.id, z.name)),
        [(900010, 'Taak 1')],
      );
    });

    test('parseUploadZones gives a zone the folders it is in', () {
      final zones = CourseService.parseUploadZones(
        '[{"attributes":{"id":"tree_0"},"data":{"title":"Uploadzone"},'
        '"children":[{"attributes":{"id":"map_5"},"data":{"title":"Map"},'
        '"children":[{"attributes":{"id":"uploadmap_7"},'
        '"data":{"title":"Taak"}}]}]}]',
      );
      expect(zones.single.path, ['Map']);
      expect(
        () => CourseService.parseUploadZones('<html>'),
        throwsA(isA<SmartschoolCourseError>()),
      );
    });

    test('createUploadZone sends saveuploadmap once with the web client\'s '
        'params', () async {
      final zone = await courses.createUploadZone(
        course,
        name: 'Taak 2',
        description: 'Lever hier in',
        visibleFrom: DateTime(2026, 12, 1, 8),
        visibleUntil: DateTime(2026, 12, 15, 18),
        maxFiles: 2,
      );
      expect(zone.name, 'Taak 2');
      final command = _fieldsOf(server.writes.single)['command']!;
      for (final param in [
        '<subsystem>uploadzone</subsystem>',
        '<action>saveuploadmap</action>',
        '<param name="naam"><![CDATA[Taak 2]]></param>',
        '<param name="omschrijving"><![CDATA[Lever hier in]]></param>',
        '<param name="tijd"><![CDATA[1]]></param>',
        '<param name="vanDatum"><![CDATA[2026-12-01 08:00]]></param>',
        '<param name="totDatum"><![CDATA[2026-12-15 18:00]]></param>',
        '<param name="aantal"><![CDATA[2]]></param>',
        '<param name="eigenlezen"><![CDATA[1]]></param>',
        '<param name="medezien"><![CDATA[0]]></param>',
      ]) {
        expect(command, contains(param));
      }
    });

    test('createUploadZone refuses only one date, before anything is '
        'sent', () async {
      await expectLater(
        courses.createUploadZone(
          course,
          name: 'X',
          visibleFrom: DateTime(2026),
        ),
        throwsArgumentError,
      );
      expect(server.log, isEmpty);
    });
  });

  group('news', () {
    test('getNews reads the management list, with each message the news '
        'page shows', () async {
      final items = await courses.getNews(course);
      expect(items.map((n) => (n.id, n.title, n.isVisible)), [
        (900020, 'Welkom', true),
        (900021, 'Verborgen', false),
      ]);
      expect(items.first.html, '<p>Hallo <strong>allemaal</strong></p>');
      expect(items.last.html, isNull);
    });

    test('postNews posts the form once and returns the new item', () async {
      final item = await courses.postNews(
        course,
        title: 'Toets',
        html: '<p>Vrijdag</p>',
      );
      expect((item.title, item.html), ('Toets', '<p>Vrijdag</p>'));
      expect(_fieldsOf(server.writes.single), {
        'store': '1',
        'sendNotification': '0',
        'title': 'Toets',
        'message': '<p>Vrijdag</p>',
        'visible': '1',
      });
      final hidden = await courses.postNews(
        course,
        title: 'Later',
        html: '<p>x</p>',
        visible: false,
        notify: true,
      );
      expect(hidden.isVisible, isFalse);
      expect(_fieldsOf(server.writes.last), isNot(contains('visible')));
      expect(_fieldsOf(server.writes.last)['sendNotification'], '1');
    });
  });
}
