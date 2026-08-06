# SmartyAlarm Support

SmartyAlarm works backwards from when you need to arrive to when you need to wake, checking
live traffic on your commute and moving the alarm earlier if the drive gets worse.

**Questions, bugs, or feature requests:** danielxiao9807@gmail.com

---

## Common questions

### Why did it wake me earlier than I expected?

Tap **Why this time?** on the Today screen. Every minute is itemised — the map's estimate, the
padding for how much your route varies at that hour, the buffer for parking, your get-ready
time. Nothing is hidden.

The app is deliberately biased toward early. Worsening traffic always moves your alarm sooner;
improving traffic can move it later, but never once you're close to waking.

### Why didn't it move the alarm when traffic cleared up?

If the improvement arrived inside the lock window — 45 minutes before your alarm by default —
it was ignored on purpose. Open **History** and you'll see the check logged with the reason.
Waking early costs you a few minutes; waking late costs you the meeting.

You can change the lock window in **Setup → Advanced → Freeze later moves**.

### It says "Traffic unknown"

The app needs a free-flow reference for your route before it can call traffic light, moderate or
heavy. That's captured in the background shortly after setup. Until then it reports "unknown"
rather than guessing.

### The alarm didn't ring

Check **Setup** shows both addresses with green ticks, and that **Alarm armed** is on.

Then tap **Ring a test alarm in 1 minute** on the Today screen. Lock your phone and switch the
ringer to silent — it should still ring. If it doesn't, SmartyAlarm doesn't have alarm
permission: **Settings → SmartyAlarm → Alarms**.

### Does it need my location?

No. SmartyAlarm never requests location access. It routes between the two addresses you typed
in, and nothing else.

### What does Pro add?

Calendar-aware mornings, weather padding, per-day arrival times, and full history. The alarm
itself — the traffic-aware wake time, the leave-by backstop, and all the safety rules — is free
and stays free.

Pro is a single one-time purchase, not a subscription. **Restore purchase** is on the upgrade
screen if you reinstall or switch devices.

### How do I delete my data?

Delete the app. Everything lives in a local database on your iPhone and goes with it. There's
no account and no server. See the [privacy policy](PRIVACY.md).

---

## Requirements

iOS 26.1 or later. iPhone only.
