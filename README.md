# TaskHUD

An always-on-top macOS heads-up display for a time-blocked day. It shows the block you're in, counts it down, lets you mark whether you actually did it, and turns red when you drift onto a site you told it to watch.

One Swift file. No Xcode project, no dependencies, no package manager. ~600KB binary.

Everything is local. Nothing leaves the machine.

---

## What it does

A small card in the corner, above every window, on every Space, including other apps' fullscreen windows:

- Time range, wall clock, current block, large countdown, hairline progress rule, what's next
- **Pause / resume / skip** — menu bar, right-click the card, or double-click it
- **Adherence marking** — a ✓ button opens a panel to mark every block done or missed, including past days
- **Dashboard** — 30-day rate, streak, per-activity breakdown
- **Distraction watch** — washes red on watched sites, and stays quiet during blocks where those sites are your actual job

---

## Install

Requires macOS 12+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone <this repo> taskhud
cd taskhud
chmod +x install.sh
./install.sh --login
```

`--login` installs a LaunchAgent so it starts at every login. Drop it to just run now.

The installer builds a real `.app` bundle rather than a bare binary — macOS only grants Automation permission (needed to read browser tabs) to bundled, signed applications — and ad-hoc signs it.

**Uninstall:** `./install.sh --uninstall`. Your schedule and adherence log are kept.

---

## Your day

Everything is `~/.taskhud/schedule.json`. Save it and the HUD hot-reloads within a second. A starter file is written on first run; `schedule.example.json` here is a fuller one.

Minimum viable:

```json
[
  { "title": "Deep work", "start": "09:00", "end": "11:00" },
  { "title": "Email",     "start": "11:00", "end": "12:00" }
]
```

### Block fields

| Field | Required | Notes |
|---|---|---|
| `title` | yes | Shown large on the card |
| `start` | yes | `"HH:mm"` or `"HH:mm:ss"`, 24-hour. `"9:00"` works |
| `end` | yes | Same. If `end <= start` the block crosses midnight |
| `days` | no | `["mon","tue",…]`, `["weekdays"]`, `["weekends"]`, `["daily"]`, or ints `1`=Sun…`7`=Sat. Omit for daily |
| `note` | no | Small text in the meta row |
| `color` | no | `#RRGGBB` or `#RRGGBBAA` — tints the progress rule. Pick something that reads on a light background |

### Settings

| Key | Default | Notes |
|---|---|---|
| `warnMinutes` | `[10, 5, 1]` | Chime + colour shift at each mark. Ochre at the largest, clay red at the smallest |
| `sound` | `true` | Master switch for chimes |
| `startSound` / `warnSound` | `"Glass"` / `"Tink"` | Any name from `/System/Library/Sounds` |
| `opacity` | `0.96` | `0.30`–`1.00` |
| `compact` | `false` | One-line mode: title + remaining |
| `showSeconds` | `true` | Off gives `1h 23m` instead of `1:23:45` |
| `windowLevel` | `"screenSaver"` | Floats above other apps' fullscreen windows. `"status"` or `"float"` are less aggressive |
| `clickThrough` | `false` | `true` makes the card non-interactive. Toggle back from the menu bar |
| `scale` | `1.0` | `0.75`–`1.75` UI scale |

---

## Pause, resume, skip

Menu bar, right-click, or double-click the card.

**Pause** freezes the countdown, progress, and all chimes — but it cannot outlive its block. The block still ends when it ends. Pause means "stop nagging me," not "hold the day." A wall-clock schedule that quietly rearranges itself isn't a schedule.

**Skip** dismisses one block instance. It never edits your JSON; the block returns tomorrow. With no active block it skips the next one.

**Back to schedule** clears every pause and skip.

State persists across restarts, and is discarded if stale (older than 12h).

---

## Adherence

The ✓ button opens the review panel.

**Day tab** — every block with ✓ / ✗. Clicking an active mark clears it. `‹ ›` walks back through history so you can fill in yesterday. Forward is capped at today.

**Dashboard tab** — 30-day adherence, streak, blocks done, days logged, a bar chart, and a per-activity breakdown.

Two decisions worth knowing:

