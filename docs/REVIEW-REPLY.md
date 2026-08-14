# Reply to Guideline 2.1 — Information Needed

Apple isn't rejecting the app; they want context before reviewing. Reply in **App Store Connect
→ App Review → Messages**.

Item 1 is a screen recording that must be captured on a physical iPhone, so do the device test
first — it also gives you the honest answer to item 2.

---

## Before you reply: the device test

Nothing has run on real hardware yet. Everything so far is simulator-verified, which is not what
item 2 is asking about.

1. **TestFlight → build 1.0 (2) → install on your iPhone.**
2. Grant the alarm permission when prompted.
3. Enter two real addresses in Setup.
4. Tap **Ring a test alarm in 1 minute**, lock the phone, flip the ringer to silent. Confirm it
   rings through.
5. Check the Lock Screen shows the Live Activity while it rings.
6. Add the home-screen widget and confirm it shows a time rather than the placeholder.
7. Turn on the calendar toggle (after unlocking Pro in the sandbox) and confirm the permission
   prompt appears.

If anything there fails, fix it before replying — a reviewer following your own recording will
hit the same thing.

---

## 1. Screen recording

Record on the iPhone (Settings → Control Centre → add Screen Recording). Roughly 90 seconds.
Apple requires it to **start with the app launching** and to include the purchase flow and every
permission prompt.

Shot list, in order:

| # | What to show | Why Apple asked |
|---|---|---|
| 1 | Tap the app icon on the Home Screen; app launches to the empty state | Required: must begin with launch |
| 2 | Setup tab → type both addresses → tap **Look up address** on each | Core setup |
| 3 | Today tab → tap **Grant permission** → **the iOS alarm permission dialog** → Allow | Sensitive-data prompt |
| 4 | Toggle **Alarm armed** on; the computed wake time appears | Core feature |
| 5 | Tap **Why this time?** → scroll the breakdown → Done | Core feature |
| 6 | Tap **Ring a test alarm in 1 minute** → lock the phone → **show it ringing** → Stop | The central claim |
| 7 | Setup → tap the locked **Use my calendar** row → paywall opens | Paid-feature gate |
| 8 | Tap **Unlock Pro** → **the App Store purchase sheet** → complete in sandbox | Required: purchase flow |
| 9 | Calendar toggle now enabled → tap it → **the iOS calendar permission dialog** | Sensitive-data prompt |
| 10 | History tab → scroll the logged checks | Core feature |

Upload the file in the App Review Messages thread.

---

## 2. Devices and OS tested on

Replace with what you actually used. Do not list anything you didn't test on.

```
Tested on:
- iPhone [YOUR MODEL], iOS [YOUR VERSION] — physical device
- iPhone 17 Pro and iPhone 17 Pro Max simulators, iOS 26.5

The app requires iOS 26.1 or later because it uses AlarmKit, which is unavailable
before iOS 26, and the non-deprecated AlarmPresentation.Alert initialiser introduced
in 26.1.
```

---

## 3. Functions and target audience

```
SmartyAlarm is an alarm clock for people who drive to a fixed workplace on a route where traffic varies day to day.

THE PROBLEM
A fixed alarm assumes a fixed commute. Real commutes vary by 15-40 minutes depending on traffic, so a fixed alarm means either waking earlier than necessary every single day, or being late whenever traffic is worse than usual.

WHAT IT DOES
The user enters a home address, a work address, and the time they need to arrive. The app queries Apple Maps for a traffic-aware driving estimate for that specific future departure time, then works backwards:

  leave-by = arrival time - drive time - parking buffer
  wake time = leave-by - get-ready time

It then schedules a real system alarm (AlarmKit) at that wake time, plus a second alarm at the leave-by time. As the morning approaches it re-checks traffic in the background and moves the alarm earlier if the drive has got worse.

THE VALUE
The user gets the latest wake time that still has them arriving on time, and does not have to guess or pad manually. Every adjustment is biased toward waking early: worsening traffic always moves the alarm sooner, while improving traffic is only accepted outside a configurable lock window and never on a single unconfirmed reading. If a traffic check fails, the last known-good alarm time is kept rather than reverting to a default.

The app also shows its full working on a "Why this time?" screen, so the user can see exactly which minutes came from the map estimate, the safety padding, and their own buffers.

TARGET AUDIENCE
Commuters who drive to a workplace with a hard start time. General audience, no age restriction, rated 4+.
```

---

## 4. Setup and access instructions

```
No account, no login, no sample files. Nothing is gated behind a server.

TO SET UP (about 30 seconds)
1. Setup tab: enter any two addresses and tap "Look up address" under each. They are geocoded via Apple Maps.
2. Today tab: tap "Grant permission" to allow alarms, then turn on "Alarm armed".

The wake time appears immediately, along with the leave-by time, the drive estimate, and the traffic condition.

TO SEE AN ALARM FIRE IN ABOUT 60 SECONDS
On the Today tab, tap "Ring a test alarm in 1 minute". Lock the device and set the ringer to silent. It will still ring. This exists precisely because the app's core behaviour is otherwise hours away.

TO SEE THE FULL TRAFFIC CALCULATION IN ABOUT 10 MINUTES
Use two addresses roughly 10 minutes' drive apart. Set "Usual arrival" to about 20 minutes from now, "Get ready" to 5 minutes and "Arrival buffer" to 0. The alarm will be scheduled about 10 minutes out. Tap "Why this time?" to see every minute itemised.

TO TEST THE IN-APP PURCHASE
Setup tab: any row marked PRO opens the upgrade screen. "SmartyAlarm Pro" is a single non-consumable (com.danielxiao.SmartAlarm.pro). "Restore purchase" is on the same screen. The alarm itself is free and fully functional without it.

PERMISSIONS
- Alarms: required, so the alarm rings when the app is closed and the phone is silenced.
- Calendar and Reminders: optional and read-only, Pro only. The app is fully functional if both are denied.
- The app never requests location access.
```

---

## 5. External services

```
The app uses only Apple's own frameworks. There are no third-party SDKs, no analytics, no advertising, no AI services, and no backend of any kind.

- MapKit (MKDirections) — traffic-aware driving time estimates for a future departure time. This is the core data source.
- MapKit (MKGeocodingRequest) — converts the two addresses the user types into coordinates.
- WeatherKit — forecast conditions at the departure hour, used to add padding for rain, snow or ice. Pro feature only.
- AlarmKit — schedules the system alarms.
- EventKit — reads the user's first calendar commitment of the morning. Optional, read-only, Pro feature only.
- StoreKit 2 — the single in-app purchase.
- SwiftData — local on-device storage.
- BackgroundTasks — re-checks traffic as the wake window approaches.

The developer operates no servers. No user data is transmitted to the developer or to any third party. This is declared in the app's PrivacyInfo.xcprivacy, which reports no tracking and no collected data types.
```

---

## 6. Regional differences

```
There are none. The app functions identically in all regions.

All times, dates and distances are formatted using the device locale, and the app follows the user's calendar and time zone settings. Route and weather coverage comes from Apple Maps and Apple WeatherKit and therefore matches Apple's own coverage in each region; where Apple Maps cannot return a driving route, the app reports that the check failed and keeps the last known-good alarm time rather than guessing.

The app is currently localised in English only.
```

---

## 7. Regulated industry or protected material

```
Not applicable. SmartyAlarm does not operate in a regulated industry and contains no third-party or protected material.

All map, routing and weather data is provided by Apple's own frameworks (MapKit and WeatherKit) under the standard Apple Developer Program License Agreement. All other content, including the app icon and all text, is original work by the developer.
```
