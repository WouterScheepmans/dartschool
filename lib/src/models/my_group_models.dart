/// An own mail group of the user (#251): a group of "Mijn groepen" in the
/// profile (`/?module=Profile&file=mygroups`, "Stel uw eigen favoriete
/// groepen samen"). Every user keeps their own; the compose form of
/// Messages finds one by its name, as a group, so that a message to it goes
/// to all its members.
///
/// Returned by `MyGroupsService.list`, sorted by name as Smartschool lists
/// them. [toString] names the group by its [id] only: a name can name
/// people.
class MyGroup {
  /// The group's ID: the `mID` of its links in the list. The compose search
  /// of Messages finds the group with this as its `groupId`
  /// (`MyGroupsService.findRecipient`).
  final int id;

  /// The group's name, as the list of own groups shows it.
  ///
  /// The list does not escape it (seen live, 2026-11-16): `&` and `"` are
  /// kept as they are. A name that holds the text of an HTML entity (such as
  /// `&amp;`) is read as the character it names; only the group's edit form
  /// has such a name exactly. Smartschool strips tags when it saves a name,
  /// so it never holds markup.
  final String name;

  /// The group's description, as the list shows it (not escaped either);
  /// `''` when it has none.
  final String description;

  const MyGroup({required this.id, required this.name, this.description = ''});

  @override
  String toString() => 'MyGroup($id)';
}

/// A member of an own mail group ([MyGroup], #251), as
/// `MyGroupsService.members` reads it: from the members page of the group
/// and from Smartschool's member picker (`get Items Selected`), which also
/// gives the member's platform ([ssId]) and school.
///
/// The members of a group are mostly pupils: [toString] names a member by
/// [type], [userId] and [ssId] only, never by [name].
class MyGroupMember {
  /// The member's user ID: the `<id>` of the picker's item, the `id` of the
  /// member's row on the members page.
  final int userId;

  /// The member's name as Smartschool shows it, last name first (the
  /// picker's `<name>`).
  final String name;

  /// The member's platform (school), the picker's `<ssId>`: what the picker
  /// takes, with [userId] and [type], to keep a member in the group when its
  /// members are changed.
  final int ssId;

  /// The member's school, the picker's `<schoolname>`, or `null` when it is
  /// empty.
  final String? schoolName;

  /// The kind of member, the picker's `<type>`: `U` for a person, the only
  /// kind seen live (2026-11-16). The picker also offers classes and
  /// Smartschool groups; what a group holds when one of those is added was
  /// not tried.
  final String type;

  const MyGroupMember({
    required this.userId,
    required this.name,
    required this.ssId,
    this.schoolName,
    this.type = 'U',
  });

  /// Whether the member is a person ([type] `U`).
  bool get isUser => type == 'U';

  @override
  String toString() => 'MyGroupMember($type$userId, ssId: $ssId)';
}
