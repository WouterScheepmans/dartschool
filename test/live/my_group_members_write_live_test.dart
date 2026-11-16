// The live member writes of MyGroupsService (#253): an own mail group named
// after the run ("dartschool test <run tag>"), made with create, gets the
// own account as its only member with addMembers, loses it with
// removeMember, gets it again with setMembers, and is emptied with
// clearMembers; each change is checked with members (the members page and
// the member picker's selection). The group is deleted again. No one but
// the own account is ever a member, and no other own group is changed.
//
// **Opt-in twice**: local and on demand only, as messages_live_test.dart
// (see there and dart_test.yaml), and only with
// DARTSCHOOL_LIVE_MY_GROUPS_WRITE=1 in the environment (as
// my_groups_write_live_test.dart, #252), since it writes in the account's
// own groups:
//
//   DARTSCHOOL_LIVE_MY_GROUPS_WRITE=1 \
//     dart test -P live test/live/my_group_members_write_live_test.dart
//
// Without a credentials.yml in the package root, or without that variable,
// it skips.
//
// The library posts the members form with `X-Requested-With`, as every form
// POST of the client; the live research of the issue posted it without.
// This run is what checks that Smartschool answers it with the members page
// all the same.
//
// At the end, also when a test failed, it deletes every own group named
// after the run that the list still has, and checks that the other own
// groups are as they were at the start (IDs, names and descriptions).
// LiveWireGuard (support/live_wire_guard.dart) refuses on the wire a new
// selection (`confirm Selection`) that names anyone but the own account, a
// post of the members form or a removal of a member of any group but the
// run's, and the removal of anyone but the own account. As every live run,
// it takes the lock of the session first, logs in at most once, and prints
// no credential, no cookie and no name.
//
// It does not call forbidRealNetwork(): it talks to the live Smartschool on
// purpose (see network_guard_test.dart).
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/live_client.dart';
import 'support/live_run.dart';
import 'support/live_wire_guard.dart';

/// The variable that lets the live suite write in the own groups (#252).
const _optInVariable = 'DARTSCHOOL_LIVE_MY_GROUPS_WRITE';

/// [groups] as (ID, name, description), to compare.
List<(int, String, String)> _rows(Iterable<MyGroup> groups) => [
  for (final group in groups) (group.id, group.name, group.description),
];

void main() {
  final credentials = liveCredentialsFile();
  final optedIn = Platform.environment[_optInVariable]?.trim() == '1';

  group(
    'live, the members of the own mail group of the run (#253):',
    skip: credentials == null
        ? 'no credentials.yml in the package root; the live suite needs one '
              '(#57)'
        : !optedIn
        ? 'changes the members of an own mail group it makes; set '
              '$_optInVariable=1 to run it'
        : null,
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      LiveRun? started;
      late LiveRun run;
      late MyGroupsService groups;

      /// The own groups at the start: the run changes none of them.
      late List<MyGroup> before;

      /// The name of the run's group.
      late String name;

      /// The run's group.
      late MyGroup made;

      bool isRuns(MyGroup group) => group.name.startsWith(name);

      /// The user IDs of the members of the run's group, as members reads
      /// them.
      Future<List<int>> memberIds() async => [
        for (final member in await groups.members(made)) member.userId,
      ];

      setUpAll(() async {
        run = started = await LiveRun.start(credentials!);
        groups = MyGroupsService(run.client);
        name = '$liveMyGroupPrefix ${run.tag}';
        before = await groups.list();
        if (before.any(isRuns)) {
          throw StateError('An own group is named after this run already.');
        }
        print('${before.length} own groups at the start');
        made = await groups.create(name: name, description: '#253');
        print('made $made');
      });

      tearDownAll(() async {
        try {
          final failures = <String>[];
          if (started != null) {
            // Every group named after the run that the list still has.
            for (final group in (await groups.list()).where(isRuns)) {
              try {
                await groups.delete(group);
              } on Object catch (e) {
                failures.add('$group: $e');
              }
            }
            final after = await groups.list();
            expect(after.where(isRuns), isEmpty, reason: 'left behind');
            expect(
              _rows(after),
              _rows(before),
              reason: 'the other own groups must be as they were',
            );
          }
          if (failures.isNotEmpty) {
            fail('Could not delete the run\'s group: ${failures.join('; ')}');
          }
        } finally {
          await started?.close();
        }
      });

      test('the new group has no members', () async {
        expect(await memberIds(), isEmpty);
      });

      test('refused before anything is sent: no people, a person of another '
          'school, one whose school is not known', () async {
        final sent = run.guard.requestsSent;
        // Made-up people: none of them is sent.
        const otherSchool = MessageSearchUser(
          userId: 900021,
          displayName: 'Wouters Koen',
          ssId: 900,
          otherSchool: true,
        );
        const unknown = MessageSearchUser(
          userId: 900022,
          displayName: 'Wouters Koen',
          ssId: 900,
        );

        await expectLater(
          groups.setMembers(made, const []),
          throwsArgumentError,
        );
        await expectLater(
          groups.addMembers(made, [otherSchool]),
          throwsArgumentError,
        );
        await expectLater(
          groups.addMembers(made, [unknown]),
          throwsArgumentError,
        );

        expect(run.guard.requestsSent, sent);
      });

      test('addMembers: the own account is the only member, with its '
          'platform; adding it again changes nothing', () async {
        expect(run.own.otherSchool, isFalse);

        expect(await groups.addMembers(made, [run.own]), isTrue);

        final members = await groups.members(made);
        expect(members.map((m) => m.userId), [run.own.userId]);
        expect(members.single.ssId, run.own.ssId);
        expect(members.single.isUser, isTrue);
        expect(run.guard.myGroupSelections, 1);
        expect(run.guard.myGroupMemberSaves, 1);

        expect(await groups.addMembers(made, [run.own]), isFalse);
        expect(run.guard.myGroupSelections, 1);
        expect(run.guard.myGroupMemberSaves, 1);
      });

      test('removeMember: the own account is no member any more; removing '
          'it again changes nothing', () async {
        final member = (await groups.members(
          made,
        )).where((m) => m.userId == run.own.userId);
        if (member.isEmpty) {
          markTestSkipped('the own account was not added');
          return;
        }

        expect(await groups.removeMember(made, member.single), isTrue);

        expect(await memberIds(), isEmpty);
        expect(run.guard.myGroupMemberRemovals, 1);
        expect(await groups.removeMember(made, member.single), isFalse);
        expect(run.guard.myGroupMemberRemovals, 1);
      });

      test('setMembers: the own account is the only member again; setting it '
          'again changes nothing', () async {
        final saves = run.guard.myGroupMemberSaves;

        expect(await groups.setMembers(made, [run.own]), isTrue);

        expect(await memberIds(), [run.own.userId]);
        expect(await groups.setMembers(made, [run.own]), isFalse);
        expect(run.guard.myGroupMemberSaves, saves + 1);
      });

      test('clearMembers: the group has no members; clearing it again '
          'changes nothing', () async {
        if ((await memberIds()).isEmpty) {
          expect(await groups.addMembers(made, [run.own]), isTrue);
        }
        final saves = run.guard.myGroupMemberSaves;

        expect(await groups.clearMembers(made), isTrue);

        expect(await memberIds(), isEmpty);
        expect(await groups.clearMembers(made), isFalse);
        expect(run.guard.myGroupMemberSaves, saves + 1);
      });
    },
  );
}
