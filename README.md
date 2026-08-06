# SmartAlarm

A traffic-aware wake alarm for iOS 26. It works backwards from *when you need to arrive* to
*when you need to wake*, re-checking traffic as the morning approaches and adjusting the
system alarm — but only in directions that make you safer.

```
Leave-by = Desired arrival − Estimated drive − Arrival buffer
Wake     = Leave-by − Get-ready
```

Requires **Xcode 26+** and **iOS 26.1+**. Open `SmartAlarm.xcodeproj` and run.

The icon is the app's idea in one shape: a dial carrying two markers — when you wake and when
you have to leave — with the get-ready window drawn as the arc between them, on a dawn
gradient. Light, dark and tinted variants live in `SmartAlarm/Assets.xcassets`; the generator
that drew them is in `Tools/make_icon.py`, so the mark can be re-rendered rather than
hand-patched.

---

## The governing idea: asymmetric risk

Waking ten minutes early costs you ten minutes. Waking ten minutes late costs you the
meeting. Every ambiguous decision in this app therefore resolves toward *earlier*:

| Situation | Behaviour |
|---|---|
| Traffic worsens | Alarm moves earlier — always, with no gating, right up to the moment it rings |
| Traffic improves, early in the morning | Alarm may move later |
| Traffic improves, inside the lock window | Change is **rejected** and logged |
| Traffic improves *implausibly* | Held until a second check agrees |
| Traffic worsens while you're getting ready | Leave-by alarm moves earlier; the wake time is left alone |
| You snooze | Snooze length is capped by the slack left before leave-by |
| You snooze anyway | A second system alarm fires at leave-by |
| Leave-by has already passed | The stale leave alarm is cancelled rather than left to mislead |
| Rain, snow or ice forecast | Extra padding, because forecasts lead the traffic model |
| A check fails | Last known-good alarm time is kept |
| Background refresh never runs | Alarm still rings, at the conservative time set the night before |
| Calendar is empty, stale, or unreadable | Alarm is unaffected — the calendar can only pull it earlier |

Those last two are why the padding is front-loaded rather than applied late: correctness must
not depend on iOS choosing to run a background task.

---

## Three problems the original spec didn't account for

**1. The formula is circular.** `leaveBy = arrival − driveTime(leaveBy) − buffer`, but the
drive time depends on when you leave. `WakeTimeSolver` iterates to a fixed point: guess a
departure, ask for a drive time, derive a better departure, repeat. It settles in one or two
rounds and is capped at three, because MapKit throttles.

**2. `CLGeocoder` is deprecated in iOS 26** (`API_DEPRECATED("Use MapKit", ios(5.0, 26.0))`).
This uses `MKGeocodingRequest` instead. Likewise `MKMapItem(placemark:)` → `MKMapItem(location:address:)`.

**3. AlarmKit needs a widget extension.** `AlarmAttributes` is an `ActivityAttributes`, so
without an `ActivityConfiguration` there is nowhere for the Lock Screen or Dynamic Island to
draw. Hence the second target.

---

## Layout

```
SmartAlarmShared/     Types shared by the app and widget (Coordinate, TrafficCondition,
                      WakeAlarmMetadata). Membership in both targets.
SmartAlarm/
  Core/Logic/         Pure. No MapKit, EventKit, AlarmKit, WeatherKit or SwiftData imports,
                      and no clock of its own — every decision is a function of its arguments,
                      so all of it is unit-tested without a simulator.
                      WakeTimeSolver · AdjustmentPolicy · SchedulePhase · HistoricalTravelModel
                      EventImportance · DrivingWeather · PostureAdvisor
  Core/Models/        SwiftData: UserSettings, AlarmPlan, CheckLog, TravelSample, RouteBaseline
  Core/Services/      Protocols + live implementations (swappable)
  Core/Coordinator/   WakePlanner, BackgroundRefreshController, AppEnvironment, DateProvider
  Features/           Today, Setup, History, Debug
SmartAlarmWidget/     Live Activity (Lock Screen / Dynamic Island) + home-screen widget
SmartAlarmTests/      131 tests, logic + planner integration
```

### Swapping the traffic provider

Everything upstream of `TrafficProviding` deals in `Coordinate` and `TravelEstimate`, never in
`MKRoute`. A Google Directions implementation means one new conformance and one line in
`AppEnvironment.init`:

```swift
protocol TrafficProviding: Sendable {
    func estimate(from: Coordinate, to: Coordinate, departingAt: Date) async throws -> TravelEstimate
}
```

