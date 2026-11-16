// The live own mail groups (#251): what MyGroupsService reads of the groups
// of "Mijn groepen" of the account of credentials.yml, and of their members.
//
// Local and on demand only, as messages_live_test.dart (see there and
// dart_test.yaml): `dart test -P live test/live` runs it with the other live
// files, `dart test -P live test/live/my_groups_live_test.dart` alone.
// Without a credentials.yml in the package root, it skips.
//
// It only reads: the list of own groups and a group's members page with
// GETs, the member picker's selection of a group with its one command that
// reads (`userSelect` / `get Items Selected`), and a recipient search on a
// compose form, which LiveWireGuard (support/live_wire_guard.dart) lets out;
// the guard refuses the picker's `confirm Selection` and the GET that
// deletes a group. It creates, changes and deletes no group and no member.
// The members of a group are mostly pupils: it prints no name of a member
// (nor of a group), only IDs and counts. As every live run, it takes the
// lock of the session first, logs in at most once, and prints no credential
// and no cookie.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';

void main() {
  final credentials = liveCredentialsFile();

  group(
    'live, read only:',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : null,
    timeout: const Timeout(Duration(minutes: 2)),
    () {
      LiveRun? started;
      late MyGroupsService groups;
      late List<MyGroup> all;

      setUpAll(() async {
        final run = started = await LiveRun.start(credentials!);
        groups = MyGroupsService(run.client);
        all = await groups.list();
      });

      tearDownAll(() async {
        await started?.close();
      });

      test('list: each own group with an ID of its own and a name', () {
        expect(all.map((g) => g.id).toSet(), hasLength(all.length));
        for (final group in all) {
          expect(group.id, greaterThan(0));
          expect(group.name.trim().isNotEmpty, isTrue, reason: '$group');
        }
        print('${all.length} own groups');
      });

      test('members: the members page and the picker list the same members, '
          'each with a platform', () async {
        if (all.isEmpty) {
          markTestSkipped('the account has no own group');
          return;
        }
        for (final group in all) {
          final members = await groups.members(group);

          expect(
            members.map((m) => m.userId).toSet(),
            hasLength(members.length),
          );
          for (final member in members) {
            expect(member.userId, greaterThan(0));
            expect(member.ssId, greaterThan(0), reason: '$member');
            expect(member.type, 'U', reason: '$member');
            expect(member.name.trim().isNotEmpty, isTrue, reason: '$member');
          }
          print('$group: ${members.length} members');
        }
      });

      test('members: a made-up group ID is a '
          'SmartschoolMyGroupNotFoundError', () async {
        await expectLater(
          groups.members(const MyGroup(id: 999999999, name: 'made up')),
          throwsA(
            isA<SmartschoolMyGroupNotFoundError>().having(
              (e) => e.groupId,
              'groupId',
              999999999,
            ),
          ),
        );
      });

      test('findRecipient: the compose search finds each own group by its '
          'name, with its ID', () async {
        if (all.isEmpty) {
          markTestSkipped('the account has no own group');
          return;
        }
        for (final group in all) {
          final found = await groups.findRecipient(group);

          expect(found, isNotNull, reason: '$group');
          expect(found!.groupId, group.id);
          expect(found.ssId, greaterThan(0), reason: '$group');
        }
      });
    },
  );
}
