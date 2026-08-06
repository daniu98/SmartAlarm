# Shipping SmartAlarm

Everything the code needs is done. What's left is account setup, assets, and the things only
you can do. Work top to bottom.

---

## Done in the project already

- ✅ `PrivacyInfo.xcprivacy` — declares no tracking, no collected data, verified to ship inside
  the built `.app`
- ✅ `ITSAppUsesNonExemptEncryption = false` — you won't be asked export compliance on uploads
- ✅ `LSApplicationCategoryType = utilities`
- ✅ App icon with light/dark/tinted variants, no alpha on the primary (a hard rejection)
- ✅ Version 1.0, build 1
- ✅ Debug menu, demo seeding and launch arguments compile out of Release — verified: **zero**
  debug symbols in the Release binary
- ✅ All permission strings written and specific
- ✅ In-app purchase restorable, cancellation handled, Ask-to-Buy handled
- ✅ Privacy policy drafted at [`docs/PRIVACY.md`](PRIVACY.md) — host it somewhere public

---

## 1. Decide the name first

**`SmartAlarm` is almost certainly taken.** Check
[App Store Connect](https://appstoreconnect.apple.com) before anything else, because the name
propagates into the bundle ID, the product ID and your screenshots.

If you change it, update in this order:

| Where | What |
|---|---|
| `project.pbxproj` | `PRODUCT_BUNDLE_IDENTIFIER` (app + widget) |
| `Config/SmartAlarm-Info.plist` | both `BGTaskSchedulerPermittedIdentifiers` |
| `BackgroundRefreshController` | `refreshTaskIdentifier`, `nightlyTaskIdentifier` |
| `StoreKitPurchaseProvider` | `proProductID` |
| `Config/SmartAlarm.storekit` | `productID` |
| `AppLogger` | `subsystem` |

The background task identifiers **must** match between the plist and the code, or
`BGTaskScheduler.register` throws at launch.

## 2. Apple Developer Program — $99/year

[developer.apple.com/programs](https://developer.apple.com/programs/). Allow a day or two for
approval.

## 3. App ID capabilities

In the Developer portal, create the App ID and enable:

- **WeatherKit** — without it, weather padding silently returns "clear" forever
- **In-App Purchase**
- **Push Notifications** — required by Live Activities
- **App Groups** — create `group.com.danielxiao.SmartAlarm`, matching `SharedStore.appGroupID`.
  The home-screen widget reads its snapshot from here. Without it the widget shows its
  placeholder and the app carries on regardless — `SharedStore` degrades rather than throws.

Then in Xcode, set your team on **both** `SmartAlarm` and `SmartAlarmWidgetExtension`.

## 4. The in-app purchase

Create a **non-consumable** in App Store Connect with product ID exactly:

```
com.danielxiao.SmartAlarm.pro
```

matching `StoreKitPurchaseProvider.proProductID`. Price it in whatever tier maps to your
number — `Config/SmartAlarm.storekit` currently mocks $7.99. Fill in the display name,
description, and a review screenshot of the paywall.

**It must be in "Ready to Submit" state and attached to your app version**, or reviewers will
reject the build for a non-functioning purchase.

## 5. Screenshots

Ready-made sets are checked in under `AppStoreScreenshots/`:

- `6.5-inch/` — **1284 × 2778** (iPhone 14 Plus)
- `6.9-inch/` — **1320 × 2868** (iPhone 17 Pro Max)

App Store Connect shows whichever slots your account offers; upload the matching set. Regenerate
with `-screenshotMode YES`, which stages the app realistically — a simulator can't grant AlarmKit
permission, so without it every shot carries a permission banner a real device would never show.
It also hides the Debug tab and seeds a week of plausible history.

Take them on the matching simulator:

```bash
xcrun simctl boot "iPhone 17 Pro Max"
xcrun simctl launch "iPhone 17 Pro Max" com.danielxiao.SmartAlarm -seedDemoRoute YES
xcrun simctl io "iPhone 17 Pro Max" screenshot shot1.png
```

Shoot these five, in this order — they tell the story:

1. **Today** with a computed wake time — the whole product in one screen
2. **Why this time?** — the differentiator; nothing else shows its working
3. **History** with a rejected later-move — proves the safety logic is real
4. **Home screen with the widget** — shows it lives outside the app
5. **Setup**
6. **Paywall**

Use `-startTab setup|history|debug` to land on a screen directly.

## 6. App Review notes — do not skip this

A reviewer has minutes, and this app's whole point is an alarm hours in the future. Without
instructions they will not see it work. Paste this in:

> SmartAlarm computes a wake time by working backwards from when you need to arrive, using live
> traffic. No account or login is needed.
>
> **Fastest way to see an alarm fire (about 60 seconds):**
> 1. Setup tab → enter any two addresses, tap "Look up address" on each.
> 2. Today tab → grant the alarm permission.
> 3. Tap **"Ring a test alarm in 1 minute"**. Lock the device and set the ringer to silent —
>    it will still ring, which is the core of what the app does.
>
> **To see the full traffic calculation:**
> 1. Set "Usual arrival" to about 20 minutes from now, "Get ready" to 5, "Arrival buffer" to 0,
>    using two addresses roughly 10 minutes apart.
> 2. Turn on "Alarm armed" on the Today tab.
>
> The alarm lands about 10 minutes out, and "Why this time?" itemises every minute of the
> calculation.
>
> **Background modes:** `fetch` and `processing` re-check traffic as the wake window approaches
> and move the alarm earlier if the commute deteriorates. This is the core function of the app.
>
> **AlarmKit:** used so the alarm rings reliably when the app is closed and the phone is
> silenced — the same reason the system Clock app does.
>
> **Calendar and Reminders:** optional and read-only. The app works fully without them.
>
> **In-app purchase:** one non-consumable, "SmartAlarm Pro". The alarm itself is free; Pro adds
> calendar awareness, weather padding, per-day arrival times and full history. Restore is on
> the paywall screen.

## 7. Privacy nutrition label

App Store Connect → App Privacy. The honest answers:

- **Do you collect data from this app?** → **No**

That's the whole thing. Route lookups go to Apple Maps and forecasts to Apple WeatherKit under
Apple's own terms; you receive nothing. You still need a privacy policy URL — host
[`docs/PRIVACY.md`](PRIVACY.md) on GitHub Pages or anywhere public.

## 8. Listing copy

**Subtitle** (30 chars): `Wake for the traffic ahead`

**Keywords** (100 chars, comma-separated, no spaces):
```
alarm,commute,traffic,wake,drive,morning,late,arrive,clock,calendar,rush hour,leave
```

**Description** — lead with the moat:

> Most "smart alarms" are notifications. Notifications get silenced by Focus, by the ringer
> switch, by a force-quit. SmartAlarm sets a real system alarm — it rings through all of it.
>
> Then it works backwards. Tell it when you need to arrive, and it checks live traffic on your
> commute and sets the alarm for when you actually need to get up. As the morning approaches it
> keeps checking, and moves the alarm earlier if the drive gets worse.
>
> **It only ever errs early.** Traffic worsening always moves your alarm sooner, right up to
> the moment it rings. Traffic improving can move it later — but never once you're close to
> waking, and never on a single suspicious reading. If a check fails, your last good alarm time
> stands.
>
> **It shows its working.** Tap "Why this time?" and every minute is accounted for: the map's
> estimate, the padding for how much your route varies, the buffer for parking. No black box.
>
> **A second alarm for when you have to leave**, because getting up on time and leaving on time
> are different problems.
>
> Everything runs on your iPhone. No account, no server, nothing collected.

## 9. Archive and upload

```bash
xcodebuild -scheme SmartAlarm -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/SmartAlarm.xcarchive archive
```

Then Xcode → Window → Organizer → Distribute App. Or use the Product → Archive menu directly.

---

## Known review risks, ranked

**1. Background modes.** `fetch` and `processing` get scrutiny. The review notes above address
it directly — an alarm that adjusts to traffic genuinely cannot work without them.

**2. AlarmKit.** Newer framework, less reviewer familiarity. The usage is exactly what it's for.

**3. Nothing visible happens.** If a reviewer sets a realistic 45-minute commute and a 9 AM
arrival, nothing observable occurs for hours and they may mark the app non-functional. The
**"Ring a test alarm in 1 minute"** button on the Today screen exists largely for this — it
gives a reviewer (and a new user) a sixty-second proof that the alarm rings through a silenced
phone. Make sure the review notes point at it.

**4. iOS 26.1+ only.** Not a rejection risk, but understand the trade: AlarmKit needs iOS 26,
and the non-deprecated alert initialiser needs 26.1. That's a small installed base today and it
will grow. Dropping to 26.0 buys very little and costs a deprecation warning.

## After it's live

Ship an update the week you get real users — reviewers and users both read "last updated".
The highest-value first update is whatever the outcome-feedback data tells you: if people are
tapping "Was late", your padding constants are too thin, and that's now measurable rather than
guessed.