`GeocodingProviding`, `CalendarProviding`, `WeatherProviding` and `AlarmScheduling` follow the
same pattern.

---

## How the drive estimate is built

```
base       = what MapKit says for that future departure time
spreadPad  = (historical p80 − p50) × posture      ← how much this route swings at this hour
horizonPad = base × 8% × min(1, minutesOut / 180)  ← predictive ETAs are soft far out
weatherPad = base × forecast severity              ← 0% clear … 35% ice
estimate   = clamp(base + spreadPad + horizonPad + weatherPad, minTravel, maxTravel)
```

`horizonPad` shrinks as departure approaches, which naturally produces *later* proposals as
confidence rises. That is intended, and is exactly what the lock window exists to gate.

The **Why this time?** screen itemises every one of these terms. An alarm whose reasoning is
opaque is one you set a backup for, and a backup alarm defeats the whole feature.

### Historical model

Built from the app's own logged estimates — no location permission, no geofencing. One sample
per morning is recorded during the *locked* phase, the check closest to actual departure and
so the nearest thing to ground truth available. Samples are bucketed by `(route, weekday,
15-minute departure window)` on a 12-week rolling window, and the model declines to answer
below four samples rather than guessing.

It's used to seed the fixed-point solve, to size the spread padding, as an offline fallback,
and to flag a morning as anomalous when live traffic exceeds the historical p90.

### Traffic classification

MapKit exposes no congestion field. `RouteBaseline` caches a free-flow reference (an ETA for a
3:30 a.m. Sunday departure, refreshed monthly); `live ÷ free-flow` gives light / moderate /
heavy. Without a baseline the condition is honestly reported as `unknown` rather than guessed.

The baseline is captured on foreground as well as nightly. It has to be: when only the 22:00
background task wrote it, a fresh install reported "unknown" indefinitely, because there was
never anything to compare against. It self-cancels once a baseline under 30 days old exists, so
this costs one extra request on first run and nothing after.

### Recomputing after a settings change

Changing get-ready time changes the arithmetic, not the traffic. Setup watches a single
`planSignature` hash covering every setting that moves the wake time — rather than wiring a
recompute onto fifteen individual controls and eventually forgetting one — debounces for
600 ms, and recomputes from the cached drive estimate without a network round trip.

---

## Proving it works before you trust it

The app's central claim — that it rings through a silenced, force-quit phone — is one nobody
should have to take on faith at 6 a.m. **"Ring a test alarm in 1 minute"** on the Today screen
schedules a throwaway alarm on its own identifier, so you can lock the phone, flip the ringer
switch and hear it for yourself. It also gives an App Store reviewer a sixty-second path to
seeing the app work rather than waiting until tomorrow morning.

Alongside it, the Today screen says **how many mornings the estimate rests on**. The padding
maths is invisible, and the number it produces looks equally authoritative on forty mornings of
data or none. Below four recorded mornings the model declines to answer and a conservative
default is used — the user is told that, rather than being handed a confident-looking number
built on nothing.

## Bedtime

The app spends all its effort on when to wake you and, until now, said nothing about the other
end of the night — the half you can actually control. Set a sleep target and the Today screen
shows the asleep-by time that would hit it.

## The home-screen widget

Small, medium, and Lock Screen (rectangular and inline) families showing the wake time, leave-by
and drive estimate.

The widget is **read-only by design**: it renders a `WakePlanSnapshot` the app wrote and never
computes anything itself, so all the safety logic stays in one place and the widget can't
disagree with the app. The snapshot travels through an App Group rather than sharing the
SwiftData store, which avoids coordinating schema migrations across two processes.

Every path degrades rather than throws. If the App Group entitlement is missing — an unsigned
build, a bad provisioning profile — `SharedStore.isAvailable` is false, the app skips writing,
and the widget shows its placeholder. A missing widget is a much better outcome than an alarm
app that crashes over one.

## The leave-by backstop

Waking you at the right minute is only half the job. The app schedules **two** system alarms
per morning:

| | Fires at | Snooze |
|---|---|---|
| Wake alarm | Computed wake time | Yes, capped by remaining slack |
| Leave alarm | Computed leave-by time | No — there is nothing left to trade |

Both are real AlarmKit alarms, so they fire even if the app has been force-quit. Snooze length
is recomputed on every reschedule as `min(your preference, slack − 5 min)`: three nine-minute
snoozes would otherwise consume a thirty-minute get-ready window entirely.

