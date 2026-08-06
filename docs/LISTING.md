# App Store Connect — every field, filled in

Paste-ready values for **SmartyAlarm**. Character counts verified against Apple's limits.

The fields are spread across three pages in App Store Connect, which is the main reason this is
confusing. They're grouped that way below.

---

## Page 1 — App Information *(left nav → General → App Information)*

Set once; applies to every version.

| Field | Value | Limit |
|---|---|---|
| **Name** | `SmartyAlarm` | 30 — using 11 |
| **Subtitle** | `Wake for the traffic ahead` | 30 — using 26 |
| **Privacy Policy URL** | see *URLs* below | required |
| **Primary Category** | **Utilities** | |
| **Secondary Category** | **Productivity** | |
| **Content Rights** | **No** — contains no third-party content | |
| **Age Rating** | Answer the questionnaire with **None** throughout → resolves to **4+** | |
| **License Agreement** | Leave as Apple's standard EULA | |

**On Content Rights:** the app shows map and weather data, but that arrives through Apple's own
frameworks under Apple's terms rather than being third-party content you license. No is correct.

**Why Utilities over Productivity:** Utilities is where alarms and clocks live, so it matches
browsing intent. Productivity as secondary picks up the commute angle. If you'd rather fight a
smaller crowd, swapping them is defensible — this is not a decision you're locked into.

---

## Page 2 — 1.0 Prepare for Submission *(the version page)*

### Promotional Text — 170 max, using 158

Changeable any time **without** resubmitting for review. The only field with that property, so
it's where seasonal or timely messaging goes.

```
Set your arrival time. SmartyAlarm checks live traffic overnight and wakes you when you actually need to get up — with a second alarm for when you have to leave.
```

### Description — 4,000 max

```
Most "smart alarms" are just notifications. Notifications get silenced by Focus, by the ringer switch, by a force-quit. SmartyAlarm sets a real system alarm — it rings through all of it.

Then it works backwards. Tell it when you need to arrive, and it checks live traffic on your commute to work out when you actually need to get up. As the morning approaches it keeps checking, and moves the alarm earlier if the drive gets worse.

IT ONLY EVER ERRS EARLY
Worsening traffic always moves your alarm sooner — right up to the moment it rings. Improving traffic can move it later, but never once you're close to waking, and never on a single suspicious reading. If a check fails, your last good alarm time stands. Waking ten minutes early costs you ten minutes. Waking ten minutes late costs you the meeting.

IT SHOWS ITS WORKING
Tap "Why this time?" and every minute is accounted for: the map's estimate, the padding for how much your route varies at that hour, the buffer for parking and walking in. No black box. It also tells you how many mornings it has learned from, so you know how much to trust it.

A SECOND ALARM FOR LEAVING
Getting up on time and leaving on time are different problems. SmartyAlarm sets a second alarm for your leave-by time, and shortens your snooze so you can't sleep through it.

IT LEARNS YOUR COMMUTE
Every morning sharpens the estimate. The app records how long your route actually takes at your departure time and sizes its safety margin from how much that route really varies — not from a guess.

FREE
• Traffic-aware wake time
• The leave-by alarm
• Every safety rule
• Why this time? breakdown
• A week of history

PRO — one purchase, no subscription
• Calendar-aware mornings — wake earlier when your first meeting starts sooner, route to off-site meetings, add buffer on high-stakes days
• Weather padding — adds time for rain, snow and ice
• A different arrival time each weekday
• Full history

PRIVATE BY DESIGN
Everything runs on your iPhone. No account, no server, nothing collected. SmartyAlarm never asks for your location — it routes between the two addresses you type in, and nothing else.

Requires iOS 26.1 or later.
```

### Keywords — 100 max, using 86

Comma-separated, **no spaces after commas** — spaces waste characters.

```
alarm,commute,drive,morning,late,arrive,leave,oversleep,rush hour,clock,calendar,early
```

Deliberately omits *wake* and *traffic*: both already appear in the Subtitle, and Apple indexes
Name + Subtitle + Keywords together. Repeating them would burn characters for nothing.

