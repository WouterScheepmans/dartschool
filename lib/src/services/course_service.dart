import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;

import '../exceptions.dart';
import '../models/course_models.dart';
import '../session.dart';
import '../xml_interface.dart';
import 'smartschool_uploader.dart';

export '../models/course_models.dart';

/// The management of a course (a "vak") by its teacher: the courses of the
/// course menu, the documents of a course (Documenten), its upload zones
/// (Uploadzone) and its news (Vaknieuws).
///
/// ```dart
/// final courses = CourseService(client);
/// final course = (await courses.getCourses())
///     .firstWhere((c) => c.name == 'testvak');
///
/// // Documents: list a folder, make a folder, upload files into it.
/// final top = await courses.getDocuments(course);
/// final folder = await courses.createFolder(course, name: 'Hoofdstuk 1');
/// await courses.uploadDocuments(course, ['/pad/naar/les1.pdf'],
///     folderId: folder.id);
///
/// // An upload zone for the pupils' work, and a news item.
/// await courses.createUploadZone(course, name: 'Taak 1');
/// await courses.postNews(course, title: 'Welkom', html: '<p>Hallo!</p>');
/// ```
///
/// What Smartschool answers (seen live on 2026-11-23):
/// - **The course menu** (`POST /Topnav/getCourseConfig`) is JSON with the
///   courses of the user in `own`, `titu` and `community`, each
///   `{id, platformId, name, descr, icon, url, teacher}`.
/// - **The documents** of a folder are the management page
///   `/Documents/Admin/Index/courseID/{c}/parentID/{folder}/ssID/{s}`
///   (folder `0` is the top): a `ul#list` with an `li[itemid]` per item,
///   whose link goes to the folder's own page for a folder, and to
///   `/Documents/Download/Index/...` for a file.
/// - **A new folder** is the form of `/Documents/Map/Index/...`, posted to
///   `/Documents/Map/Save/courseID/{c}/ssID/{s}` (`parentID`, `name`,
///   `description`, `visible`, and `fromdatecheck`/`fromdate`,
///   `untildatecheck`/`untildate` as `YYYY-MM-DD HH:MM`); Smartschool
///   answers `302` without the folder's ID.
/// - **Uploaded files** go through the form of
///   `/Documents/Multiupload/Index/...`: its `randomDir` is the upload
///   directory the files are uploaded into (`SmartschoolUploader`), and the
///   form is posted to `/Documents/Multiupload/Save/...` with `randomDir`,
///   `parentID`, the visibility fields and `sendNotification` ("Opslaan en
///   melden" sends `1`); Smartschool answers `302`.
/// - **The upload zones** are the tree of the module (`POST
///   ?module=Uploadzone&file=tree&ssID={s}&courseID={c}` with `id=0`):
///   JSON nodes whose `attributes.id` is `uploadmap_{id}` for an upload
///   zone. A new one is the dispatcher command `uploadzone` /
///   `saveuploadmap` (`POST ?module=Uploadzone&file=dispatcher&function=dispatcher`),
///   answered with `<status>ok</status>`.
/// - **The news** of a course is listed by its management page
///   (`?module=News&file=coursenews_admin`, an `li[itemid]` per item with
///   its title and dates) and shown with its message on the news page
///   (`?module=News&file=coursenews&function=main`). A new item is the
///   form of `?module=News&file=addNews` posted to the same URL (`store`,
///   `sendNotification`, `title`, `message`, `visible`); Smartschool
///   answers `302` to the management page.
///
/// The writes are sent once, never again after logging in, and are
/// confirmed by reading the list after them: an item that was not there
/// before, with the name sent. Anything else after a write went out is a
/// [SmartschoolCourseWriteUnconfirmedError]; a read that cannot be used is
/// a [SmartschoolCourseError].
class CourseService {
  CourseService(this._client) : _uploader = SmartschoolUploader(_client);

  final SmartschoolClient _client;
  final SmartschoolUploader _uploader;

  /// The path of the course menu.
  static const courseMenuPath = '/Topnav/getCourseConfig';