Checks keep running through the `gettingReady` phase, because the drive can still fall apart
while you're in the shower. When it does, the leave alarm moves earlier with it — but the wake
time is never touched, since it is already in the past. And if traffic collapses far enough
that leave-by has *already* passed, the stale alarm is cancelled rather than left to go off
later and cheerfully tell you to leave.

## Weather

The forecast is the one input that reliably *leads* the traffic model rather than trailing it:
a provider asked about a departure six hours away leans on historical patterns, and history
doesn't know it will be sleeting tomorrow. `DrivingWeather` collapses WeatherKit's thirty-odd
conditions into the handful that change a drive time, worst-case-wins, and adds 0% (clear) to
35% (ice).

WeatherKit needs its own capability on the App ID. On an unsigned build it simply fails — and
failing means "no extra padding", the same answer as a clear morning. It can never block a
check.

## Learning from outcomes

Without location tracking the app never finds out whether it actually got you there on time.
One tap on the Today screen — *Made it / Was late / Didn't go* — is the only ground truth it
gets, and `PostureAdvisor` calibrates against it.

The two directions are deliberately asymmetric. Suggesting you wake **earlier** needs 8
mornings and a 20% late rate. Suggesting you trade margin for **sleep** needs 20 mornings with
a spotless record — because that is the call whose downside is the thing you were paying to
avoid.

## Running cost, and why the paywall is where it is

The app is designed to cost its developer **$99/year and nothing else**, at any number of free
users.

| | Cost |
|---|---|
| Apple Developer Program | $99/year |
| MapKit — routing, geocoding, the entire core feature | **$0**, no key, no quota billing |
| AlarmKit, EventKit, SwiftData, BackgroundTasks | **$0**, on-device |
| Servers, database, accounts | **$0** — there aren't any |
| WeatherKit | 500,000 calls/month free, then $49.99/million |

WeatherKit is the *only* metered dependency, which drives two decisions.

**It's cached per morning, not per check.** The forecast for a 7:57 AM departure does not
change every fifteen minutes. `weatherPadFraction(plan:…)` refetches at most every three hours,
and the call sits *below* the guard that skips idle checks — so a check that does no work
spends nothing. Uncached and above the guard, this ran at roughly 500 calls/user/month and
would have exhausted the free tier at about a thousand users. Cached, it's nearer eleven
thousand.