### URLs

| Field | Value |
|---|---|
| **Support URL** | `https://daniu98.github.io/SmartAlarm/SUPPORT` |
| **Marketing URL** | leave blank |
| **Privacy Policy URL** | `https://daniu98.github.io/SmartAlarm/PRIVACY` |

Both require GitHub Pages — see *URLs* at the bottom.

### Version Information

| Field | Value |
|---|---|
| **Version** | `1.0` |
| **Copyright** | `2026 Daniel Xiao` |

Copyright is about *ownership*, not branding: the year rights were obtained, then the rights
holder. Not the app name. No © symbol, no URL.

### App Review Information

| Field | Value |
|---|---|
| **Sign-in required** | **No** |
| **Contact** | your name, email, phone |
| **Attachment** | none |

**Notes** — the most important field on this page. Your app's whole point is an alarm hours
away; without this a reviewer sees nothing happen and marks it non-functional.

```
SmartyAlarm computes a wake time by working backwards from when you need to arrive, using live traffic. No account or login is needed.

FASTEST WAY TO SEE AN ALARM FIRE (about 60 seconds)
1. Setup tab — enter any two addresses, tap "Look up address" on each.
2. Today tab — grant the alarm permission.
3. Tap "Ring a test alarm in 1 minute". Lock the device and set the ringer to silent; it will still ring, which is the core of what the app does.

TO SEE THE FULL TRAFFIC CALCULATION
1. Use two addresses roughly 10 minutes' drive apart.
2. Set "Usual arrival" to about 20 minutes from now, "Get ready" to 5 minutes, "Arrival buffer" to 0.
3. Turn on "Alarm armed" on the Today tab.
The alarm lands about 10 minutes out. "Why this time?" itemises every minute of the calculation.

BACKGROUND MODES
fetch and processing re-check traffic as the wake window approaches and move the alarm earlier if the commute deteriorates. This is the core function of the app, not a background refresh for content.

ALARMKIT
Used so the alarm rings reliably when the app is closed and the phone is silenced — the same reason the system Clock app does.

CALENDAR AND REMINDERS
Optional, read-only, and Pro-only. The app is fully functional without granting either.

IN-APP PURCHASE
One non-consumable, "SmartyAlarm Pro" (com.danielxiao.SmartAlarm.pro). The alarm itself is free; Pro adds calendar awareness, weather padding, per-day arrival times and full history. "Restore purchase" is on the paywall screen.
```

### Version Release

**Manually release this version.** Automatic means it goes live the moment review passes,
possibly at 3 a.m. while you're asleep. Manual costs one click and gives you the launch moment.

### Build

Greyed out until you archive and upload from Xcode. Come back and select it afterwards.

---

## Page 3 — Pricing and Availability

| Field | Value |
|---|---|
| **Price** | **Free** |
| **Availability** | All countries and regions |

Free with an in-app purchase — not a paid app. That's what the Pro unlock is for.

---

## Page 4 — App Privacy

| Question | Answer |
|---|---|
| **Do you or your third-party partners collect data from this app?** | **No** |

That's the entire section. Route lookups go to Apple Maps and forecasts to Apple WeatherKit
under Apple's own terms; you receive nothing. Verified by `SmartAlarm/PrivacyInfo.xcprivacy`,
which declares no tracking and no collected data types.

---

## URLs — do this before filling in Page 2

Both required URLs can come from the repo you already pushed.

1. GitHub → your repo → **Settings → Pages**
2. Source: **Deploy from a branch** → branch `main`, folder `/docs`
3. Save, wait about a minute

That publishes:

- `https://daniu98.github.io/SmartAlarm/PRIVACY`
- `https://daniu98.github.io/SmartAlarm/SUPPORT`

**The repo must be public** for these to resolve. If you'd rather keep it private, host both
markdown files anywhere public — a Gist, Notion, Carrd — and use those URLs instead.

Apple checks both links during review. A 404 on either is a straightforward rejection.