  /// Reads the courses of the course menu: the user's own courses, then
  /// those of the classes the user is the titular of, then those of the
  /// school community, each in the menu's order.
  Future<List<ManagedCourse>> getCourses() async {
    final response = await _client.postFormResponse(courseMenuPath, {});
    final body = response.data ?? '';
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      json = null;
    }
    if (response.statusCode != 200 || json is! Map) {
      throw SmartschoolCourseError(
        'The course menu ($courseMenuPath) gave no list of courses: '
        '${_excerpt(body)}',
        statusCode: response.statusCode == 200 ? null : response.statusCode,
      );
    }
    return [
      for (final kind in ManagedCourseKind.values)
        if (json[kind.wireName] case final List<dynamic> list)
          for (final entry in list)
            if (entry is Map<String, dynamic>)
              ?ManagedCourse.fromJson(entry, kind),
    ];
  }

  // ---------------------------------------------------------------------
  // Documents
  // ---------------------------------------------------------------------

  /// Reads the items of the folder [folderId] of the documents of
  /// [course] (`0`, the default, is the top), in the order of its
  /// management page.
  ///
  /// Throws a [SmartschoolCourseError] when the page has no list of items
  /// (a folder the user cannot manage, or one that does not exist).
  Future<List<CourseDocument>> getDocuments(
    ManagedCourse course, {
    int folderId = 0,
  }) async {
    final response = await _client.getResponse(
      _documentsPath(course, folderId),
    );
    return parseDocuments(response.data ?? '', status: response.statusCode);
  }

  /// Reads the items of a documents management page [html]; see
  /// [getDocuments].
  static List<CourseDocument> parseDocuments(String html, {int? status}) {
    final list = _list(html, 'documents', status);
    return [
      for (final item in list.querySelectorAll('li[itemid]')) ?_document(item),
    ];
  }

  static CourseDocument? _document(html_dom.Element item) {
    final id = int.tryParse(item.attributes['itemid'] ?? '');
    final link = item.querySelector('a.smsc_cm_link');
    if (id == null || link == null) return null;
    final href = link.attributes['href'] ?? '';
    final kind = href.contains('/Documents/Admin/Index/')
        ? CourseDocumentKind.folder
        : href.contains('/Documents/Download/')
        ? CourseDocumentKind.file
        : CourseDocumentKind.other;
    return CourseDocument(
      id: id,
      name: _text(link),
      kind: kind,
      downloadPath: kind == CourseDocumentKind.file ? href : null,
      isVisible: _visibility(item),
      visibleFrom: _date(item, '.from'),
      visibleUntil: _date(item, '.until'),
    );
  }

  /// Makes a folder [name] in the folder [parentId] of the documents of
  /// [course] (`0`, the default, is the top), and returns it as the list
  /// shows it after the save.
  ///
  /// [visible] `false` hides it from pupils; [visibleFrom] and
  /// [visibleUntil] limit when they see it.
  ///
  /// Throws an [ArgumentError], before anything is sent, for a blank name
  /// or one Smartschool does not allow ([SmartschoolUploader.isAllowedName]),
  /// and a [SmartschoolCourseWriteUnconfirmedError] when the save went out
  /// but the list after it has no new folder of that name.
  Future<CourseDocument> createFolder(
    ManagedCourse course, {
    required String name,
    int parentId = 0,
    String description = '',
    bool visible = true,
    DateTime? visibleFrom,
    DateTime? visibleUntil,
  }) async {
    final folderName = name.trim();
    if (folderName.isEmpty || !SmartschoolUploader.isAllowedName(folderName)) {
      throw ArgumentError.value(
        name,
        'name',
        'A folder name must not be blank, nor contain / : * ? " \\ < > |, '
            'nor start or end with a dot',
      );
    }
    _checkWindow(visibleFrom, visibleUntil);
    final before = await getDocuments(course, folderId: parentId);
    return _confirm(
      () => _client.postFormResponse(
        '/Documents/Map/Save/courseID/${course.id}/ssID/${course.platformId}',
        {
          'parentID': '$parentId',
          'name': folderName,
          'description': description,
          'visible': visible ? '1' : '0',
          ..._windowFields(visibleFrom, visibleUntil),
        },
        retryAfterLogin: false,
      ),
      what: 'the new folder "$folderName"',
      read: () => getDocuments(course, folderId: parentId),
      find: (after) => _newOnes(
        before,
        after,
        (d) => d.id,
      ).where((d) => d.name == folderName).firstOrNull,
    );
  }

  /// Uploads the files at [filePaths] into the folder [folderId] of the
  /// documents of [course] (`0`, the default, is the top), each under its
  /// own name, and returns them as the list shows them after the save, in
  /// the order of [filePaths].
  ///
  /// [visible] `false` hides them from pupils; [visibleFrom] and
  /// [visibleUntil] limit when they see them; [notify] sends the pupils a
  /// notification, as "Opslaan en melden" does.
  ///
  /// Throws an [ArgumentError], before anything is sent, for no files, a
  /// file that does not exist, a name Smartschool does not allow, or two
  /// files of the same name; a [SmartschoolAttachmentUploadError] when the
  /// upload of a file fails (nothing is saved then); and a
  /// [SmartschoolCourseWriteUnconfirmedError] when the save went out but
  /// the list after it does not have a new item for every file.
  Future<List<CourseDocument>> uploadDocuments(
    ManagedCourse course,
    List<String> filePaths, {
    int folderId = 0,
    bool visible = true,
    DateTime? visibleFrom,
    DateTime? visibleUntil,
    bool notify = false,
  }) async {
    if (filePaths.isEmpty) {
      throw ArgumentError.value(filePaths, 'filePaths', 'No files to upload');
    }
    final names = <String>[];
    for (final path in filePaths) {
      final file = File(path);
      if (!file.existsSync()) {
        throw ArgumentError.value(path, 'filePaths', 'No such file');
      }
      final name = file.uri.pathSegments.last;
      if (!SmartschoolUploader.isAllowedName(name)) {
        throw ArgumentError.value(
          path,
          'filePaths',
          'Smartschool does not allow the name "$name"',
        );
      }
      if (names.contains(name)) {
        throw ArgumentError.value(
          path,
          'filePaths',
          'Two files are named "$name"',
        );
      }
      names.add(name);
    }
    _checkWindow(visibleFrom, visibleUntil);

    final before = await getDocuments(course, folderId: folderId);
    final query =
        '/courseID/${course.id}/parentID/$folderId'
        '/ssID/${course.platformId}';
    final form = await _client.getResponse(
      '/Documents/Multiupload/Index$query',
    );
    final directory = _randomDir(form.data ?? '');
    if (form.statusCode != 200 || directory == null) {
      throw SmartschoolCourseError(
        'The upload form of the documents gave no upload directory: '
        '${_excerpt(form.data ?? '')}',
        statusCode: form.statusCode == 200 ? null : form.statusCode,
      );
    }
    for (final path in filePaths) {
      await _uploader.uploadFile(
        directory,
        path,
        retryAfterLogin: false,
        sameSessionAs: form,
      );
    }
    return _confirm(
      () => _client.postFormResponse(
        '/Documents/Multiupload/Save$query',
        {
          'randomDir': directory,
          'parentID': '$folderId',
          'visible': visible ? '1' : '0',
          ..._windowFields(visibleFrom, visibleUntil),
          'sendNotification': notify ? '1' : '0',
        },
        retryAfterLogin: false,
        sameSessionAs: form,
      ),
      what: names.length == 1
          ? 'the uploaded file "${names.single}"'
          : 'the ${names.length} uploaded files',
      read: () => getDocuments(course, folderId: folderId),
      find: (after) {
        final added = _newOnes(before, after, (d) => d.id);
        final found = [
          for (final name in names)
            added.where((d) => d.name == name).firstOrNull,
        ];
        return found.contains(null) ? null : found.cast<CourseDocument>();
      },
    );
  }

  /// Downloads the file [document] of [course]'s documents, with at most
  /// [maxBytes] bytes when given (see [SmartschoolClient.download]).
  ///
  /// Throws an [ArgumentError] for an item that is not a file.
  Future<Uint8List> downloadDocument(CourseDocument document, {int? maxBytes}) {
    final path = document.downloadPath;
    if (path == null) {
      throw ArgumentError.value(document, 'document', 'Not a file');
    }
    return _client.download(path, maxBytes: maxBytes);
  }

  // ---------------------------------------------------------------------
  // Upload zones
  // ---------------------------------------------------------------------

  /// Reads the upload zones of [course], in the order of the module's
  /// tree, each with the folders it is in.
  Future<List<CourseUploadZone>> getUploadZones(ManagedCourse course) async {
    final response = await _client.postFormResponse(
      '/',
      {'id': '0'},
      query: {
        'module': 'Uploadzone',
        'file': 'tree',
        'ssID': '${course.platformId}',
        'courseID': '${course.id}',
      },
    );
    return parseUploadZones(response.data ?? '', status: response.statusCode);
  }

  /// Reads the upload zones of the module's tree [json]; see
  /// [getUploadZones].
  static List<CourseUploadZone> parseUploadZones(String json, {int? status}) {
    Object? tree;
    try {
      tree = jsonDecode(json);
    } on FormatException {
      tree = null;
    }
    if ((status != null && status != 200) || tree is! List) {
      throw SmartschoolCourseError(
        'The tree of the upload zones could not be read: ${_excerpt(json)}',
        statusCode: status == 200 ? null : status,
      );
    }
    final zones = <CourseUploadZone>[];
    void walk(List<dynamic> nodes, List<String> path) {
      for (final node in nodes) {
        if (node is! Map) continue;
        final attributes = node['attributes'];
        final id = attributes is Map ? '${attributes['id'] ?? ''}' : '';
        final data = node['data'];
        final title = data is Map ? '${data['title'] ?? ''}'.trim() : '';
        final children = node['children'];
        final zone = RegExp(r'^uploadmap_(\d+)$').firstMatch(id);
        if (zone != null) {
          zones.add(
            CourseUploadZone(
              id: int.parse(zone[1]!),
              name: title,
              path: List.unmodifiable(path),
            ),
          );
        }
        if (children is List) {
          walk(children, id == 'tree_0' ? path : [...path, title]);
        }
      }
    }

    walk(tree, const []);
    return zones;
  }

  /// Makes an upload zone [name] in [course], at the top of its tree, and
  /// returns it as the tree shows it after the save.
  ///
  /// [description] is shown to pupils; [visibleFrom] and [visibleUntil],
  /// both or neither, limit when pupils can upload (without them: always);
  /// [maxFiles] limits how many files a pupil uploads; [visible] `false`
  /// hides it; [classmatesSee] lets pupils see who uploaded what, and
  /// [classmatesRead] read it; [pupilsReadOwn] lets a pupil read their own
  /// files (the module's default).
  ///
  /// Throws an [ArgumentError], before anything is sent, for a blank name,
  /// only one of the dates, or an end before the start; a
  /// [SmartschoolCourseWriteUnconfirmedError] when the save went out but
  /// was not answered with `ok`, or the tree after it has no new upload
  /// zone of that name.
  Future<CourseUploadZone> createUploadZone(
    ManagedCourse course, {
    required String name,
    String description = '',
    DateTime? visibleFrom,
    DateTime? visibleUntil,
    int? maxFiles,
    bool visible = true,
    bool classmatesSee = false,
    bool classmatesRead = false,
    bool pupilsReadOwn = true,
  }) async {
    final zoneName = name.trim();
    if (zoneName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Must not be blank');
    }
    if ((visibleFrom == null) != (visibleUntil == null)) {
      throw ArgumentError(
        'An upload zone takes both visibleFrom and visibleUntil, or neither',
      );
    }
    _checkWindow(visibleFrom, visibleUntil);
    if (maxFiles != null && maxFiles < 1) {
      throw ArgumentError.value(maxFiles, 'maxFiles', 'Must be at least 1');
    }
    final now = _formatDate(DateTime.now());
    final params = {
      'courseID': '${course.id}',
      'ssID': '${course.platformId}',
      'naam': zoneName,
      'omschrijving': description,
      'parentID': '0',
      'tijd': visibleFrom == null ? '0' : '1',
      'vanDatum': visibleFrom == null ? now : _formatDate(visibleFrom),
      'totDatum': visibleUntil == null ? now : _formatDate(visibleUntil),
      'aantal': maxFiles == null ? '' : '$maxFiles',
      'zichtbaar': visible ? '1' : '0',
      'medezien': classmatesSee ? '1' : '0',
      'medelezen': classmatesRead ? '1' : '0',
      'eigenlezen': pupilsReadOwn ? '1' : '0',
      'files_sort': '0',
      'user_group': '0',
      'shareteacher': '0',
      'students_showdefault': '0',
    };
    for (final value in params.values) {
      if (value.contains(']]>')) {
        throw ArgumentError('A value must not contain "]]>"');
      }
    }
    final before = await getUploadZones(course);
    return _confirm(
      () => _client.postFormResponse(
        '/',
        {
          'command': XmlInterface.buildCommand(
            'uploadzone',
            'saveuploadmap',
            params,
          ),
        },
        query: {
          'module': 'Uploadzone',
          'file': 'dispatcher',
          'function': 'dispatcher',
        },
        retryAfterLogin: false,
      ),
      what: 'the new upload zone "$zoneName"',
      answered: (response) =>
          response.statusCode == 200 &&
          (response.data ?? '').contains('<status>ok</status>'),
      read: () => getUploadZones(course),
      find: (after) => _newOnes(
        before,
        after,
        (z) => z.id,
      ).where((z) => z.name == zoneName).firstOrNull,
    );
  }

  // ---------------------------------------------------------------------
  // News
  // ---------------------------------------------------------------------

  /// Reads the news items of [course]: those of its management list, in
  /// its order, each with its message when the news page shows it.
  Future<List<CourseNewsItem>> getNews(ManagedCourse course) async {
    final admin = await _client.getResponse(
      '/',
      query: _newsQuery(course, 'coursenews_admin'),
    );
    final page = await _client.getResponse(
      '/',
      query: {..._newsQuery(course, 'coursenews'), 'function': 'main'},
    );
    return parseNews(
      admin.data ?? '',
      page.data ?? '',
      status: admin.statusCode,
    );
  }

  /// Reads the news items of a management list [adminHtml], with their
  /// messages from the news page [pageHtml]; see [getNews].
  static List<CourseNewsItem> parseNews(
    String adminHtml,
    String pageHtml, {
    int? status,
  }) {
    final list = _list(adminHtml, 'news', status);
    final messages = <int, String>{};
    final page = html_parser.parse(pageHtml);
    for (final row in page.querySelectorAll('.smsc_cm_body_row')) {
      final edit = row.querySelector('.smsc_quick_edit');
      final id = RegExp(
        r'newsID=(\d+)',
      ).firstMatch(edit?.attributes['onclick'] ?? '')?[1];
      final desc = row.querySelector('.smsc_cm_body_row_block_desc');
      if (id != null && desc != null) {
        messages[int.parse(id)] = desc.innerHtml.trim();
      }
    }
    return [
      for (final item in list.querySelectorAll('li[itemid]'))
        if (int.tryParse(item.attributes['itemid'] ?? '') case final id?)
          CourseNewsItem(
            id: id,
            title:
                item.querySelector('.name')?.attributes['title']?.trim() ??
                _text(item.querySelector('.name')),
            html: messages[id],
            isVisible: _visibility(item),
            visibleFrom: _date(item, '.from'),
            visibleUntil: _date(item, '.until'),
          ),
    ];
  }

  /// Posts a news item [title] with the message [html] in [course], and
  /// returns it as the list shows it after the save.
  ///
  /// [visible] `false` hides it from pupils; [notify] sends them a
  /// notification, as "Opslaan en melden" does.
  ///
  /// Throws an [ArgumentError], before anything is sent, for a blank title,
  /// and a [SmartschoolCourseWriteUnconfirmedError] when the save went out
  /// but the list after it has no new item of that title.
  Future<CourseNewsItem> postNews(
    ManagedCourse course, {
    required String title,
    required String html,
    bool visible = true,
    bool notify = false,
  }) async {
    final newsTitle = title.trim();
    if (newsTitle.isEmpty) {
      throw ArgumentError.value(title, 'title', 'Must not be blank');
    }
    final before = await getNews(course);
    return _confirm(
      () => _client.postFormResponse(
        '/',
        {
          'store': '1',
          'sendNotification': notify ? '1' : '0',
          'title': newsTitle,
          'message': html,
          if (visible) 'visible': '1',
        },
        query: _newsQuery(course, 'addNews'),
        retryAfterLogin: false,
      ),
      what: 'the news item "$newsTitle"',
      read: () => getNews(course),
      find: (after) => _newOnes(
        before,
        after,
        (n) => n.id,
      ).where((n) => n.title == newsTitle).firstOrNull,
    );
  }

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  /// Sends the write [send] once, and confirms it by reading the list with
  /// [read] and finding the result in it with [find].
  ///
  /// The write is confirmed by an answer [answered] accepts (by default a
  /// `302`, the redirect of a saved form) and a result [find] finds.
  Future<T> _confirm<T, L>(
    Future<Response<String>> Function() send, {
    required String what,
    required Future<L> Function() read,
    required T? Function(L list) find,
    bool Function(Response<String> response)? answered,
  }) async {
    Response<String> response;
    try {
      response = await send();
    } on SmartschoolConnectionError catch (error) {
      throw SmartschoolCourseWriteUnconfirmedError(
        'The save of $what went out, but no answer came in: it may or may '
        'not have been made.',
        cause: error,
      );
    }
    final accepted =
        answered?.call(response) ??
        (response.statusCode == 302 || response.statusCode == 200);
    if (!accepted) {
      throw SmartschoolCourseWriteUnconfirmedError(
        'Smartschool did not confirm the save of $what: '
        '${_excerpt(response.data ?? '')}',
        statusCode: response.statusCode,
      );
    }
    L list;
    try {
      list = await read();
    } catch (error) {
      throw SmartschoolCourseWriteUnconfirmedError(
        'The save of $what went out, but the list after it could not be '
        'read: it may or may not have been made.',
        cause: error,
      );
    }
    final found = find(list);
    if (found == null) {
      throw SmartschoolCourseWriteUnconfirmedError(
        'The save of $what went out, but the list after it does not show '
        'it.',
      );
    }
    return found;
  }

  static Iterable<T> _newOnes<T>(
    List<T> before,
    List<T> after,
    int Function(T item) id,
  ) {
    final known = {for (final item in before) id(item)};
    return after.where((item) => !known.contains(id(item)));
  }

  static String _documentsPath(ManagedCourse course, int folderId) =>
      '/Documents/Admin/Index/courseID/${course.id}/parentID/$folderId'
      '/ssID/${course.platformId}';

  static Map<String, String> _newsQuery(ManagedCourse course, String file) => {
    'module': 'News',
    'file': file,
    'courseID': '${course.id}',
    'ssID': '${course.platformId}',
  };

  /// The `ul#list` of a management page, or a [SmartschoolCourseError].
  static html_dom.Element _list(String html, String what, int? status) {
    final list = html_parser.parse(html).querySelector('ul#list');
    if ((status != null && status != 200) || list == null) {
      throw SmartschoolCourseError(
        'The page of the $what has no list: ${_excerpt(html)}',
        statusCode: status == 200 ? null : status,
      );
    }
    return list;
  }

  static String _text(html_dom.Element? element) =>
      (element?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

  static String? _date(html_dom.Element item, String selector) {
    final text = _text(item.querySelector(selector));
    return text.isEmpty || text == '-' ? null : text;
  }

  /// Whether the visibility icon of a list item says pupils see it.
  static bool? _visibility(html_dom.Element item) {
    final icon = item.querySelector('[id^="visibleImg"]');
    if (icon == null) return null;
    // Seen live (2026-11-23): `ico visible` or `ico not_visible`.
    final classes = icon.classes;
    if (classes.contains('not_visible')) return false;
    return classes.contains('visible') ? true : null;
  }

  static String? _randomDir(String html) {
    final input = html_parser
        .parse(html)
        .querySelector('input[name="randomDir"]');
    final value = input?.attributes['value']?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static void _checkWindow(DateTime? from, DateTime? until) {
    if (from != null && until != null && !until.isAfter(from)) {
      throw ArgumentError('visibleUntil must be after visibleFrom');
    }
  }

  static Map<String, String> _windowFields(DateTime? from, DateTime? until) => {
    if (from != null) 'fromdatecheck': '1',
    'fromdate': from == null ? '' : _formatDate(from),
    if (until != null) 'untildatecheck': '1',
    'untildate': until == null ? '' : _formatDate(until),
  };

  /// [date] as the modules' date fields take it: `YYYY-MM-DD HH:MM`.
  static String _formatDate(DateTime date) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}';
  }

  static String _excerpt(String body) {
    final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.isEmpty
        ? 'an empty answer'
        : text.length > 120
        ? '"${text.substring(0, 120)}..."'
        : '"$text"';
  }
}