- **Adherence is done ÷ marked, not done ÷ scheduled.** Unmarked blocks are ignored entirely, never counted as missed. A metric that punishes you for forgetting to tick a box stops getting ticked.
- **Days with no marks draw as a faint stub, not a zero bar.** A day you didn't record is not a day you failed.

Stored at `~/.taskhud/adherence.json`, written atomically. If it ever fails to parse it's copied aside rather than overwritten.

---

## Distraction watch

```json
"distractions": {
  "enabled": true,
  "apps": ["Instagram", "TikTok"],
  "sites": ["instagram.com", "x.com", "reddit.com"],
  "graceSeconds": 20,
  "escalateAfterMinutes": 5,
  "onlyDuringBlocks": true,
  "allowDuringTitles": ["Marketing", "Events"],
  "message": "back to it?",
  "debug": false
}
```

After `graceSeconds` on a watched site the whole card washes soft red with a line like `INSTAGRAM.COM · 2m · BACK TO IT?`. Your task and countdown stay visible underneath. At `escalateAfterMinutes` it chimes once and stops. Leave the site and it clears.

`allowDuringTitles` is the point of the whole feature — substring match against the current block's title. Instagram during a build block goes red; Instagram during a marketing block does nothing, because that's the job.

Also quiet during free time (`onlyDuringBlocks`), while paused, and when the screen is locked.

**Permissions.** Reading the frontmost browser tab needs Automation permission; macOS prompts once per browser. Set `"debug": true` to log every poll to `~/.taskhud/taskhud.log` while tuning.

Supported for tab URLs: Safari, Chrome, Brave, Arc, Edge, Vivaldi, Opera. **Firefox exposes no scriptable tab URL** and falls back to app-name matching.

**Ad-hoc signatures are content-derived, so every rebuild invalidates the Automation grant** and you'll be prompted again. Only matters while iterating.

---

## Edge cases handled

- Midnight-crossing blocks stay current past 00:00
- Overlapping blocks — most recently started wins, ties to the shorter, `overlap` marker shown
- Gaps show `Open` and count down to the next block
- Sleep/wake — every tick recomputes from wall-clock `Date()`, so no drift
- DST and timezone changes rebuild the schedule; spring-forward times that don't exist snap to the next valid instant
- Broken JSON keeps the last good schedule and shows an amber line
- **Atomic saves** — editors replace the file by rename, which kills a naive `DispatchSource` watch and can make a read fail mid-swap. The watcher re-arms, polls mtime as a fallback, and failed loads retry with backoff
- Monitor unplugged or resolution changed — the card is clamped back onto a real screen
- Space switching — re-fronts so it can't get buried
- Relaunch mid-block doesn't replay the start chime
- Alerts fire once per block instance and the dedupe set is capped

---

## Known limitations

- **No calendar sync.** This works because a day repeats. If yours doesn't, hand-editing JSON gets old fast — a cron job writing `schedule.json` from the Calendar API would hot-reload fine.
- **No phone, no cloud, no sync.**
- **Nudges, doesn't block.** If you need enforcement, buy Cold Turkey or Focus Bear.
- **Renaming a block splits its history.** Records key on title + start time, which is what makes them survive schedule edits and also what fragments them on rename.

---

## Prior art

This is not an unserved need, and you should probably buy one of these instead:

- **[Focus Bear](https://www.focusbear.io/)** — contextual blocking tied to what you're working on, routine completion tracking, four platforms
- **[FocusMe](https://focusme.com/)** — scheduled blocking by day and time, floating timer, pause limits
- **RescueTime FocusTime** — blocking triggered from calendar events
- **[Chunk](https://www.chunkapp.net/)** — macOS-native time blocking with a countdown that floats over fullscreen apps
- **[1Focus](https://onefocusapp.com/)** — per-site recurring schedules, ~$10/year

TaskHUD exists because I wanted all of it in one always-visible card driven by a text file I control. That's a taste preference, not a market insight.

---

## Troubleshooting

```bash
tail -f ~/.taskhud/taskhud.log
```

Card missing but the menu bar item is there? It may be off-screen from a previous monitor — menu bar → **Reset position**.

---

MIT. Built in an evening with [Claude](https://claude.ai).
