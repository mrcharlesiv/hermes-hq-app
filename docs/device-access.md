# Device Access

Settings › Device Access lets the owner's bots use things on this phone: contacts, location, reminders, calendar,
alarms and timers, photos, Health, motion, music, and email or text drafts. Everything starts off.

## How a request travels

1. A bot calls a tool. The tools come from the hermes-hq-push add-on's `device_access.py`: Contacts since 0.9.19, every
   other kind since 0.9.21. A bot sees a kind's tool only while some phone shares that kind.
2. The add-on saves the request and wakes the phone with a silent push (`kind: "device"`).
3. The add-on waits 25 seconds. If nothing has come back, the bot gets `waiting` with a `request_id` it can check later
   with `device_request_result`.
4. The phone runs `POST /device-access/<device>/pending`. It does this on the wake-up push, when the app comes back on
   screen, and after sign-in. `DeviceAccessCenter` checks each request against this phone's switches
   (`DeviceAccess.check`), then runs it through its kind's handler (`DeviceAccessHandlers`).
5. The phone posts the answer to `POST …/results/<id>` as `{status: done|failed|unavailable, result, error}`. A photo is
   posted first to `POST …/files/<id>` as `{type, name, data: base64}`. The add-on keeps the file and adds its path to
   the bot's result as `file`.

