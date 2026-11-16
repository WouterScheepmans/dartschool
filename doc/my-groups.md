# Own mail groups

The reference of `MyGroupsService` (#251). The README keeps its overview, with a short example: [`MyGroupsService`](../README.md#mygroupsservice).

## `MyGroupsService`

Every user keeps their own groups of people in Smartschool: "Mijn groepen" in the profile (`/?module=Profile&file=mygroups`, "Stel uw eigen favoriete groepen samen"). The compose form of Messages finds such a group by its name, as a group, so that a message to it goes to all its members: they are personal mail groups. The service reads them: the list of own groups and the members of one. It creates, renames or deletes no group and changes no members.

### Methods

| Method | Returns | Description |
|---|---|---|
| `list()` | `Future<List<MyGroup>>` | The own groups, sorted by name as Smartschool lists them (`GET /?module=Profile&file=mygroups`); an empty list when the user has none. Each `MyGroup` has its `id` (the `mID` of its links), `name` and `description` (`""` when none). |
| `members(group)` | `Future<List<MyGroupMember>>` | The members of an own group, in the order of its members page (by name); an empty list for a group without members. It reads the group's members page (`GET ...&function=users&mID={id}`), and then, in that page's session, the member picker's selection of the group (see below), and checks that both list the same members. Each `MyGroupMember` has its `userId`, `name` (last name first), `ssId` (its platform), `schoolName` (`null` when empty) and `type` (`U`, a person). A group the user does not have (any more) is a `SmartschoolMyGroupNotFoundError`. |
| `findRecipient(group)` | `Future<MessageSearchGroup?>` | The group as a recipient of a message: the `MessageSearchGroup` that `MessagesService.searchRecipientsForCompose` finds for its name with the group's ID as its `groupId` and its name as its `displayName` (seen live, 2026-11-16), or `null`. Pass it to `SendMessageParams.toGroups` (or `ccGroups`, `bccGroups`). A group with a blank name is an `ArgumentError`, before anything is sent. |

### What Smartschool answers

Seen live on 2026-11-16:

- **The list** is an HTML table with a row per group: its name, its description, and the links to edit it, to add people to it (`function=users&mID={id}`) and to delete it, which carry its ID. It does **not escape** a name or a description: a group named `a & "b"` is in the page as `a & "b"`, which the service reads as it is. A name that holds the text of an HTML entity (such as `&amp;`) is read as the character it names; only the group's edit form has such a name exactly. Smartschool strips tags when it saves a name or a description, so neither holds markup.
- **The members page** of a group has a row per member with the member's user ID and name, sorted by name, but not the member's platform (`ssId`), which a change of the members needs (#253). For an ID the user has no group of, Smartschool answers the list instead, with the feedback "De actie werd niet correct uitgevoerd!".
- **The member picker** ("Personen toevoegen" on the members page, Smartschool's general user picker) gives the platform. Loading the members page sets the picker's selection for the group (`usc` `mygroups_{id}`) in the PHP session to the current members, and the picker's dispatcher (`POST /?module=Userselect&file=dispatcher`, form-encoded `command`, the XML command format of the Messages dispatcher) answers the command `userSelect` / `get Items Selected` with that selection (`handle selected items`): each member as an `<item>` with its `type`, `id`, `ssId`, `name` and `schoolname`, or `<items />` for a group without members. The picker's own page did not need to be opened first. Without `X-Requested-With`, Smartschool answers the dispatcher with `302 Location: /?module=Homepage`; the service always sends it, and reports a redirect as a `SmartschoolMyGroupsError`.

The picker's request carries state of the session of the members page, so it is not retried after logging in again, nor sent in another session than the page's: when Smartschool refuses its session, or the client logged in again since the page was loaded, `members` loads the page again (logging in first) and asks the picker once more, and throws a `SmartschoolSessionExpiredError` when that fails too.

A change of the members (the picker's steps, which replace the selection, #253) must not have a load of the group's members page between its steps on the same session. The calls of `members` on one `SmartschoolClient` take turns, also those through another `MyGroupsService` of it. Clients that share one session (one cache folder) do not.

The models never print a name: `MyGroup.toString()` names a group by its ID, `MyGroupMember.toString()` a member by its type, ID and platform. The members of a group are mostly pupils.

Not covered: creating, renaming and deleting a group (#252), adding and removing members (#253), and whether a pupil account has "Mijn groepen" (not tried).

### Errors

| Exception | Thrown when |
|---|---|
| `SmartschoolMyGroupsError` | Smartschool answered with something the service cannot use: another status than `200` (in `statusCode`; a redirect of the picker's request too), another page than the list or the members page, a picker answer that is not `ok` or holds no selection, a row or item without its ID, or a members page and a picker selection that do not list the same members. Never an empty result; its message names a group by its ID only. Not a session problem |
| `SmartschoolMyGroupNotFoundError` | `members`: the user has no own group with that ID (carries the `groupId`). A `SmartschoolMyGroupsError` |

The picker answering with an HTML page is a `SmartschoolUnexpectedPageError`, another answer that is not XML a `SmartschoolParsingError`, as for every XML command. A session Smartschool does not accept, also after logging in again, is a `SmartschoolSessionExpiredError`; no connection a `SmartschoolConnectionError`.
