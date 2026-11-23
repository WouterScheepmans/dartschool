/// Models for the management of a course (a "vak") by its teacher: the
/// courses the user has, the documents of a course (Documenten), its upload
/// zones (Uploadzone) and its news (Vaknieuws). Read and written by
/// `CourseService`.
library;

/// The kind of a course, as the course menu of the top bar groups them
/// (`POST /Topnav/getCourseConfig`).
enum ManagedCourseKind {
  /// The user's own courses ("Vakken", `own`).
  own('own'),

  /// The courses of the classes the user is the titular of
  /// ("Titularisvakken", `titu`).
  titular('titu'),

  /// The courses of the school community ("Scholengemeenschapsvakken",
  /// `community`).
  community('community');

  const ManagedCourseKind(this.wireName);

  /// The key of the course menu's answer that lists these courses.
  final String wireName;
}

/// A course of the course menu in Smartschool's top bar: its ID and platform
/// (`ssID`), which every course module takes, its name and description, and
/// its teacher as the menu names them.
///
/// Not a course of the Lesfiches module's course list
/// (`LessonContentService.getCourses`): a course made in the course
/// management (`/course/course-management`) is in this list, but not always
/// in that one (seen live, 2026-11-23).
class ManagedCourse {
  /// The course's ID (`id`), the `courseID` of its modules.
  final int id;

  /// The platform of the course (`platformId`), the `ssID` of its modules.
  final int platformId;

  /// The course's name (`name`).
  final String name;

  /// The course's description (`descr`), often its classes; `""` when none.
  final String description;

  /// The teacher the menu names (`teacher`); `Niet beschikbaar` for an old
  /// course, as Smartschool answers it.
  final String teacher;

  /// The group of the course menu the course is in.
  final ManagedCourseKind kind;

  const ManagedCourse({
    required this.id,
    required this.platformId,
    required this.name,
    this.description = '',
    this.teacher = '',
    this.kind = ManagedCourseKind.own,
  });

  /// Reads one course of the menu's answer; `null` when it has no numeric
  /// `id` and `platformId`.
  static ManagedCourse? fromJson(
    Map<String, dynamic> json,
    ManagedCourseKind kind,
  ) {
    final id = _int(json['id']);
    final platformId = _int(json['platformId']);
    if (id == null || platformId == null) return null;
    return ManagedCourse(
      id: id,
      platformId: platformId,
      name: '${json['name'] ?? ''}'.trim(),
      description: '${json['descr'] ?? ''}'.trim(),
      teacher: '${json['teacher'] ?? ''}'.trim(),
      kind: kind,
    );
  }

  @override
  String toString() => 'ManagedCourse($id/$platformId "$name")';
}

/// The kind of an item of a course's documents.
enum CourseDocumentKind {
  /// A folder: it holds documents of its own.
  folder,

  /// An uploaded file, which [CourseDocument.downloadPath] downloads.
  file,

  /// Another item, such as a document made in Smartschool's editor ("Nieuw
  /// document").
  other,
}

/// An item of a folder of a course's documents (Documenten), as its
/// management page lists it
/// (`/Documents/Admin/Index/courseID/{c}/parentID/{folder}/ssID/{s}`).
class CourseDocument {
  /// The item's ID (`itemID`, the `docID` of its links).
  final int id;

  /// Its name as the list shows it.
  final String name;

  /// Whether it is a folder, a file or another item.
  final CourseDocumentKind kind;

  /// The path that downloads a file (`/Documents/Download/Index/...`);
  /// `null` for a folder and another item.
  final String? downloadPath;

  /// Whether pupils see it, as the visibility icon of the list says; `null`
  /// when the list does not say.
  final bool? isVisible;

  /// From when pupils see it, as the list writes it; `null` when it sets
  /// no start.
  final String? visibleFrom;

  /// Until when pupils see it, as the list writes it; `null` when it sets
  /// no end.
  final String? visibleUntil;

  const CourseDocument({
    required this.id,
    required this.name,
    required this.kind,
    this.downloadPath,
    this.isVisible,
    this.visibleFrom,
    this.visibleUntil,
  });

  @override
  String toString() => 'CourseDocument(${kind.name} $id "$name")';
}

/// An upload zone of a course (Uploadzone): a folder pupils upload files
/// into, as the module's tree lists it (`?module=Uploadzone&file=tree`).
class CourseUploadZone {
  /// The upload zone's ID (`mapID`; the tree's `uploadmap_{id}`).
  final int id;

  /// Its name.
  final String name;

  /// The names of the folders of the tree it is in, outermost first; empty
  /// for one at the top.
  final List<String> path;

  const CourseUploadZone({
    required this.id,
    required this.name,
    this.path = const [],
  });

  @override
  String toString() => 'CourseUploadZone($id "$name")';
}

/// A news item of a course (Vaknieuws), as its management list and the
/// news page show it.
class CourseNewsItem {
  /// The item's ID (`newsID`).
  final int id;

  /// Its title.
  final String title;

  /// Its message (HTML) as the news page shows it; `null` when the news
  /// page does not show the item (pupils do not see it).
  final String? html;

  /// Whether pupils see it, as the visibility icon of the list says; `null`
  /// when the list does not say.
  final bool? isVisible;

  /// From when pupils see it, as the list writes it; `null` when it sets
  /// no start.
  final String? visibleFrom;

  /// Until when pupils see it, as the list writes it; `null` when it sets
  /// no end.
  final String? visibleUntil;

  const CourseNewsItem({
    required this.id,
    required this.title,
    this.html,
    this.isVisible,
    this.visibleFrom,
    this.visibleUntil,
  });

  @override
  String toString() => 'CourseNewsItem($id "$title")';
}

int? _int(Object? value) =>
    value is int ? value : int.tryParse('${value ?? ''}'.trim());