Handlers get the switches of their kind that are on (`scopes`), and they still keep to them. A handler must answer
within 20 seconds (`DeviceAccessCenter.answerSeconds`). A silent push gives the app about 30 seconds in the background,
and the app may be in the background or the phone locked. A wake-up in the background answers what fits in 26 seconds
all together (`backgroundSeconds`, audit 09-8); each request gets the time left, less 3 seconds for its answer, and the
rest wait for the next fetch (the add-on hands out `pending` and `sent` requests again until answered or 10 minutes
pass). A request past its time is `failed` with "The iPhone took too long to answer."; one that changes something
(`DeviceAccess.changingOps`) adds "It may still have done it: check before asking again." (09-9).
Nothing asked or found is logged: only the request's op, its outcome and a count. Recent Requests keeps the last 50 on
the phone: Answered, Unavailable (a switch off, iOS's permission, the app closed or the device locked, something this
device can't do), Failed, or Answer Not Sent when posting the answer back failed (09-13, 09-9).

What bots hear names the device and the app as they are ("on this Mac", "Hermes HQ isn’t allowed…"), since a bot
may say it back (09-12). The words below are an iPhone's.

The Settings page: a switch left on after iOS Settings took the permission away can still be turned off (09-3). A
switch this device can't have (Text Message Drafts on the Mac, Motion & Fitness without motion sensing) says why in an
alert and stays off (09-10). The first-time question says which way things go: drafts and alarms are written on the
device by the bots (09-14). On Your Gateway tells a missing add-on ("Not Installed") from the old dispatch-push one
("Update Needed") by asking the old route after a 404 (09-15).

## Switches (scopes)

Each kind's switches are named by the key the add-on uses for them.

| Kind | Switches |
|---|---|
| contacts | phone, email, birthday, address |
| location | city, address, exact (one level; the add-on hears the lower levels too), locked |
| reminders | read, write |
| calendar | read, write |
| alarms | set |
| photos | find, send |
| health | one per Health type, keyed by its HealthKit identifier (`HealthCatalog`; see Health below) |
| motion | activity |
| music | nowPlaying, control |
| drafts | email, text |

## Requests

Dates the bot sends:
- `"2026-11-01"`: the start of that day, here.
- `"2026-11-01T09:30"`: that time here.
- `"…Z"` or `"…-05:00"`: that time, in the zone given.

Dates the phone sends back:
- A moment: `DeviceAccess.stamp(date)`, as in `2026-11-01T09:30:00-05:00`.
- A day: `DeviceAccess.day(date)`, as in `2026-11-01`.

Ids are the system's own identifiers: EventKit's `calendarItemIdentifier` for reminders and its `eventIdentifier` for
events (audit 09-16), PhotoKit's `localIdentifier`, AlarmKit's UUID.

A missing argument takes the default shown in the tables below. A bad argument is answered with
`.failed("<plain words>")`.

### Contacts

- **Switches:** any
- **Request:** `contacts.search`
- **Arguments:** `query` (a name, email address or phone number); `fields?` (array)
- **Result:** `{contacts: [{name, organization?, phones?, emails?, birthday?, addresses?}], count, more?}`
- **Rules:** at most 10 matches. Only the details whose switches are on.

### Location

- **Switches:** city, address or exact
- **Request:** `location.get`
- **Arguments:** `precision?`, one of `city`, `address`, `exact`. Default: the level shared. The phone gives the lower of
  the asked level and the shared one.
- **Result:**
  - Every level: `{precision, place: {city?, region?, country?}, at, timezone}`
  - Street address adds `place.address` (one line).
  - Exact adds `coordinates: {latitude, longitude, accuracy_m}`.
  - With iOS's Precise Location off (audit 09-7), a street address or exact answer says `precision: "approximate"` and
    adds `note` ("…only roughly where the user is (within about N km)."); the page's footer says so too.

Without the `locked` switch, a request that arrives while the app isn't active comes back as `unavailable`:
"Location needs Hermes HQ open on the iPhone (While Locked is off)." With it on but iOS's Location permission set back to
While Using, the answer is the same with "(Location isn’t set to Always)".

### Reminders

**`reminders.list`** (switch: read)
- **Arguments:**
  - `search?`
  - `list?` (a list's name)
  - `include_completed?`, default false
  - `due_after?`, `due_before?`
  - `limit?`, default 50, at most 100
- **Result:**
  - `{reminders: [R], count, more?, lists: [names]}`
  - Each `R` is `{id, title, notes?, list, due?, priority, completed, completed_at?}`.
  - `priority` is `high`, `medium`, `low` or `none`.

**`reminders.create`** (switch: write)
- **Arguments:** `title`; `notes?`; `due?` (a date, or a date and time); `list?` (default: the default list);
  `priority?`
- **Result:** `{reminder: R}`

**`reminders.update`** (switch: write)
- **Arguments:** `id`; `title?`; `notes?`; `due?` (`null` clears it); `completed?`; `priority?`
- **Result:** `{reminder: R}`

### Calendar

**`calendar.list`** (switch: read)
- **Arguments:**
  - `start?`, default now
  - `end?`, default 7 days after `start`, at most 62 days after it
  - `search?`
  - `calendar?` (a name)
  - `limit?`, default 50, at most 100
- **Result:**
  - `{events: [E], count, more?, calendars: [names]}`
  - Each `E` is `{id, title, start, end, all_day, location?, notes?, calendar}`.
  - `notes` is cut to 500 characters.

**`calendar.create`** (switch: write)
- **Arguments:**
  - `title`
  - `start`: a date only makes an all-day event
  - `end?`, default 1 hour after `start`, or the same day for an all-day event
  - `all_day?`, `location?`, `notes?`
  - `calendar?`, default: the default calendar
- **Result:** `{event: E}`

Bots can add events but can't change or delete them.

### Alarms and timers

All of these need the `set` switch.

| Request | Arguments | Result |
|---|---|---|
| `alarms.set` | `time` ("07:30", 24-hour), `label?`, `repeat?` (array of `mon`…`sun`; day names, `daily`/`everyday`, `weekdays` and `weekends` count too, any other word is `failed`, audit 09-28) | `{alarm: {id, time, label, repeat, next}}`, `repeat` as `mon`…`sun` |
| `alarms.timer` | `seconds` (1 to 86400), `label?` | `{timer: {id, label, ends}}` |
| `alarms.list` | none | `{alarms: [{id, kind: alarm\|timer, time?, ends?, label, repeat?, state}], count}` |
| `alarms.cancel` | `id` | `{cancelled: id}` |

Bots see only the alarms Hermes HQ set. A timer is an alarm at now plus `seconds`.

### Photos

**`photos.search`** (switch: find)
- **Arguments:**
  - `start?`, `end?`
  - `near?`: `{latitude, longitude, radius_km?}`, radius default 1 km, at most 50 km
  - `favorites?`
  - `media?`: `photo`, `video`, `screenshot`, `live` or `any` (the default)
  - `limit?`, default 25, at most 50
- **Result:**
  - `{photos: [P], count, more?}`, newest first
  - Each `P` is `{id, date, kind, width, height, duration_s?, favorite, place?: {latitude, longitude}}`.
  - `place` is rounded to 3 decimals (about 100 m). It comes with Location off too; the Photos footer says so (09-5).

**`photos.get`** (switch: send)
- **Arguments:** `id`; `max_pixels?` (the longest side), default 1600, at most 2048
- **Result:** a JPEG goes up as the answer's `file`, with `{photo: P}`. The add-on adds `file`, the path of its saved
  copy.

### Health

The switches are every kind of data the Health app can share, one per type (`HermesKit/Device/HealthCatalog.swift`),
grouped as the Health app groups them: Activity, Body Measurements, Cycle Tracking, Hearing, Heart, Mental Wellbeing,
Mobility, Nutrition, Respiratory, Sleep, Symptoms, Vitals and Other Data (tester, 2026-11-08). A switch's key
is its type's HealthKit identifier, as in `HKQuantityTypeIdentifierHeartRate`, `HKCategoryTypeIdentifierHeadache`,
`HKWorkoutTypeIdentifier`. A type newer than the phone's iOS isn't listed.

Left out on purpose: clinical records and CDA documents (the entitlement asks for no clinical access), vision
prescriptions and medications (HealthKit asks about those one object at a time), workout routes, heartbeat series, and
the blood pressure and food correlations (their parts are there).

The page: Settings › Device Access › Health lists the groups, each with how many are on ("Off", "3 of 12", "On"), and
Turn Off All Health Data. A group's page has Turn On All (one iOS sheet asks about all of its types) and a switch per
type. While the gateway's add-on is older than 0.9.46 (no `deviceAccessHealthTypes` in its status), the page says bots
can read only steps, sleep, workouts and heart rate.

**The four old switches.** Before hermes-hq-push 0.9.46 Health had four switches: steps, sleep, workouts, heart. Saved
settings turn into their types when they load: steps is step count, walking and running distance, and flights climbed;
sleep is sleep analysis; workouts is workouts; heart is heart rate and resting heart rate. iOS asks nothing new. The
add-on still hears the four, each on while one of its types is, followed by every type that is on (only as `true`): an
older add-on keeps only the four.

- **Request:** `health.summary`. Switches: any Health type.
- **Arguments:**
  - `start?`, default the start of today
  - `end?`, default now; at most 31 days after `start`
  - `format?`: `"types"` (0.9.46 on) for the answer below; without it, the old answer
  - `metrics?`: type keys (at most 250); steps, sleep, workouts and heart stand for their types
  - `categories?`: group keys (`activity`, `bodyMeasurements`, `cycleTracking`, `hearing`, `heart`, `mentalWellbeing`,
    `mobility`, `nutrition`, `respiratory`, `sleep`, `symptoms`, `vitals`, `other`): every type of the group that's on
  - Nothing named: every type that is on.
- **Result** with `format: "types"`:
  - `{range: {start, end}, types: {key: entry}, count, no_data?: [keys], off?: [keys], unknown?: [names],
    trimmed?, note?, left_out?: [keys]}`
  - `no_data`: switched on but nothing in the range. `off`: asked for but switched off. `unknown`: not a type or group
    this phone has.
  - Every entry has `name`, `category`, `kind` and, for a quantity, `unit` (HKUnit's spelling: `count/min`, `km`,
    `kcal`, `mg/dL`…; `%` reads 0–100).
  - `cumulative` (steps, energy, nutrients): `total`, `by_day: {day: total}`.
  - `discrete` (heart rate, weight, blood oxygen): `average`, `min`, `max`, `latest: {value, at}`,
    `by_day: {day: {average, min, max}}`.
  - `category` (symptoms, stand hours, mindful minutes): `count`, `minutes?`, `values?: {name: count}` (mild, severe…),
    `latest`, `by_day: {day: count}`, `more?` past 5,000 samples.
  - `sleep`: `nights: [N]`. `workout`: `workouts: [W]`, `count`, `more?` past 100. `activitySummary`: `days: [{day,
    move_kcal or move_minutes, its goal, exercise_minutes, exercise_goal_minutes, stand_hours, stand_goal_hours}]`.
  - `characteristic` (date of birth, sex, blood type, skin type, wheelchair use, move ring mode): `value`.
  - `electrocardiogram`: `count`, `results: {name: count}`, `average_bpm`, `latest`. `audiogram`: `count`, `latest`.
    `stateOfMind`: `count`, `kinds`, `feelings`, `labels`, `average_valence` (−1 to 1), `latest`. `assessment` (GAD-7,
    PHQ-9): `count`, `latest`, `latest_score`, `latest_risk`.
  - `by_day` comes only for a range of more than a day. An answer over about 48 KB loses entries' `by_day` first (the
    largest first), then whole entries from the end of the page's order (`left_out`), with `trimmed` and `note`
    (`DeviceAccess.healthTrimmed`; the add-on takes 64 KB). Types are read six at a time.
- **Result** without `format` (an add-on before 0.9.46): `{range}`, plus a section for each old switch asked for that
  has a type on (none asked, or none of those on: every one that has):
  - `steps: {steps, distance_km, flights, by_day: [{day, steps}]}`, each part only while its type is on
  - `sleep: {nights: [N]}`
  - `workouts: [W]`
  - `heart: {resting_bpm?, average_bpm?, min_bpm?, max_bpm?}`
- `N` is `{night, asleep_hours, in_bed_hours, stages_hours?: {core, deep, rem, awake}, start, end}`; a night is the
  day a sample starting before 2pm belongs to the night before.
- `W` is `{type, start, end, minutes, energy_kcal?, distance_km?, average_bpm?}`; `type` names every
  HKWorkoutActivityType ("pickleball", "traditional strength training", …).

The add-on's `device_health` (0.9.46) asks with `format: "types"`, and its action `types` lists the types a phone has
on from what the phone last said, without asking it. A bot that names types a phone doesn't share is answered by the
add-on without waking it.

Health is read-only. While the phone is locked, Health can't be read; the answer is `unavailable`: "Health can be read
only while this phone is unlocked."

### Motion

- **Request:** `motion.activity` (switch: activity)
- **Arguments:** `start?`, default 24 hours ago, at most 7 days back; `end?`, default now
- **Result:**
  - `{now: {activity, confidence, since}, periods: [{activity, start, end, minutes}], steps: {today, distance_km, floors_up}}`
  - `activity` is `walking`, `running`, `cycling`, `automotive`, `stationary` or `unknown`.
  - `periods` lists the last 30, merged.
  - `now` only when the window reaches the present (its `end` within 5 minutes of now, audit 09-27).

### Music

| Request | Switch | Arguments | Result |
|---|---|---|---|
| `music.now` | nowPlaying | none | `{state: playing\|paused\|stopped, item?: {title, artist?, album?, duration_s?, position_s?}}` |
| `music.control` | control | `action` (`play`, `pause`, `next` or `previous`; anything else or none is `failed`, audit 09-6); `query?` (for `play`: a song, album, artist or playlist from the library) | the same as `music.now` |

`play` without a `query` resumes.

### Drafts

- **Request:** `drafts.create`. Switches: email or text, depending on `kind`.
- **Arguments:** `kind` (`email` or `text`); `to` (array); `cc?`; `subject?` (email only); `body`
- **Result:** `{draft: "waiting", kind, note}`

The phone keeps the draft and shows a notification. Tapping it opens the Mail or Messages composer, already filled in.
Nothing is sent until the owner taps Send. Drafts still waiting are listed under "Waiting for You" on the Email & Text
Drafts page (tap to open, swipe to delete); each is kept for a day, at most 20.
