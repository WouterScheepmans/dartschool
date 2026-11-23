# Learning goals

The reference of `GoalService` (#222). The README keeps its overview, with a short example: [`GoalService`](../README.md#goalservice).

## `GoalService`

Smartschool's goal selector is its own app (`/goal/`), which the Lesfiches module and the planner open to pick the learning goals of a lesfiche or a lesson. Its JSON API is under `/goal/selector/api/v1/`; every route names a `GoalLocation` (where the selector is opened: `lessonContent`, the default, `plannerLessonContent`, or `lessonContentNavigator`) and a day (`yyyy-MM-dd`, today by default; curricula can change with the school year). `lessonContent` and `plannerLessonContent` list the same curricula (seen live, 2026-11-01). `lessonContentNavigator` (`lesson-content-navigator`) is the selector's "GO! Navigator" tab of the Lesfiches module: the curricula of the GO!, in answers of the same shapes (seen live, 2026-11-23). See [GO! Navigator](#go-navigator).

### Methods

| Method | Returns | Description |
|---|---|---|
| `getCurricula({location, date})` | `Future<List<CurriculumGroup>>` | The curricula the selector offers, in groups (`GET leerplannen/{location}/list/{date}`), in its order: such as `Overheid SO` (the eindtermen), `Levensbeschouwing SO`, `Andere SO`, `Minidatabanken` (the school's own). A `CurriculumGroup` has its `name` and `curricula` (`CurriculumListItem`: `id`, `title`, `icon`, `isVisible`, `isFavourite`). |
| `getCurriculum(curriculumId, {location, date})` | `Future<Curriculum>` | One curriculum as a tree (`GET leerplannen/{location}/{curriculumId}/{date}`). An ID with another character than a letter, a digit or `-` is an `ArgumentError`, before anything is sent; an ID the selector does not know (`404`) a `SmartschoolCurriculumNotFoundError`. |
| `resolve(goals, {location, date})` | `Future<List<Curriculum>>` | Names stored goals (`LearningGoalRef`s): `POST leerplannen/{location}/{date}` with `{"selection": [{"id", "goalId", "leerplanId", "type"}], "isView": true}`, as the selector does to show the goals of a lesfiche. It answers one tree per curriculum, pruned to the goals asked for and the nodes above them. It only reads, and is retried once after logging in again. Without goals it sends nothing. A goal the selector does not know is left out of its curriculum, and a curriculum it does not know (an LLinkid goal, for instance) is left out (seen live): such a goal has no `findGoal`. |
| `findGoal(curricula, ref)` (static) | `SelectableGoal?` | The goal `ref` in the trees of `resolve` or `getCurriculum`, by its curriculum and ID. |
| `formatDay(date)` (static) | `String` | A day as the routes take it (`yyyy-MM-dd`). |
| `parseCurricula(json)` / `parseCurriculum(json)` / `parseResolved(json)` (static) | | Parse the three answers. |

### The trees

A `Curriculum` has its `id` (the `leerplanId` of its goals), `type`, `leerplanType` (`config.leerplanType`, such as `eindtermen-derde-graad-doorstroom` or `miniDB`: the `type` of its goals' references), `title`, `isDeprecated`, `selectableTypes` (`config.typesThatCanBeSelected`) and `children`. A `CurriculumNode` has its `id`, `type` (`CurriculumNodeType`: `title`, `subtitle`, `part`, `subpart`, `goal`, `goalBasic`, `goalExtension`, or `other` with the selector's name in `typeName`), `title` (HTML for the eindtermen, plain text for a mini-database; `text` gives it as plain text), `prefix` (the number shown before it, such as `01.02`; `null` when empty), `number`, `icon`, `isDeprecated` and `children`.

The eindtermen have headings with goals under them, the goals in HTML with their number in `prefix`; those of the first grade have goals of basic literacy (`goal-basic`) and extension goals (`goal-extension`) too, which can be picked as well. A mini-database has headings, subheadings and goals in plain text.

`Curriculum.goals` lists the nodes the selector lets a user pick (`selectableTypes`), depth first, deprecated ones too: each a `SelectableGoal` with its `node`, the `path` of nodes above it, `titles` (the plain-text titles of the path and the goal) and `ref`, the `LearningGoalRef` to store. `Curriculum.goal(id)` finds one.

A `LearningGoalRef` (`id`, `leerplanId`, `type`) is how a lesfiche or a planned lesson stores a goal: `fromJson` and `toJson` read and write that, `toWire` adds the `goalId` (the same as `id`) that the web clients send. `LessonContentService.changeGoals` and the creates of lesfiches send them, and `LessonContentDetail.goals` reads them (#223, see [`doc/lesson-content.md`](lesson-content.md#lessoncontentservice)); `PlannerService.changeGoals` sets those of an own planned lesson, and `PlannedElementDetail.goals` reads them (#226, see [`doc/planner.md`](planner.md)). For a goal of the selector, `type` is the curriculum's `leerplanType`; goals of other sources have their source there (`llinkid`, `zill`, ...).

The service does not mark curricula as favourites, keep the selector's settings, or read goals of LLinkid, Zill, OVSG, POV or Op Stap.

### GO! Navigator

The Lesfiches module's goal dialog has a second tab, "GO! Navigator", with the curricula of the GO!. It opens the same selector app at the location `lesson-content-navigator` (`GoalLocation.lessonContentNavigator`), with the same three routes (seen live on 2026-11-23):

- `getCurricula(location: GoalLocation.lessonContentNavigator)`: one group, `Navigator`, with some 345 curricula; each one's grade (`Eerste graad`, `Tweede graad`, `Derde graad`) is its `CurriculumListItem.group` (`metadata.group`), since titles such as `Wiskunde` occur in more than one grade.
- `getCurriculum(id, location: GoalLocation.lessonContentNavigator)`: a tree as for the eindtermen, with `leerplanType` `go-navigator`. Its headings are `title`s; its goals have the kinds `normaal-doel`, `mia`, `basisgeletterdheid`, `uitbreiding`, `subgoal-global` and `subgoal-platform` (`config.typesThatCanBeSelected`; `CurriculumNodeType.other`, by `typeName`), nested: a `normaal-doel` can have `subgoal-global`s and `mia`s under it. Their numbers (`prefix`) look like `WD3_01.01.01`.
- `resolve(goals, location: GoalLocation.lessonContentNavigator)`: names stored GO! goals. The other locations answer `[]` for them (seen live), so a lesfiche with goals of both kinds is named with two calls.

A lesfiche stores a GO! goal as any other: a `LearningGoalRef` with the goal's `id`, the curriculum's `leerplanId` and `type` `go-navigator`, sent with `LessonContentService.changeGoals` (the web client sends the same `change-goals` request, seen live). Whether the planner has a navigator location of its own was not checked.

### Errors

| Exception | Thrown when |
|---|---|
| `SmartschoolGoalError` | The selector answered with something the service cannot use: another status than `200` (in `statusCode`), an HTML page, invalid JSON, an unknown shape. Not a session problem |
| `SmartschoolGoalAccessDeniedError` | The selector refused the read with `403`. A `SmartschoolGoalError` |
| `SmartschoolCurriculumNotFoundError` | `getCurriculum`: no curriculum with that ID (`404`; carries the `curriculumId`). A `SmartschoolGoalError` |

A session Smartschool does not accept, also after logging in again, is a `SmartschoolSessionExpiredError`; no connection a `SmartschoolConnectionError`.