**It's a Pro feature.** Gating the only metered dependency means variable cost accrues solely
on paying users: a free user cannot cost money. That is enforced in `WakePlanner`, not in the
UI, and [there's a test for it](SmartAlarmTests/WakePlannerTests.swift) — hiding a toggle is
not a cost control.

The corollary, and the reason the Google Routes upgrade stays deferred: `TRAFFIC_AWARE_OPTIMAL`
bills at $10 per 1,000 requests. At three calls per solve and a dozen-plus checks a morning
that's **$11–16 per user per month** — unservable under any consumer price. Staying on MapKit
is a business decision as much as a technical one.

### What's free, what's Pro

**Free, and staying free:** the traffic-aware wake time, the leave-by backstop, every safety
rule, the posture setting, "Why this time?", and a week of history. An alarm app whose free
tier oversleeps you earns exactly one review.

**Pro** (`ProFeature`, one enum — change the split by editing it): calendar-aware mornings,
weather padding, per-day arrival times, and history beyond a week.

A single non-consumable via StoreKit 2 — buy once, keep it. Not a subscription: there is no
server cost to fund, and charging rent for something that runs entirely on the user's own phone
is hard to defend. `Config/SmartAlarm.storekit` is wired into the scheme, so purchases work in
the simulator without an App Store Connect record; the Debug tab has a Pro toggle for
everything else.

## Calendar integration

Reads the first real commitment of the morning — not all-day, not declined, not marked free.

- **Arrival deadline** = `min(your usual arrival, commitment start)`. That `min` is the entire
  safety guarantee: the calendar can only ever pull the alarm earlier.
- **Destination** is overridden only when the commitment is the thing setting the deadline and
  is more than 500 m from work — otherwise a 4 p.m. client visit would reroute your 9 a.m.
  commute.
- **Importance** (keywords, attendee count, external organiser, high-priority reminders) adds
  buffer and escalates the posture. It can only ever add time.

---

## Testing

```bash
xcodebuild test -scheme SmartAlarm -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

131 tests. The logic suites use an injected clock and closure-based providers; the planner
suite runs against a real in-memory `ModelContainer` with mock traffic, weather and alarm
services. Notable cases: earlier-moves apply even one minute before the alarm · later-moves are
rejected inside the lock window · a scheduling failure cannot make a later-move bypass the lock
· an out-of-range estimate is rejected rather than clamped · a cold start with no network still
schedules something · the calendar can pull arrival earlier but never later · snooze is capped
by remaining slack · getting-ready checks move leave-by but never the wake time · an
already-passed leave-by cancels its stale alarm · relaxing the posture needs a far longer clean
record than tightening it · a settings edit recomputes without touching the network · every
setting that moves the wake time is covered by the change signature · **a free user never
triggers a WeatherKit call** · the forecast is fetched once per morning rather than once per
check · a cancelled purchase is not an error and a pending one waits for approval.

### Debug tab (DEBUG builds only)

Testing a time-dependent alarm by waiting for real mornings is not a workable loop. The Debug
tab shifts the app's sense of "now" (everything reads one `DateProvider`), injects arbitrary
drive times, and shows the computed watch/lock boundaries.

```bash
# Seed a real commute and open a given tab, without driving the UI
xcrun simctl launch <device> com.danielxiao.SmartAlarm -seedDemoRoute YES -startTab debug
# Open the upgrade sheet on launch
xcrun simctl launch <device> com.danielxiao.SmartAlarm -showPaywall YES
```

Background tasks can't be triggered from the app. Pause in the debugger and run:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.danielxiao.SmartAlarm.refresh"]
```

---

## Simulator vs. device

Verified in the simulator: build (Debug + Release, no warnings), launch, persistence, live
MapKit ETAs, the full solve, all four screens, and the phase machine.

**Needs a physical device**, and is not covered by anything above:

- AlarmKit authorization, and either alarm actually firing
- Live Activity / Dynamic Island rendering
- WeatherKit, which needs its capability on a real App ID — unsigned builds fail soft to "clear"
- Real `BGTaskScheduler` execution — the simulator rejects submissions outright with
  `BGTaskSchedulerErrorDomain error 1`, which the app logs and shrugs off by design

## Shipping

[`docs/APP-STORE.md`](docs/APP-STORE.md) is the submission checklist — capabilities, the IAP
record, screenshots, review notes, listing copy, and the known review risks.
[`docs/PRIVACY.md`](docs/PRIVACY.md) is a ready-to-host privacy policy; App Store Connect
requires a URL for one even though the app collects nothing.

Already handled in the project: privacy manifest (verified to ship inside the `.app`), export
compliance declared, app category set, icon alpha correct, and the Debug menu / demo seeding /
launch arguments confirmed absent from the Release binary.

## Before shipping to a device

1. Set your team in Signing & Capabilities for both `SmartAlarm` and `SmartAlarmWidgetExtension`,
   and add the **WeatherKit** and **In-App Purchase** capabilities to the app's App ID.
   Create a non-consumable in App Store Connect with product ID
   `com.danielxiao.SmartAlarm.pro` to match `StoreKitPurchaseProvider`.
2. Change `PRODUCT_BUNDLE_IDENTIFIER` from `com.danielxiao.SmartAlarm` if needed — and update
   the two `BGTaskSchedulerPermittedIdentifiers` in `Config/SmartAlarm-Info.plist` plus the
   constants in `BackgroundRefreshController` to match.

No App Group is required: the widget renders entirely from `WakeAlarmMetadata`, which travels
with the alarm, and never reads the app's store.

---

## Not in v1

Single home→work route only (no multi-stop), driving only, iOS only, no backend — everything
runs on-device.

Considered and deliberately deferred:

- **A Google Routes provider.** `staticDuration` and `trafficModel: PESSIMISTIC` would replace
  two approximations here — the 3:30 a.m. free-flow probe and the locally-derived spread — with
  Google's own historical distribution. `TrafficProviding` is the seam. Worth doing if accuracy
  ever becomes the complaint; not worth an API key and a billing account before then.
- **Geofenced departure detection.** True ground truth on when you actually left, at the cost
  of an Always-location permission. The one-tap outcome prompt buys most of the calibration
  value for none of the privacy cost.
- **Querying past traffic.** No consumer routing API supports it. Real historical speed
  profiles mean an enterprise product (TomTom Traffic Stats, INRIX Speed), which is
  batch-oriented and the wrong shape for a per-morning mobile call.
