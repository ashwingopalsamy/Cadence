# Cadence specification

Blueprint v1.1, 30 October 2026. This file is the source of truth for Cadence. All example data is synthetic (ACME, example.com). `verify` marks a platform claim to prove on a Mac; results go in docs/SPIKES.md.

A local work log for macOS 26 that fills itself from what you already do, asks you only for judgment, and turns every workday into evidence a manager's agent can check. It lives in one dot in your menu bar.

- **Under a minute a day** Login, PRs, reviews and Claude Code sessions arrive on their own. You plan in the morning and confirm in the evening.
- **Nothing leaves the Mac** The app runs in the App Sandbox with no network entitlement, so macOS itself blocks it from opening a connection.
- **Every claim carries its source** Collected entries link to the PR or ticket. Typed entries are labelled self-reported. The proof file says which is which.


## 1. Brief

Every answer from the interview is fixed here, so the build can start without re-asking.

Topic| Decision
---|---
Product| Native macOS app in Swift and SwiftUI, minimum macOS 26 Tahoe. Local only. Private GitHub repo `Cadence` first, open source later, built from source on the work Mac.
Primary surface| A tiny, dynamic dot in the menu bar. A Pocket popover for today. The full window is secondary.
Who| Ashwin first: staff engineer, remote in Asia/Kolkata, team in São Paulo, stand-up at 17:30 IST, Monday to Friday. Then any developer on a Mac.
Why| Make daily consistency visible and give verifiable evidence for the annual review. Backfill from 1 Oct 2026, the start of the financial year.
Input style| Collectors pre-fill, you confirm. Morning plan, quick capture, evening wrap-up. No plain forms: chips, toggles, steppers and natural-language capture.
What it tracks| First and last activity, plan vs done, PRs opened, merged and reviewed, initiatives (self-initiated vs assigned), meetings, leadership signals, on-call and incidents, GenAI usage.
Tickets| Configurable pattern. Assigned work looks like `ACME-123456`; self-initiated work uses the placeholder `ACME-000000`. Your real prefix exists only in local config.
Agents| Local MCP server over stdio (no listener of any kind), a `cadence` CLI, Claude Code hooks. Slack dictation is pasted into Claude Code or into Cadence the next day.
Integrations, v1| GitHub Enterprise through your own `gh` CLI, Claude Code (hooks and local transcripts), your GenAI usage endpoint, and an import of your October data.
Integrations, later| Outlook calendar and Slack message counts (counts only, never content).
Reminders| Native macOS notifications. Wrap-up at 17:30 by default; 16:00 and 18:00 are one-tap options; any time can be added. A morning plan prompt after first activity.
Leave| Planned leave never breaks a streak. Unplanned leave is declared by hand and pauses the streak the same way.
Evidence| Edit history on everything. A hash-chained, agent-readable proof file with source links and self-reported labels. No keys.
Security| No network entitlement, no admin rights, no Docker. Nothing from the employer in the repo. Work data never in git.
Workflow| Every task is in `docs/PLAN.md` with a tier: planner, builder, mechanic, auditor. Core phases run in the cloud project, macOS phases on the Mac. No GitHub CI for now; `make check` is the gate.


## 2. Principles

Eight rules, inherited from Agam and Policy Rate Atlas and sharpened for a tool you touch every day.

#### Capture is a confirmation

Collectors propose; you accept with one tap, adjust by direct manipulation, or dismiss. Typing is the fallback, and typed text turns into chips as you type.

#### Evidence before adjectives

Every entry has one immutable origin: **observed** (the Mac saw it), **collected** (a source system has it, with a link), **agent** (Claude wrote it), **self** (you typed it). Accepting an entry changes its status, never its origin.

#### Unknown is never zero

A day with nothing logged is blank, not 0. A missing logout is "-". Leave and holidays are their own states. Backfilled entries say so, with the date they were recorded.

#### Tiny at rest, rich on demand

One glyph in the menu bar. The Pocket answers "how is today going" in two seconds. History and insights live in the window.

#### Close the loop, not the list

The ring closes when every planned task is resolved and the day is sealed: done, slipped or dropped with a reason. Consistency means showing up and accounting for the day, so over-planning and under-planning both show.

#### Delight confirms, it does not nag

Sound, haptics and motion mark real moments: the day starting, the plan set, the ring closing, a streak milestone. No badges, no confetti, no guilt copy such as "You missed".

#### Local and inspectable

One SQLite file you own, plain JSON out, Apple frameworks only inside the app, collectors short enough to read in a minute. macOS enforces the no-network promise.

#### Employer-neutral by construction

Ticket patterns, hosts, labels and holidays live in local config. Code, fixtures, screenshots and docs use ACME. A guard on every commit and in `make check` fails on forbidden terms.

### What "consistency" maps to

Your read of the manager's meaning is: proactive, leadership presence, raising discussions, every day. Cadence records each of those as a separate signal and never folds them into one score, because a sourced count survives scrutiny and a score does not.

Signal| What Cadence records| Where it comes from
---|---|---
Proactive| Self-initiated PRs (placeholder ticket), initiatives started, discussions raised| GitHub collector, you
Leadership presence| Meetings led, decisions challenged, mentoring, design docs, reviews given| You, GitHub collector
Every day| First activity on workdays, sealed-day streak, days with at least one review| The Mac, GitHub, you
Delivery| PRs merged, plan vs done, slip reasons| GitHub, you
AI fluency| Sessions, AI-active days, tokens, AI-assisted PRs| Claude Code, usage endpoint

Confirm with your manager which of these matter most. The signal set is a config list, so adding "customer escalations" later is one line.


## 3. A day with Cadence

Four touchpoints a day and three of them are pre-filled. The Mac notes when you start, you plan in under a minute, agents and collectors log through the day, and the 17:30 wrap-up seals the day and writes your stand-up.

An example Thursday on an 08:00 to 22:00 axis. Filled marks need nothing from you; ringed marks take a few seconds; the accent mark is the wrap-up.

first input after 04:00 · automatic

#### Day start

  1. The Mac wakes or unlocks; the presence engine sees the first keyboard or pointer input of the workday.
  2. Cadence records first activity as **observed**. The dot pips in with a soft tick (Subtle sound level).
  3. If yesterday is not sealed, the Pocket's first row is "Seal Wednesday", one click away.


Your time **0 s** Source **the Mac**

2 min after day start · notification

#### Morning plan

  1. "Plan Thursday" arrives; the dot shows its attention satellite.
  2. Yesterday's open tasks come back as chips: keep or drop.
  3. Suggestions from collectors: PRs waiting to merge, review requests, tickets you touched yesterday. Tap + to plan.
  4. Type to add; ticket keys, estimates and tags become chips. Optional focus line. `⌘↩` commits with a rising three-note chime.


Your time **30 to 60 s** Pre-filled **carry-over, suggestions**

any time · global shortcut

#### Quick capture

  1. `⌃⌥L` opens the capture bar over any app. Option-click the dot, drop a link on it, or type in the Pocket.
  2. Write one line. The parser turns it into a kind, ticket, time, duration and tags as you type.
  3. `↩` saves as **self** ; the bar closes with a short "tock".


Your time **about 5 s** Typing **one line**

17:30 default · notification

#### Wrap-up and stand-up

  1. Plan check: each task gets done, slipped or dropped. A merged PR with the task's ticket pre-selects done. Slips take a reason chip.
  2. Found today: collected entries are accepted by default. Exclude noise, or drag a PR onto the task it finished.
  3. Signals: tap tiles for discussions raised, decisions challenged, meetings led, mentoring, initiatives, incidents; set meetings attended with a stepper.
  4. Seal: the ring closes, the streak ticks up, and the stand-up text is copied with its witness code.


Your time **under 60 s** Pre-filled **PRs, reviews, sessions**

first run, then on demand

#### Backfill from 1 Oct

  1. Pick the range; the default is 1 Oct 2026 to yesterday.
  2. Collectors run: GitHub contributions and reviews, Claude Code transcripts, your October GenAI data, and the power log for first and last activity where it still exists.
  3. An October calendar shows each day's proposed entries. Mark holidays and leave, then accept per day or accept all collected.
  4. Backfilled entries keep their real date and carry "recorded 29 Oct".


Your time **about 15 min, once**

next morning · when you forgot

#### Dictation fallback

  1. Dictate into Slack on your phone, as you planned.
  2. Next day, paste the transcript into the capture bar (Cadence splits the lines and parses them on device) or into Claude Code with `/mcp__cadence__import-dictation`.
  3. Entries land in the Inbox with the dictation date, marked as dictated. Accept all in one click.


Your time **1 to 2 min** Network **none**

during Claude Code sessions · automatic

#### Agent logging

  1. SessionStart and SessionEnd hooks append one line to Cadence's spool in a few milliseconds and exit.
  2. Cadence records the session (start, end, reason, project alias). Tokens arrive later from the transcripts collector.
  3. Optional: SessionStart prints today's plan to Claude as context, so Claude knows what you are working on.
  4. When you finish something, Claude can call `log_entry`. The dot's satellite orbits once.


Your time **0 s**

from the Pocket menu

#### Leave, holidays, on-call

  1. "Leave…" opens a date-range chip picker with planned or unplanned. Reminders for those days are cancelled.
  2. Holidays: add dates or import an .ics file in Settings.
  3. "On call…" sets a range; the dot gains its outer ring and incidents log as Ownership entries.


Streak **paused, never broken**

### The rules behind the day

Rule| Default| Why
---|---|---
Day boundary| 04:00 local, configurable| Late nights belong to the day they started, and an overnight-awake Mac does not invent a new day.
Workdays| Monday to Friday| Weekend activity is recorded but never prompts.
First activity| First input after the boundary with the session unlocked| Matches "my first interaction on the laptop that day".
Last activity| End of the last activity span before the next boundary| Logout is inferred, never typed. Spans close after 5 minutes idle.
Seal| Wrap-up seals the day| Seal at stand-up time; the day keeps collecting.
After the seal| New collected entries join the day marked "after wrap-up"| A PR merged at 19:02 still counts without reopening anything.
Grace window| Seal yesterday until 23:59 today, calendar time in the day's zone| Forgetting once does not cost the streak if you account for it next morning. The proof states the same rule.
Streak| Consecutive workdays sealed; leave and holidays are skipped| Rewards accounting for every workday, not hours.
Edits after seal| Allowed, recorded as amendments with timestamps| Honest history beats a locked log.


## 4. Surfaces

Six surfaces, one grammar. The dot signals, the Pocket summarises, the capture bar and two sheets take input by direct manipulation, and the window holds history.

### 4.1 The menu-bar dot

A 16-point glyph in an 18-point status item, so it takes about the width of one letter. It is drawn as a template image, so macOS 26 tints it for the transparent menu bar in light, dark and tinted modes. State is carried by form, never by colour alone. An optional setting tints only the attention satellite with the accent.

The grammar has four parts: a **core** (filled when the day is active), a **progress arc** (resolved planned tasks), a **satellite** at one o'clock (something wants you), and an **outer ring** (on call). Everything else is a variation of those.

State| When| Form| Motion| Sound| VoiceOver
---|---|---|---|---|---
Resting| Before first activity, weekends, after the boundary| Hollow ring, 55% opacity| None| None| "Cadence, day not started"
Day started| First activity recorded| Filled core, empty track| Pip in, 240 ms spring| `day.start`| "Day started at 10:02"
Plan pending| Plan prompt fired and no plan yet| Core and satellite| Satellite fades in, 180 ms| None| "Plan your day"
In progress| Plan set| Core and arc at resolved / planned| Arc eases on change, 400 ms| `capture.saved` on capture| "3 of 5 planned done"
Agent logged| MCP or hook write| Satellite| One orbit, 700 ms| `agent.logged`, off by default| Polite announcement
Wrap-up due| Reminder time passed, day not sealed| Arc and satellite| One pulse when the reminder fires| Notification sound| "Wrap-up due"
Sealed| Day sealed| Closed ring, core at 118%| Arc completes, core pops, 400 ms| `ring.closed` and trackpad haptic| "Day sealed, streak 19"
On call| Inside an on-call range| Adds an outer hairline ring| None| None| "On call"
Leave or holiday| Declared day| Short dash| None| None| "On leave"
Paused| Capture paused by you| Half-filled core| None| None| "Capture paused"
Needs attention| Store or collector error| Triangle outline| None| None| "Cadence needs attention"

#### Interactions

  * **Click** opens the Pocket. Click again or press `esc` to close.
  * **Option-click** opens the capture bar directly.
  * **Right-click** opens a menu: Start day now, End day now, Seal today, Leave…, On call…, Pause capture, Open Cadence, Quit.
  * **Hover** shows "6h 12m · 3 of 5 planned · streak 19".
  * **Drop** a PR or ticket URL, or a text selection, on the dot to start a capture pre-filled with it.


#### Build notes

  * Use AppKit `NSStatusItem` with a fixed length of 18 pt, not SwiftUI `MenuBarExtra`, which cannot do right-click menus, drops or custom animation.
  * Render the glyph with Core Animation layers (or a SwiftUI view in an `NSHostingView`) so state changes animate at 120 Hz without redrawing images.
  * Dot style setting: Dot only (default), Dot and day length (6h12), Dot and plan (3/5), in Geist Mono.
  * Increase Contrast thickens strokes to 1.8 pt. Reduce Motion replaces all motion with instant state changes.


### 4.2 The Pocket

It is a 340-point Liquid Glass panel that opens under the dot in under 100 ms because it is created at launch and kept warm. It is a non-activating panel (`NSPanel` with `.nonactivatingPanel`), so it can take typing without pulling your editor out of focus.

  * **Header** : date, time since first activity, and the streak chip.
  * **Ring and four numbers** : planned done, found today, signals, Claude Code sessions and time.
  * **Plan** : click a circle to mark done; right-click for slipped or dropped with a reason.
  * **Found today** : collected entries with a source glyph (GitHub, Claude Code, the Mac).
  * **Capture field** : the same parser as the capture bar.
  * **Actions** : Wrap up (`⌘↩`), Open Cadence, and a menu with leave, on-call and pause.


### 4.3 The capture bar

A floating glass bar, like Spotlight, opened by `⌃⌥L` from any app. You write one line; Cadence recognises tokens and turns them into chips while you type. Tab moves between chips; clicking a chip cycles or edits it. The parser is deterministic and lives in the core package, so it is unit-tested on Linux. When Apple Intelligence is available on the Mac, an on-device model can refine the parse; it never replaces the deterministic result without showing you.


**What the core parser returns**


Token| Recognised by| Becomes
---|---|---
Ticket| Config regex, default `\b[A-Z][A-Z0-9]{1,9}-\d{3,8}\b`, searched anywhere and in the first 12 characters of PR titles| Ticket chip, class **assigned** , or **self-initiated** when the number matches `^0+$`
PR or ticket URL| `…/pull/<n>`, `…/browse/<KEY>`| Link chip; resolved to a title when a collector has seen it
Kind verb| Lexicon, first match wins: reviewed, approved → review · merged, shipped, released → delivery · fixed, implemented, built, refactored, finished → work done · raised, proposed, brought up → discussion · challenged, pushed back → decision challenged · led, ran, facilitated, demoed → meeting led · attended, joined, sync, 1:1 → meeting · helped, paired, mentored, unblocked → mentoring · paged, incident, hotfix, mitigated → incident · prototyped, kicked off, automated, initiative → initiative · wrote, drafted, RFC, ADR → doc| Kind chip with family colour and shape; falls back to note
Time| `@10:30`, `at 3pm`, `yesterday`, `mon`, `27 oct`| Occurred time or day; past days are marked backfilled
Duration| `~2h`, `45m`, `for 1h30`| Duration chip
Count| Leading number with a kind noun: `3 reviews`, `attended 4 meetings`| Quantity
Tag| `#word`| Tag chip

### 4.4 Morning plan sheet


Static mock. Suggestions come from collectors only; Cadence never invents tasks. Planning more than seven tasks shows a quiet note, not a block.

### 4.5 Wrap-up deck

Four steps in one sheet, keyboard first. Each planned task gets a three-way toggle; slips take a reason chip instead of typed prose. Signal tiles count with a tap and take an optional one-line note on long press. Sealing closes the ring.


Stand-up text the wrap-up copies (template is configurable)


```
*Thu 29 Oct*
Done
• Shipped retry budget for capture path (ACME-482913), PR #412 merged
• Reviewed settlement batching RFC
• Paired on the flaky ledger test
Reviews 3 · PRs merged 1 · Claude Code 4 sessions
Next
• Draft idempotency ADR (slipped: reprioritised)
• Prototype webhook replay tool (ACME-000000)
Blockers: none
cadence 3f9ac21e77b01d4e
```


The last line is the witness code: the first 16 hex characters of a checkpoint hash in your ledger. Posted in Slack, it gives the proof file an independent timestamp. See section 12.

### 4.6 The window


Section| What it does
---|---
Today| Ring, activity strip, plan, found, signals. Same data as the Pocket, with room for edits and history.
Timeline| Day by day, newest first. Filter chips by family and origin. Search across titles, tickets and notes. Each entry opens a history popover showing every version with time and actor.
Insights| Heatmap, streak, plan vs done, delivery split, review cadence, leadership signals, day shape, AI. Section 5.
Recaps| Weekly story, month and cycle summaries, "since my last 1:1" with a date picker. Copy as text.
Evidence| Proof export: range presets, what is included, redaction toggles, preview, export and self-verify. Section 12.
Inbox| Entries proposed by agents, dictation and backfill. Accept, edit or dismiss, one by one or all.
Settings| General, Reminders, Capture, Sources, Tickets, Privacy, Data, About. The About pane reads the running app's own entitlements and shows "Network access: none".

### 4.7 Notifications

**Plan Thursday now**

2 carried over · 1 review waiting on you

Plan nowIn 30 minSkip today

**Wrap up Thursday 17:30**

9 found today · 3 of 5 planned done

Wrap upCopy stand-upAdd a line…In 30 min

**6 entries to review 09:48**

From Claude Code · dictation for Wed 28 Oct

Review

  * `UNUserNotificationCenter` with three categories: `PLAN`, `WRAP` and `INBOX`. "Add a line…" is a `UNTextInputNotificationAction`, so a quick entry never opens a window.
  * Reminder times are a list. Defaults: plan at day start plus 2 minutes, wrap-up at 17:30. The Reminders pane offers 16:00, 17:30 and 18:00 as one-tap chips and an "Add time" picker.
  * Wrap-up triggers are `UNCalendarNotificationTrigger`s rescheduled each morning for the next 7 workdays, skipping leave and holidays.
  * Notification text shows counts, never titles, by default, so a screen share never leaks work detail. "Show titles" is an opt-in.
  * Interruption level is `.active`. Time-sensitive delivery needs a restricted entitlement, so Cadence does not use it.
  * No streak or nag notifications. Milestones are celebrated inside the app.


### 4.8 Keyboard

Where| Keys
---|---
Anywhere (global, configurable)| `⌃⌥L` capture · `⌃⌥P` plan · `⌃⌥W` wrap-up. Registered with `RegisterEventHotKey`, which needs no Accessibility permission. The recorder warns on clashes with input-source shortcuts.
Capture bar| `↩` save · `⌘↩` save and keep open · `tab`/`⇧tab` move between chips · `⌫` on empty removes the last chip · `↑` edits the last entry · `esc` close
Wrap-up| `↑``↓` move · `1` done · `2` slipped · `3` dropped · `R` reason · `space` count a signal · `⌘↩` next step or seal
Window| `⌘1` to `⌘7` sections · `←``→` previous or next day · `T` today · `⌘F` search · `⌘E` export proof

### 4.9 System surfaces, later

App Intents for "Log to Cadence", "Start day" and "Seal today", which also surface as Spotlight actions and Shortcuts on macOS 26. A desktop widget with this week's heatmap. A Control Center control for capture. All in Phase 5, because none of them is needed to build the habit.


## 5. Insights and delight

Days become patterns: a cycle heatmap, a streak that leave never breaks, plan vs done, the assigned and self-initiated split, review cadence, day shape and AI use. Every chart opens with a computed finding and has a table twin.

All numbers in this section are example data for October 2026, generated for illustration.

### 5.1 Cycle heatmap

*Is the pattern steady?*


Rows are Monday to Friday; weekend work shows as small marks below Friday.Source: ledger · example data

The financial year starts on 1 October, so the cycle view runs October to September. Metrics: ring (share of planned tasks done on sealed days), delivery (PRs merged), review (PRs reviewed), leadership (signals), AI (sessions). A logged day with zero of something is the lightest step; a day with no entry at all is an empty outline.

### 5.2 The day ring

  * **Outer segments** are the day's planned tasks, one each. Done is solid ink, slipped is dashed, dropped is grey, open is the faint track.
  * **Inner beads** are everything else that happened, grouped by family in a fixed order so only neighbouring families touch: delivery, review, initiative, ownership, leadership, then AI. Each family has its own shape as well as colour.
  * **The centre** shows planned done as a fraction in Geist Mono.
  * **Sealing** draws a hairline through the gaps so the ring reads closed, then the dot in the menu bar closes with it.
  * It is one ring on purpose. Three concentric rings would read as Apple's Activity rings and invite the wrong goal of filling them.


### 5.3 Streak

*Did I account for every workday?*


Milestones at 5, 10, 20, 50, 100 and 200 workdays play the milestone sound once.Source: ledger · example data

### 5.4 Patterns

*Do I finish what I plan?*


Weeks start MondaySource: plan ledger

*How much of my work is self-started?*


Classified from the PR title prefixSource: GitHub collector

*What shape are my days?*


Times in Asia/KolkataSource: the Mac (observed)

*How am I using AI?*


Sessions from hooks; tokens from transcripts and your endpointSource: Claude Code

Also in v0.4: review cadence (days with at least one review, reviews per day), a leadership-signal strip by week, and slip reasons. Review turnaround (request to first review) comes later because it needs timeline events per PR.

### 5.5 Recaps

The weekly recap is a short story you page through with the arrow keys, ready after Friday's wrap-up and again on Monday's plan sheet. Each frame leads with a computed sentence. The findings engine works from templates and thresholds, so it never writes "best since last week" and never invents a trend from two points.

- 1/5: Week 44: you merged 4 PRs, reviewed 12 and raised 3 discussions. (26 to 30 Oct · 5 workdays)
- 2/5: 78%. 14 of 18 planned tasks done. 3 slipped: 2 reprioritised, 1 blocked.
- 3/5: Delivered: Retry budget for capture path · Webhook replay prototype (self-initiated) · Ledger test clock fix · Rate limiter review round
- 4/5: Presence: Led 2 meetings · challenged 1 decision · mentored twice · on call Tue to Wed, 1 incident
- 5/5: AI: Claude Code on 4 of 4 workdays · 19 sessions · 2 of 4 merged PRs AI-assisted

Also: month and cycle recaps, and "since my last 1:1" for any range. All copy as plain text or Markdown. When Apple Intelligence is available, an optional on-device pass can smooth the wording; the numbers always come from the deterministic findings.

### 5.6 Sound

Six original sounds in D major pentatonic, so any two that overlap still agree. Each is under 700 ms, rendered by a script in the repo so the sounds are reproducible and clearly open-source clean. Levels: Off, Subtle (default) and Full.

The app ships 44.1 kHz CAF files from `tools/make_sounds.swift`, normalised near -18 LUFS, played with `AVAudioPlayer` and never when the Mac is muted or a Focus mode asks for silence.

### 5.7 Motion and haptics

Token| Value| Used for
---|---|---
fast| 120 ms · ease| Hover, press, chip toggles
base| 180 ms · ease| Panels, satellite fade, list insertions
slow| 240 ms · ease| Pocket open, sheet steps
arc| 400 ms · ease| Ring and dot progress changes
spring| response 0.35 · damping 0.8| Day start pip, seal pop, milestone. Nothing else.
ease| cubic-bezier(.22,.61,.36,1)| Default curve, from your systems
value change| out 70 ms, in 160 ms, 6 px shift| Numbers change by fading in the direction of change; no digit rolls

Haptics use `NSHapticFeedbackManager` on Force Touch trackpads: `.alignment` when a toggle snaps, `.levelChange` when the ring closes. Reduce Motion removes every animation and keeps the end states.


## 6. Design system

Native first, your language second. SF Pro, SF Symbols and Liquid Glass make it feel like macOS 26; Claret colour, Geist Mono figures, hairlines and finding-first copy make it feel like yours.

### 6.1 Materials

Layer| Treatment| Where
---|---|---
Floating chrome| Liquid Glass: `.glassEffect(.regular, in: .rect(cornerRadius: 22))`, or `NSGlassEffectView` in AppKit panels| Pocket, capture bar, plan and wrap-up sheets, window sidebar and toolbar
Content| Matte `surface` with 1 px `hair` lines; no shadows except the resting card shadow| Lists, charts, tables, timeline
Floating info| `tip` colours, inverted per theme| Chart tooltips, history popovers
Controls| System controls with the system accent colour| Buttons, toggles, pickers. Cadence's accent is for data, not for controls.

Your web systems ban glass and glows. The app keeps that rule for content and lets macOS own the glass, because fighting the platform material makes a Mac app look foreign.

### 6.2 Colour

Neutrals are the cool greys from Policy Rate Atlas. Roles come from the Claret palette. Each swatch shows the value for the theme you are viewing; both values are listed under it.

#### Work families

Family| Token| Shape| Kinds| SF Symbols
---|---|---|---|---
Delivery| f-delivery| ● circle| `pr.opened` `pr.merged` `shipped` `work.done`| arrow.triangle.pull · arrow.triangle.merge · shippingbox · checkmark.circle
Review| f-review| ○ ring| `review.given` `doc.reviewed`| checkmark.bubble · eye
Initiative| f-initiative| ◆ diamond| `initiative.started` `initiative.progress`, and any PR with a self-initiated ticket| flag
Ownership| f-ownership| ■ square| `incident.handled` `oncall.shift`| bolt.horizontal · antenna.radiowaves.left.and.right
Leadership| f-leadership| ▲ triangle| `discussion.raised` `decision.challenged` `meeting.led` `mentoring` `doc.written`| bubble.left.and.text.bubble.right · exclamationmark.bubble · person.wave.2 · person.line.dotted.person · doc.text
AI| f-ai (neutral)| · small dot| `genai.session` `genai.usage`| terminal
Presence and notes| ink| none| `presence.span` `meeting.attended` `note`| sunrise · sunset · person.2 · text.alignleft

Validated with the data-viz palette checker: the five hues pass lightness, chroma, contrast and colour-blind separation for adjacent pairs in both themes. They do not pass when every pair can touch, which is why ring beads are grouped by family in a fixed order and every family also has a shape. AI is deliberately neutral: it is a tool you used, not an outcome.

### 6.3 Type

| Role | Font | Example |
|---|---|---|
| hero figure | Geist Mono 34/40 · 500 | 3/5 |
| title | SF Pro 22/28 · 650 | Thursday 29 Oct |
| finding | SF Pro 15/21 · 600 | You reviewed on 18 of 19 workdays this month. |
| body | SF Pro 13/18 · 400 | Ship retry budget for capture path |
| secondary | SF Pro 12/16 · 400 | Merged 16:02 · ledger-core · collected |
| caption, floor | SF Pro 11/14 · 500 | PLAN · FOUND TODAY |
| figure | Geist Mono 13/18 · 500 | 10:02 · 6h12 · ACME-482913 |

SF Pro is the system font; SwiftUI applies its optical sizes and tracking. Geist Mono (SIL OFL 1.1) is bundled and used only for figures that stand alone: ring centre, stats, times, ticket keys, hashes. Numbers inside sentences stay in SF Pro with tabular figures.

### 6.4 Space, shape, icons

#### Spacing

One 4-point rhythm: 2 4 6 8 12 16 20 24 32 48. Pocket padding 14, sheet padding 18, window content 22.

#### Radii, concentric

Inner radius = outer radius minus padding. Pocket 22, rows inside it 9 to 12, chips are capsules, data marks 2. Window corners follow macOS 26.

#### Icons

SF Symbols, hierarchical rendering, regular weight at 13 to 15 pt, medium in the Pocket. No custom icons except the dot and the app icon. No emoji anywhere.

### 6.5 Components

Component| Role| Key inputs
---|---|---
CadenceDot| Menu-bar glyph and its 11 states| `state`, `progress`, `tinted`, `style`
DayRing| Segments, beads, centre, sealed closure| `tasks: [TaskState]`, `beads: [Family]`, `sealed`, `size`
Heatmap| Cycle and quarter grid with hover card| `days`, `metric`, `range`, `today`
BeadChain| Streak strip| `days`, `milestones`
Chip| Kind, ticket (assigned or self), origin, time, duration, tag, link| `kind`, `value`, `editable`
TokenField| Capture input that turns tokens into chips| `parser`, `onCommit`
TriToggle| Done, slipped, dropped| `state`, `reasons`
SignalTile| Tap to count, long-press to note| `kind`, `count`
TimeChips| Reminder times with presets and "Add time"| `times`, `presets`
OriginBadge| observed, collected, agent, self| `origin`, `source`
ActivityStrip| Day spans on a time axis| `spans`, `now`
FindingCard| Kick question, finding, chart, table twin, source footnote| `finding`, `chart`, `rows`, `source`
StoryFrame| One recap frame| `page`, `content`
HistoryPopover| Every version of an entry with time and actor| `events`

### 6.6 Copy rules

  * Sentence case everywhere. Plain, specific, first person where it is your journal ("You reviewed on 18 of 19 workdays").
  * No en or em dashes in the interface. Ranges read "1 to 28 Oct" in sentences and "1 - 28 Oct" in compact labels.
  * Unknown is "-". A lower bound is "≥". An approximation is "≈". Never print 0 for something not recorded.
  * Words: Seal, Wrap up, Found today, Signals, Assigned, Self-initiated, Backfilled, After wrap-up. Never "productivity", "score", "missed", "you failed".
  * Times and dates follow the system locale. Weeks start Monday. Figures are tabular.
  * Provenance is a footnote or a quiet badge, never a celebratory pill such as "Verified!".


### 6.7 Accessibility

  * Every dot state has a VoiceOver label and changes are announced politely.
  * Identity is never colour alone: families have shapes, plan states have glyphs, heat cells print their value in the hover card and table twin.
  * Text meets 4.5:1 on its ground in both themes; meaningful marks meet 3:1.
  * Full keyboard operation; visible focus rings; Reduce Motion, Increase Contrast and Differentiate Without Colour are honoured.


## 7. Data model

An append-only, hash-chained event ledger in SQLite is the single source of truth. Days, entries and plans are projections rebuilt from it, so edit history and the proof file come for free.

### 7.1 Entities

Entity| Holds| Notes
---|---|---
Day| Local date, time zone in force, kind (workday, weekend, holiday, planned leave, unplanned leave), first and last activity, focus line, note, on-call flag, seal time| Stores its own zone so travel never rewrites history
Entry| Kind, family, title, occurred time, duration, quantity, ticket (key and class), links, tags, attributes, origin, source, source ref, status, backfilled, after-seal, export policy| The universal log record. Origin is immutable
Plan task| Day, position, title, ticket, estimate, origin (self, suggested, carried), status (open, done, slipped, dropped, moved), reason, linked entries, planned and resolved times| Plan vs done is computed only from these
Presence span| Start, end, source (input, wake, unlock, power log, manual)| Timestamps only, never app names or window titles
GenAI session| Session id, tool, start, end, end reason, project alias, models, turns| From Claude Code hooks
GenAI usage| Day, tool, model, source, sessions, requests, tokens in, out, cache read, cache write, cost in micro-dollars| One row per source; the projection picks one source per day
Witness| Checkpoint hash, purpose (stand-up), time| The code that ends your stand-up text

### 7.2 An entry

entries row, as the API returns it


```json
{
  "id": "01JBX7Q3K4Z8D2N6V0R5T9W1YE",
  "day": "2026-10-29",
  "kind": "pr.merged",
  "family": "delivery",
  "title": "Ship retry budget for capture path",
  "occurred_at": "2026-10-29T16:02:11+05:30",
  "ticket": { "key": "ACME-482913", "class": "assigned" },
  "links": [{ "kind": "pr", "url": "https://git.example.com/acme/ledger-core/pull/412" }],
  "attrs": { "repo": "acme/ledger-core", "number": 412, "additions": 184, "deletions": 37, "ai_assisted": true },
  "origin": "collected",
  "source": "github",
  "source_ref": "github:PR_kwDOAbc123:merged",
  "status": "accepted",
  "backfilled": false,
  "after_seal": false
}
```


### 7.3 The ledger

Every change is an event: creating an entry, editing a title, resolving a task, sealing a day. Each event stores a digest of its payload and the hash of the previous event. Projections are updated in the same transaction, and `cadence rebuild` replays the ledger to recreate them byte for byte.

Type| Subject| Payload| Written by
---|---|---|---
ledger.genesis| `ledger`| created, app version, profile| first run
day.started| `day:2026-10-29`| time, source| app
presence.span| `day:…`| start, end, source| app, presence backfill
day.declared| `day:…`| kind, label| app, CLI, MCP
plan.added · plan.updated · plan.resolved| `task:<ulid>`| task fields · changes as [old, new] · status, reason, links| app, CLI, MCP
entry.created · entry.updated · entry.status| `entry:<ulid>`| entry · changes as [old, new] · from, to| any writer; collectors only edit their own entries
day.sealed| `day:…`| counts, plan states, head before seal| app, CLI
witness.checkpoint| `day:…`| purpose| app (copy stand-up)
genai.session · genai.usage| `session:…` · `usage:…`| session or daily usage| spool drain, collectors, import
ingest.run| `run:<ulid>`| collector, window, counts, errors| collector runner
config.classifier| `config`| digests of the ticket patterns| app, CLI

event hashing (identical in Swift and in the Python verifier)


```
canon(x)    = UTF-8 of JSON with keys sorted, no whitespace, no floats   # cadence-c14n/1, a strict subset of RFC 8785
data_digest = sha256(canon(data))
hash        = sha256(canon({ v, seq, id, at, actor, type, subject, data_digest, prev }))
prev        = hash of event seq-1, or 64 zeros for genesis
```


Hashing the payload digest instead of the payload lets the proof file drop a private payload (a note, say) and keep the chain verifiable. Money and tokens are integers (micro-dollars, counts), so canonical JSON never has to format a float.

SQLite schema (DDL)

Sources/CadenceCore/Store/Schema.sql


```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 3000;
-- PRAGMA user_version holds the schema version; a binary refuses to write to a newer schema

CREATE TABLE events (
  seq         INTEGER PRIMARY KEY,      -- 1, 2, 3 … no gaps
  id          TEXT NOT NULL UNIQUE,     -- ULID
  v           INTEGER NOT NULL DEFAULT 1,
  at          TEXT NOT NULL,            -- recorded time, RFC 3339 UTC with ms
  actor       TEXT NOT NULL,            -- app | cli | mcp | hook | collector:<name> | import:<name>
  type        TEXT NOT NULL,
  subject     TEXT,
  data        TEXT NOT NULL,            -- canonical JSON
  data_digest TEXT NOT NULL,
  prev        TEXT NOT NULL,
  hash        TEXT NOT NULL UNIQUE
);
CREATE TRIGGER events_no_update BEFORE UPDATE ON events BEGIN SELECT RAISE(ABORT, 'ledger is append-only'); END;
CREATE TRIGGER events_no_delete BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT, 'ledger is append-only'); END;
CREATE INDEX events_subject ON events(subject);
CREATE INDEX events_type_at ON events(type, at);

-- projections: rebuildable from events with `cadence rebuild`
CREATE TABLE days (
  date TEXT PRIMARY KEY, tz TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'workday',   -- workday | weekend | holiday | leave_planned | leave_unplanned
  label TEXT, first_activity TEXT, last_activity TEXT,
  focus TEXT, note TEXT, on_call INTEGER NOT NULL DEFAULT 0,
  sealed_at TEXT, seal_event TEXT, updated_seq INTEGER NOT NULL
);
CREATE TABLE entries (
  id TEXT PRIMARY KEY, day TEXT NOT NULL REFERENCES days(date),
  kind TEXT NOT NULL, family TEXT NOT NULL, title TEXT NOT NULL,
  occurred_at TEXT, duration_s INTEGER, quantity INTEGER NOT NULL DEFAULT 1,
  ticket_key TEXT, ticket_class TEXT,     -- assigned | self | NULL
  links TEXT NOT NULL DEFAULT '[]', tags TEXT NOT NULL DEFAULT '[]', attrs TEXT NOT NULL DEFAULT '{}',
  origin TEXT NOT NULL,                   -- observed | collected | agent | self (never changes)
  source TEXT, source_ref TEXT UNIQUE,    -- idempotency key for collectors
  status TEXT NOT NULL DEFAULT 'accepted',-- proposed | accepted | dismissed | deleted
  backfilled INTEGER NOT NULL DEFAULT 0, after_seal INTEGER NOT NULL DEFAULT 0,
  export TEXT NOT NULL DEFAULT 'include', -- include | digest | exclude
  created_seq INTEGER NOT NULL, updated_seq INTEGER NOT NULL
);
CREATE INDEX entries_day ON entries(day);
CREATE INDEX entries_kind_day ON entries(kind, day);
CREATE TABLE plan_tasks (
  id TEXT PRIMARY KEY, day TEXT NOT NULL REFERENCES days(date),
  position INTEGER NOT NULL, title TEXT NOT NULL,
  ticket_key TEXT, ticket_class TEXT, estimate_min INTEGER,
  origin TEXT NOT NULL,                   -- self | suggested | carried
  carried_from TEXT REFERENCES plan_tasks(id),
  status TEXT NOT NULL DEFAULT 'open',    -- open | done | slipped | dropped | moved
  reason TEXT, reason_note TEXT, linked_entries TEXT NOT NULL DEFAULT '[]',
  planned_at TEXT NOT NULL, resolved_at TEXT,
  created_seq INTEGER NOT NULL, updated_seq INTEGER NOT NULL
);
CREATE TABLE presence_spans (
  id INTEGER PRIMARY KEY, day TEXT NOT NULL,
  start_at TEXT NOT NULL, end_at TEXT NOT NULL,
  source TEXT NOT NULL                    -- input | wake | unlock | powerlog | manual | collected
);
CREATE TABLE genai_sessions (
  session_id TEXT PRIMARY KEY, tool TEXT NOT NULL, day TEXT NOT NULL,
  started_at TEXT, ended_at TEXT, end_reason TEXT, project_alias TEXT,
  models TEXT NOT NULL DEFAULT '[]', turns INTEGER
);
CREATE TABLE genai_usage (
  day TEXT NOT NULL, tool TEXT NOT NULL, model TEXT NOT NULL DEFAULT '*', source TEXT NOT NULL,
  sessions INTEGER, requests INTEGER,
  tokens_in INTEGER, tokens_out INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER,
  cost_micros INTEGER,
  PRIMARY KEY (day, tool, model, source)
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```


### 7.4 Where it lives

~/Library/Application Support/Cadence/ (folder 0700, files 0600)


```
cadence.db        ledger and projections, WAL mode (-wal and -shm beside it)
config.json       your settings: ticket pattern, hosts, collectors, reminders. Never in git
spool/            hook lines waiting to be ingested, one NDJSON file per day
jobs/             requests from the app to the collector agent (backfill, run now)
inbox/            envelopes that failed validation, kept for inspection
exports/          proof files you exported
backups/          daily VACUUM INTO snapshots: 14 daily, 8 weekly
logs/             collector and agent logs, rotated at 1 MB
```


Outside iCloud Drive and outside any app container, so the CLI reads it without privacy prompts and Time Machine backs it up if you use it. FileVault provides encryption at rest; Cadence adds no crypto dependency of its own.

Example config.json (the repo ships this with ACME; your real values stay local)

config.example.json


```json
{
  "cadence": "config/1",
  "profile": { "name": "Your Name", "role": "Software Engineer", "timezone": "Asia/Kolkata" },
  "workdays": ["mon", "tue", "wed", "thu", "fri"],
  "dayBoundary": "04:00",
  "reminders": [
    { "kind": "plan", "after": "dayStart+2m" },
    { "kind": "wrap", "at": "17:30" }
  ],
  "tickets": {
    "pattern": "\\b(?<key>[A-Z][A-Z0-9]{1,9}-(?<num>\\d{3,8}))\\b",
    "titleWindow": 12,
    "selfInitiated": "^0+$",
    "linkTemplate": "https://tickets.example.com/browse/{key}"
  },
  "team": { "timezone": "America/Sao_Paulo", "hours": ["09:00", "18:00"] },
  "sounds": "subtle",
  "claudeCode": { "injectPlanAtSessionStart": true, "projectsDir": "~/.claude/projects" },
  "privacy": { "notificationTitles": false, "exportSpans": false, "projectAliases": true },
  "collectors": {
    "github": { "enabled": true, "builtin": "github", "env": { "GH_HOST": "git.example.com" }, "gh": "/opt/homebrew/bin/gh", "every": "30m" },
    "claude-code": { "enabled": true, "builtin": "claude-code-transcripts", "every": "60m" },
    "genai-endpoint": { "enabled": false, "command": ["/usr/bin/curl", "-fsS", "--max-time", "20", "http://127.0.0.1:PORT/usage?from={since}&to={until}"], "map": "maps/genai-endpoint.json", "at": ["17:10"] }
  }
}
```


## 8. Architecture

Three processes of ours share one SQLite file and signal each other with files and a Darwin notification. Nothing listens on a port or a socket, and the only network traffic comes from tools you already trust, run outside the app.

- Claude Code (hooks and MCP client), you in Terminal (`cadence log`, `plan`, `export`) and the collector agent (launchd user agent, every 15 min, `cadence collect run --due`) all run the `cadence` binary.
- The `cadence` binary is unsandboxed and has no network code: mcp, hook, log, plan, collect, ingest, import, export, verify, doctor.
- Network happens only in collector commands the agent executes: `gh api graphql` to GitHub Enterprise, `curl` to your usage endpoint. The agent reads their JSON from stdout.
- The Cadence store at `~/Library/Application Support/Cadence/` holds `cadence.db` (the ledger), `spool/` (hook lines), `jobs/` (app to agent), `exports/` and `backups/`. Writers use SQLite WAL transactions.
- Cadence.app runs in the App Sandbox with no network entitlement: login item, menu-bar dot, Pocket, sheets, window, capture bar, hotkeys, presence engine (NSWorkspace, CGEventSource), notifications (UNUserNotificationCenter), spool drain, backups, optional on-device model (Foundation Models). It registers the login item and collector agent with SMAppService, reads and writes `jobs/`, which wakes the agent (launchd WatchPaths), and receives a Darwin notification (store-changed) when the store changes.

The cadence binary is one executable used three ways. The app is the only long-running process; MCP and hooks keep working while it is quit.

### 8.1 Processes

Process| Sandbox| Network| Runs| Does
---|---|---|---|---
Cadence.app| App Sandbox| None; macOS blocks it| Always, as a login item| UI, presence capture, reminders, spool drain, backups, registering the collector agent
`cadence` CLI| No (command-line tool)| No networking code| When you, a hook or Claude Code call it| Every store operation, the MCP server, hooks, exports, verification
Collector agent| No| Only through the commands it executes| Every 15 min, at login, and when `jobs/` changes| Runs due collectors, validates their output, writes entries

### 8.2 Why a shared file and not a socket

  * **It works when the app is closed.** Hooks and MCP write straight to the store, so a quit or crashed app never loses a Claude Code session.
  * **Nothing listens.** No TCP port, no Unix socket, no XPC service to secure.
  * **One rulebook.** Every process links the same CadenceCore, so invariants such as immutable origin are enforced everywhere.
  * **A linear chain.** Writers take `BEGIN IMMEDIATE`; the previous hash is read and the new event appended inside that transaction, so SQLite serialises the chain.
  * Rejected: a socket owned by the app (fails when the app is not running), an XPC Mach service (strong, but not testable on Linux and more moving parts; revisit only if contention appears), localhost HTTP (a listener, ruled out).


### 8.3 Sandbox, entitlements, signing

Resources/Cadence.entitlements


```
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key>
<array><string>/Library/Application Support/Cadence/</string></array>
<!-- deliberately absent:
     com.apple.security.network.client
     com.apple.security.network.server -->
```


  * The app is sandboxed with no network keys, so any connection attempt fails at the OS level. `make check` fails if a network key ever appears (`tools/check_entitlements.sh`).
  * The CLI and agent are signed with the hardened runtime and no entitlements.
  * Default signing is ad-hoc ("Sign to Run Locally"). A locally built app has no quarantine flag, so Gatekeeper does not block it. No Apple account needed.
  * Ad-hoc signatures change each build, so macOS may ask you to re-allow the login item after an update. A free personal Apple Development team gives a stable identity if that gets annoying.
  * Installed to `~/Applications` and `~/.local/bin`. No admin at any step.


### 8.4 Presence engine

Pure logic in CadenceCore, fed by a thin macOS adapter. The adapter samples idle time with `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)` (any input, no Accessibility permission) every 30 s while active and every 60 s while idle, plus `NSWorkspace` wake, sleep, screen lock and unlock, and session notifications.

PresenceEngine, simplified


```
on sample(t, idle, unlocked):
  active = unlocked && idle < 5s
  day = workday(t, boundary: 04:00, tz)                # spans split at the boundary
  if active and open span == nil: open span at t - idle
  if !active and open span != nil and idle >= 300s:  close span at t - idle
  if active and day.first_activity == nil:
      emit day.started(day, at: t - idle, source: "input")
on sleep, lock, logout, power-off: close span at event time
last_activity(day) = end of the last closed span in day   # never typed
```


Tests feed synthetic sample streams: overnight-awake Mac, a lock at 13:00 and unlock at 14:00, a crash with no close event, a time-zone change, a late night past the boundary. Backfill of October presence parses `pmset -g log` wake and sleep lines from the CLI, if the log still holds them; those spans are labelled "power log".

### 8.5 Modules

SwiftPM target| Platform| Contents
---|---|---
CadenceCore| macOS, Linux| Domain types, store and migrations, ledger and canonical JSON, projections, ticket classifier, capture parser, presence engine, streaks and insights, findings, stand-up templates, proof export and verify
CadenceIngest| macOS, Linux| Envelope schema and validation, collector runner, JSON mapping, GitHub mapper, Claude Code transcript reader, CSV and JSON import
CadenceMCP| macOS, Linux| JSON-RPC 2.0 over stdio, tool registry, schemas, both protocol revisions
cadence| macOS, Linux| CLI with Swift Argument Parser
CadenceUI| macOS| SwiftUI views and design tokens, previewable in Xcode, rendered to PNG by `make snapshots`
CadenceApp| macOS| App lifecycle, status item, panels, notifications, presence adapter, hotkeys, login item, Foundation Models interpreter

Dependencies: Apple-maintained packages only. Swift Argument Parser for the CLI. SwiftCrypto on Linux only for SHA-256; macOS uses CryptoKit. SQLite is the system library on macOS and `libsqlite3-dev` on Linux. Versions pinned, `Package.resolved` committed.

### 8.6 Budgets

Measure| Target
---|---
App idle CPU| < 0.1%
App memory| < 60 MB
Pocket or capture bar open| < 100 ms
Hook run| < 10 ms (spool append only)
MCP day query| < 100 ms p95
Store growth| ≈ 5 MB per year

### 8.7 Things to prove on your Mac first

These are platform behaviours I am confident about but cannot test from Linux. Phase 0 ships `make spike`, which checks what it can automatically and prints PASS or FAIL.

| Claim| If it fails
---|---|---
S1| An ad-hoc signed, sandboxed app with the home-relative exception can read and write the store while the CLI writes too (verify)| Ship unsandboxed with the hardened runtime and keep the entitlement and symbol checks in `make check`
S2| `SMAppService.mainApp` and `.agent` register from `~/Applications` on a managed Mac (verify)| A user LaunchAgent plist in `~/Library/LaunchAgents`, written by `make install`
S3| Notifications, including text-input actions, work for the ad-hoc app (verify)| Plain actions plus the capture bar
S4| Idle time and workspace notifications work in the sandbox (verify)| Move sampling into the agent
S5| `RegisterEventHotKey` works in the sandbox (verify)| Option-click the dot; Shortcuts app binding
S6| A Darwin notification posted by the CLI reaches the sandboxed app (verify)| Poll `PRAGMA data_version` every 2 s while visible, 30 s otherwise
S7| Apple Intelligence is enabled on the work Mac (verify)| Deterministic parser only; nothing else changes
S8| The app builds with Command Line Tools only (`swift build` plus the bundle script) (verify)| Install Xcode into `~/Applications`
S9| Claude Code transcript lines carry `message.usage` and `model` as expected (verify)| Tokens from the endpoint and import only


## 9. Agents, MCP, CLI

Claude Code gets your powers minus the ones that would make the log less honest. It can log, plan and read; it cannot accept its own proposals, seal a day, change config or touch presence.

### 9.1 Setup on the Mac

once, after make install


```sh
cadence doctor
claude mcp add --transport stdio --scope user cadence -- "$HOME/.local/bin/cadence" mcp
cadence setup claude-code --print        # prints the hooks block below; --apply merges it with a backup
```


### 9.2 MCP server

`cadence mcp` speaks JSON-RPC 2.0 over stdin and stdout, logs only to stderr, and returns tools in a fixed order. It supports both MCP revisions current in October 2026: **2025-11-25** with the `initialize` handshake, and **2026-07-28**, which is stateless, carries the protocol version in each request's `_meta` (read from `io.modelcontextprotocol/protocolVersion`, with a plain `protocolVersion` accepted too until the key is confirmed against a shipping client), requires `server/discover`, and adds `resultType` to every result. Every result includes `resultType: "complete"`, which older clients ignore.

Tool| Purpose| Lands as
---|---|---
log_entry| One entry from a natural line or explicit fields| Accepted for today; proposed for past days
log_entries| Many entries, such as a dictation transcript. `dry_run` defaults to true and returns a preview table| Proposed, in the Inbox
plan_add| Add tasks to a day's plan| Accepted, origin agent
plan_update| Resolve or edit a task, with a reason for slips| Accepted, origin agent
declare_day| Mark leave or a holiday| Accepted, origin agent
get_day| Plan, entries, presence and ring for a date| Read
query| Entries in a range with filters, paginated with a cursor, 200 per page| Read
summary| Counts, streak, plan accuracy and findings for a range| Read
standup| Stand-up text for a day| Read

Resources: `cadence://day/{date}`, `cadence://week/current`. Prompts, which Claude Code shows as slash commands: `/mcp__cadence__import-dictation`, `/mcp__cadence__standup`, `/mcp__cadence__weekly-recap`. Results stay under 20,000 characters, well inside Claude Code's 25,000-token default.

log_entry schema and a result

tools/list entry


```json
{
  "name": "log_entry",
  "description": "Record one work outcome in Cadence, the user's local work log. Use after finishing something the user would mention in stand-up. Prefer 'text' in the user's words; Cadence parses ticket keys, kind, time and duration. Do not log routine tool calls.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "text":         { "type": "string", "maxLength": 500 },
      "kind":         { "type": "string", "description": "Override the parsed kind, e.g. work.done, review.given, discussion.raised" },
      "date":         { "type": "string", "format": "date" },
      "occurred_at":  { "type": "string", "description": "RFC 3339, or HH:MM in local time" },
      "ticket":       { "type": "string" },
      "links":        { "type": "array", "maxItems": 5, "items": { "type": "object", "required": ["url"],
                        "properties": { "url": { "type": "string", "format": "uri" }, "kind": { "enum": ["pr", "ticket", "doc", "other"] } } } },
      "duration_min": { "type": "integer", "minimum": 1, "maximum": 720 },
      "quantity":     { "type": "integer", "minimum": 1, "maximum": 50 },
      "note":         { "type": "string", "maxLength": 1000 }
    },
    "required": ["text"],
    "additionalProperties": false
  }
}

// result
{
  "resultType": "complete",
  "structuredContent": {
    "status": "accepted",
    "entry": { "id": "01JBX9…", "day": "2026-10-29", "kind": "work.done", "family": "delivery",
               "title": "Fixed flaky ledger test with deterministic clock", "ticket": { "key": "ACME-482913", "class": "assigned" },
               "origin": "agent" }
  },
  "content": [{ "type": "text", "text": "Logged for Thu 29 Oct: Fixed flaky ledger test with deterministic clock (ACME-482913)." }]
}
```


### 9.3 Hooks

merged into ~/.claude/settings.json


```json
{
  "hooks": {
    "SessionStart":  [{ "hooks": [{ "type": "command", "command": "\"$HOME/.local/bin/cadence\" hook session-start", "timeout": 5 }] }],
    "SessionEnd":    [{ "hooks": [{ "type": "command", "command": "\"$HOME/.local/bin/cadence\" hook session-end", "timeout": 5 }] }],
    "Stop":          [{ "hooks": [{ "type": "command", "command": "\"$HOME/.local/bin/cadence\" hook stop", "async": true }] }],
    "TaskCompleted": [{ "hooks": [{ "type": "command", "command": "\"$HOME/.local/bin/cadence\" hook task-completed", "async": true }] }]
  }
}
```


  * `cadence hook <event>` reads the hook JSON from stdin, keeps an allowlist of fields (session id, event, source or reason, cwd, model, time), appends one line to `spool/` with `O_APPEND`, and exits 0. It never opens SQLite, so it cannot block Claude Code, and it fits SessionEnd's shared 1.5 s budget with room to spare.
  * The app and any later `cadence` run drain the spool into `genai.session` events. Tokens come separately from the transcripts collector.
  * With `injectPlanAtSessionStart` on, the SessionStart hook prints one short line to stdout, which Claude Code adds as context: "Cadence plan for Thu 29 Oct, 2 of 4 done: retry budget rollout; idempotency ADR; …". It reads the store read-only with a 200 ms limit and prints nothing if that fails.
  * The working directory is stored as a project alias (the folder name), and exports can replace aliases with `project-1`, `project-2`.
  * TaskCompleted field names are not yet confirmed; the hook stores whatever allowlisted fields arrive (verify).


### 9.4 A Claude Code skill in the repo

integrations/claude-code/skills/cadence/SKILL.md


```
---
name: cadence
description: Log work to Cadence, the user's local work log. Use when the user finishes something they would mention in stand-up, asks to log or plan, or pastes a dictation transcript to file.
---
# Cadence
- Log outcomes with the log_entry tool, one line, past tense, in the user's words, with the ticket key if one is in play.
  Good: "Fixed flaky ledger test with deterministic clock ACME-482913". Not: "ran the tests".
- One entry per outcome. Ask before logging more than five in a session.
- For a pasted transcript: call log_entries with dry_run true, show the table, then call again with dry_run false. Entries go to the user's Inbox.
- Never invent times, tickets or counts. If the date is unclear, ask.
- Accepting, sealing, deleting and presence belong to the user. Do not try them through the CLI either.
```


### 9.5 CLI

Command| Does
---|---
`cadence today`| Today's ring, plan and entries; `--json` everywhere
`cadence log "<text>"`| Parse and record; flags `--kind --at --date --ticket --link --qty`
`cadence plan add|list|done|slip|drop`| Manage the day's plan; `slip --reason reprioritised`
`cadence day start|end|seal|leave|holiday`| Manual corrections, always recorded with origin self
`cadence inbox list|accept|dismiss`| Review proposals from agents, dictation and backfill
`cadence query --from --to [--kind --family --origin]`| Entries as a table, JSON or NDJSON
`cadence summary --range week|month|cycle|A..B`| Metrics and findings
`cadence standup [--date] [--copy]`| Stand-up text with the witness code
`cadence collect run [--due] [--name] [--since --until]`| Run collectors now; the agent calls `--due`
`cadence collector github|claude-code`| Built-in collectors; print an envelope to stdout
`cadence ingest [-|FILE] [--dry-run]`| Validate and write an envelope
`cadence import genai FILE --map MAP [--dry-run]`| Import usage history, such as your October data
`cadence presence backfill --since 2026-10-01`| First and last activity from the power log, where it exists
`cadence export proof --from --to [-o FILE]`| Write a proof file
`cadence verify FILE [--recompute]`| Check a proof file; `--recompute` also reports what it could not recompute: hash-only events in range, whose payloads stay on the owner's Mac. Items are always re-derived from their events
`cadence hook <event>` · `cadence mcp`| Claude Code integration
`cadence doctor` · `cadence rebuild` · `cadence config get|set|path`| Health checks, projection rebuild, settings

Exit codes: 0 ok, 1 usage, 2 validation, 3 store busy, 4 not found. The CLI records `origin: self`; MCP records `origin: agent`. An agent can run the CLI through a shell, so the guard is honesty in the record, not a lock: accepting never changes an entry's origin.


## 10. Collectors

A collector is any command that prints one envelope of JSON lines. The agent runs it, Cadence validates every record, dedupes by source ref and writes it with origin collected. Network access lives in tools you already trust, like gh and curl, never in Cadence.

### 10.1 The envelope

envelope/1: first line is the header, then one record per line


```json
{"cadence":"envelope/1","collector":"github","run":"01JBY0M8R2","generated_at":"2026-10-29T16:10:02+05:30","window":{"since":"2026-10-26","until":"2026-10-29"}}
{"type":"item","source_ref":"github:PR_kwDOAbc123:merged","kind":"pr.merged","occurred_at":"2026-10-29T16:02:11+05:30","title":"ACME-482913 Ship retry budget for capture path","links":[{"kind":"pr","url":"https://git.example.com/acme/ledger-core/pull/412"}],"attrs":{"repo":"acme/ledger-core","number":412,"additions":184,"deletions":37,"ai_assisted":true}}
{"type":"item","source_ref":"github:PRR_kwDOAbc777","kind":"review.given","occurred_at":"2026-10-29T11:20:40+05:30","title":"ACME-000000 Idempotency keys for refunds","links":[{"kind":"pr","url":"https://git.example.com/acme/refunds/pull/88"}],"attrs":{"repo":"acme/refunds","number":88,"state":"APPROVED","comments":4}}
{"type":"genai.usage","source_ref":"claude-code:2026-10-28:model-a","day":"2026-10-28","tool":"claude-code","model":"model-a","sessions":5,"requests":212,"tokens":{"in":48210,"out":96115,"cache_read":8120400,"cache_write":402118}}
{"type":"presence.span","source_ref":"powerlog:2026-10-05T09:12","start":"2026-10-05T09:12:00+05:30","end":"2026-10-05T19:40:00+05:30"}
{"type":"leave","source_ref":"leave:2026-10-23","day":"2026-10-23","kind":"leave_planned","label":"Planned leave"}
```


Record| Required| Optional| Becomes
---|---|---|---
`item`| source_ref, kind, title, occurred_at or day| ticket (otherwise parsed from the title), links, attrs, duration_s, quantity, tags| `entry.created`, later `entry.updated`
`genai.usage`| source_ref, day, tool| model, sessions, requests, tokens.in, out, cache_read, cache_write, cost_micros, estimated (true when the cost came from a price table)| One `genai_usage` row for that source
`presence.span`| source_ref, start, end| none| Fills gaps only. Never overrides spans the Mac observed
`leave`| source_ref, day, kind| label| `day.declared`, only if you have not declared that day yourself

#### Validation

  * UTF-8, one JSON object per line, at most 10 MB and 20,000 records. Unknown record types and unknown top-level fields are rejected.
  * Times are RFC 3339 with an offset. `day` is `YYYY-MM-DD` in your profile zone. Numbers are non-negative integers; money is micro-dollars.
  * Titles lose control characters and are cut at 200 characters. `attrs` is flat, holds strings, integers and booleans, and stays under 2 KB.
  * Links must be `https` (or `http` on a host in `config.hosts`). Anything else, `javascript:` included, is dropped with a warning.
  * A bad record is skipped and counted in `ingest.run`. When any record is skipped, the whole envelope is kept in `inbox/` so you can see why.


#### Idempotency and ownership

  * Same `source_ref`, same content: nothing is written. Changed content: `entry.updated` with actor `collector:<name>`.
  * A collector only edits entries it created, and only fields you have not touched. Once you edit a title, that field is yours and later collector changes to it are ignored.
  * Collectors never delete. A PR that was opened and later closed keeps its `pr.opened` entry; you can dismiss it.
  * Collected entries arrive accepted because they carry a link to the source. If the day is already sealed they are marked **after wrap-up** and listed under "Since you sealed".


### 10.2 The runner

Rule| Detail
---|---
When| `cadence collect run --due` from the agent every 15 minutes, at login, and whenever the app drops a job in `jobs/` ("Run now", backfill). Each collector sets `every` or `at`
Window| `since` is the last successful `until` minus 3 days, so late merges and edited reviews are caught; `until` is now. Backfill from `profile.backfillFrom` (2026-10-01 for you) runs in 7-day chunks
Execution| An argv array, never a shell. The first element is an absolute path. `{since}` and `{until}` are replaced inside argv elements only. stdin is closed and the working directory is the Cadence folder
Environment| `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME`, `LANG`, `TZ`, plus the keys listed in the collector's `env`. Nothing else is inherited
Limits| 60 s, then SIGTERM, then SIGKILL after 5 s. stdout is capped at 10 MB; the last 64 KB of stderr goes to `logs/`
Approval| The first time a command runs, or after it changes, the app shows the exact argv and env keys and asks. It stores a digest of what you approved, and the agent refuses anything else
Config safety| `config.json` must be owned by you and mode 0600. Otherwise collectors are disabled and `cadence doctor` says why
Failure| A non-zero exit, a timeout or an unreadable header writes nothing except an `ingest.run` with the error. The dot shows the error state only after three failures in a row for the same collector
Concurrency| One run per collector at a time, guarded by a lock file. Runs are serial in v1

### 10.3 GitHub (built in)

`cadence collector github --since A --until B` runs `gh api graphql` with `GH_HOST` from the collector's env, so it works against GitHub Enterprise Server and github.com and reuses the login gh already has. Cadence never sees a token.

contributions query (paged 100 at a time)


```
query($from: DateTime!, $to: DateTime!, $prs: String, $reviews: String) {
  viewer {
    login
    contributionsCollection(from: $from, to: $to) {
      pullRequestContributions(first: 100, after: $prs) {
        pageInfo { hasNextPage endCursor }
        nodes { pullRequest { id number title url isDraft createdAt additions deletions bodyText
                              repository { nameWithOwner } } }
      }
      pullRequestReviewContributions(first: 100, after: $reviews) {
        pageInfo { hasNextPage endCursor }
        nodes { pullRequestReview { id state submittedAt comments { totalCount } }
                pullRequest { id number title url author { login } repository { nameWithOwner } } }
      }
    }
  }
}
```


merged PRs come from search, because contributions are keyed by creation date


```
search(type: ISSUE, first: 100, after: $cursor,
       query: "is:pr author:LOGIN merged:2026-10-26..2026-10-29") {
  pageInfo { hasNextPage endCursor }
  nodes { ... on PullRequest { id number title url mergedAt additions deletions bodyText repository { nameWithOwner } } }
}
```


On GitHub| Entry| Time| Notes
---|---|---|---
A PR you opened| `pr.opened`| createdAt| Drafts included, `attrs.draft`
A PR of yours merged| `pr.merged`| mergedAt| From search, deduped against `pr.opened` by PR id
A review you submitted| `review.given`| submittedAt| One entry per PR per day; `attrs.reviews` counts repeats, `attrs.comments` counts comments. Reviews on your own PRs are skipped. The PR author's login is used for that check and then discarded

  * **Tickets.** `tickets.pattern` runs over the first `titleWindow` characters of the title. A number matching `selfInitiated` (all zeros by default) makes the PR self-initiated and puts it in the Initiative family. No match means no ticket, shown as "untracked" without judgement.
  * **AI-assisted.** True when the PR body contains one of `ai.markers`, case-insensitive. The default markers are "Generated with Claude Code" and "Co-Authored-By: Claude", which Claude Code adds by default. The body is read in memory and dropped; only the boolean is stored.
  * Whether contribution lists include private and internal repositories on your Enterprise version needs a check (verify). If they do not, the fallback is search: `is:pr author:LOGIN created:A..B` and `is:pr reviewed-by:LOGIN updated:A..B`, then the viewer's reviews per PR.


### 10.4 Claude Code transcripts (built in)

Reads `~/.claude/projects/*/*.jsonl` incrementally, remembering each file's size and modification time. The decoder is a struct with only these fields, so nothing else is ever parsed into memory as data: `message.id`, `message.model`, `message.usage` (input, output, cache creation and cache read tokens), `timestamp`, `sessionId`.

  * Streaming can write several lines for one message. Lines are deduped by `message.id`, keeping the one with the most output tokens (verify) (spike S9).
  * Totals are computed per local day and model, with sessions (distinct session ids) and requests (distinct message ids), and emitted with `source_ref` `claude-code:DAY:MODEL`. A re-read updates the same rows.
  * Cost is not computed here unless you keep a price table in `config.genai.prices`, in which case it is labelled estimated. The table maps a model name to `{"in", "out", "cache_read", "cache_write"}`, each a whole number of micro-dollars per million tokens (a key left out counts as 0); a model with no entry gets no cost, and the cost is computed with integer arithmetic only. Your endpoint's cost always wins.
  * Run it as `cadence collector claude-code-transcripts --since DAY --until DAY [--name NAME] [--projects-dir DIR]`. Per-message figures from every file are cached in `state/`, so unchanged files are not read again but each day's totals stay complete, and totals survive Claude Code deleting old transcripts.


**Do this today.** Claude Code deletes transcripts older than `cleanupPeriodDays`, 30 by default, so your 1 October sessions disappear around 31 October. Add `"cleanupPeriodDays": 400` to `~/.claude/settings.json` now. Once Cadence has collected a day, its totals live in the ledger and later deletion no longer matters.

### 10.5 Your usage endpoint

The endpoint is just a command, `curl` in the example config (7.4), whose output is not an envelope. A map file turns any JSON or CSV into `genai.usage` records. If the endpoint needs a token, curl reads the header from a 0600 file with `-H @/Users/you/.config/cadence/usage.header`, so the token never enters Cadence or its config.

maps/genai-endpoint.json (written on your Mac by Claude Code from a real sample; never in git)


```json
{
  "cadence": "map/1",
  "input": "json",
  "produces": "genai.usage",
  "records": "$.data[*]",
  "fields": {
    "day":                { "path": "$.date", "format": "yyyy-MM-dd" },
    "tool":               { "const": "claude-code" },
    "model":              { "path": "$.model", "default": "*" },
    "requests":           { "path": "$.request_count" },
    "tokens.in":          { "path": "$.input_tokens" },
    "tokens.out":         { "path": "$.output_tokens" },
    "tokens.cache_read":  { "path": "$.cache_read_tokens", "default": 0 },
    "tokens.cache_write": { "path": "$.cache_creation_tokens", "default": 0 },
    "cost_micros":        { "path": "$.cost_usd", "scale": 1000000 }
  },
  "source_ref": "genai-endpoint:{day}:{tool}:{model}"
}
```


  * **Paths** are a small JSONPath subset: `$`, `.key`, `['key']`, `[n]`, `[*]`. No filters and no scripts.
  * **Formats** for days and times: `yyyy-MM-dd`, `iso8601`, `epoch-s`, `epoch-ms`, converted in your profile zone.
  * **Scale** is exact decimal arithmetic on the text, so `"0.4213"` dollars becomes 421300 micro-dollars with no float in between. Digits finer than one unit are rounded half away from zero. Number fields without a scale must be whole numbers.
  * **Bad records.** A record that cannot be mapped is left out, counted as skipped in `ingest.run` with its reason, and the output is kept in `inbox/`.
  * **CSV** with `"input": "csv"` turns each row into an object keyed by header, so `$.output_tokens` reads that column.


### 10.6 Importing your October data

  1. Export from your existing app to a file (CSV or JSON).
  2. Ask Claude Code on the Mac to write `maps/october-app.json` from the first rows. The real format never leaves your machine or reaches the repo.
  3. Dry run, then import. Cadence records the rows with source `import:october-app` and marks them backfilled. It does not keep the file.


```sh
cadence import genai ~/Downloads/october-usage.csv --map maps/october-app.json --dry-run
map october-app (map/1, csv) · 31 rows → 21 days · tool claude-code
day         requests   tokens out   cost       other sources
2026-10-01       118       51,302   $14.21     none
2026-10-02         0            0   $0.00      none        holiday
2026-10-05       164       77,940   $19.87     none
…
2026-10-28       212       96,115   $26.40     transcripts 95,880 (0.2% apart)
total          3,410    1,602,551   $431.06
dry run: nothing written. Run again without --dry-run to import.
```


**One source per day, never summed.** For each day and tool the projection uses the first available of endpoint, transcripts, import (`genai.priority` in config). The others stay visible in the day's detail, and if they disagree on output tokens by more than 15% the day carries a small mismatch mark.

### 10.7 Writing your own

~/.config/cadence/collectors/oncall.sh: on-call shifts from a local file


```sh
#!/bin/sh
# prints a Cadence envelope/1 for shifts listed as "2026-10-12,primary" lines
set -eu
printf '{"cadence":"envelope/1","collector":"oncall","generated_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
while IFS=, read -r day role; do
  printf '{"type":"item","source_ref":"oncall:%s","kind":"oncall.shift","day":"%s","title":"On call (%s)"}\n' "$day" "$day" "$role"
done < "$HOME/.config/cadence/oncall.csv"
```


Register it with `"command": ["/bin/sh", "/Users/you/.config/cadence/collectors/oncall.sh"]`, approve it once, and run `cadence collect run --name oncall`. The repo ships this script and a Python twin under `examples/collectors/`.


## 11. GenAI tracking

Lead with whether AI is part of how you ship: days used, AI-assisted merges, sessions, entries your agent logged. Tokens and cost sit underneath, always with their source named, and never move the ring or the streak.

- Sources: Claude Code hooks (session start and end) → `genai_sessions`, one row per session, AI beads. Usage endpoint (curl + map/1, priority 1), transcripts (`~/.claude/projects`, priority 2) and the October import (file + map/1, priority 3) → `genai_usage`, one row per day, tool, model and source; all sources kept, mismatch over 15% flagged.
- Daily pick: the first source present wins, never summed. Read by the Pocket stat, the AI chart, recaps, the proof summary and the optional stand-up line.

Every source is stored; the charts read one per day. A day with no source shows as no data, not zero.

### 11.1 Metrics

Metric| Definition| Source| Where
---|---|---|---
AI days| Workdays with at least one session or usage row, out of workdays in range| hooks, any usage source| Pocket, recap, proof
AI-assisted merges| Merged PRs with an AI marker, out of merged PRs| GitHub collector| AI chart, recap, proof
Sessions| Claude Code sessions started; median length| hooks| Window, AI chart
Agent-logged entries| Accepted entries with origin agent| ledger| Window, recap
Output tokens| Per day and model| daily pick| AI chart detail
Cache reuse| Cache read ÷ (input + cache read)| daily pick| Detail only
Cost| USD from the endpoint; otherwise estimated from your price table; otherwise hidden| daily pick| Detail, recap if enabled
Model mix| Share of output tokens by model| daily pick| Detail

### 11.2 Rules

  * The ring counts outcomes. Each Claude Code session adds one neutral AI bead, capped at three per day; usage numbers add none.
  * Unknown is not zero. Days before your first source, or with no source at all, are hatched and say "no record".
  * Every number shows its source on hover: "from endpoint", "from transcripts", "imported", "estimated".
  * Never stored: prompts, responses, code, file names. Working folders become project aliases.
  * The stand-up line is off by default. When on, it reads "AI: 4 sessions · 2 of 3 merges AI-assisted".


**The sentence your review needs** , computed for the cycle recap and the proof summary: "AI on 17 of 19 workdays. 64% of merged PRs were AI-assisted. Your agent logged 31 entries you accepted." Tokens back it up underneath; they are not the headline.


## 12. Proof export

One JSON file with the hash chain, the days, the witnesses and its own verifier inside. It shows the log is consistent, ordered, matched item by item against its own events and honestly labelled, with links to check against the source. It does not prove that self-reported work happened, and it says so.

**A chain that holds** Every event links to the one before it. Change, drop or reorder one and the verifier names it.

**Links to check** Collected items point at the PR. Your manager clicks them on the company network; nothing leaves it.

**Labels that don't move** Observed, collected, agent and self are fixed at creation. Edits after sealing are counted, not hidden.

### 12.1 The file

october.cadence-proof.json (shape; arrays shortened)


```json
{
  "format": "cadence.proof/1",
  "generated_at": "2026-10-30T09:12:00+05:30",
  "generator": "Cadence 0.4.0",
  "subject": { "name": "Your Name", "role": "Software Engineer" },
  "range": { "from": "2026-10-01", "to": "2026-10-29", "tz": "Asia/Kolkata" },
  "how_to_verify": "…plain-language steps, shown in 12.2…",
  "verifier_py": "…the script in 12.3, verbatim…",
  "summary": {
    "sealed_workdays": { "value": 19, "of": 19, "before_ledger": 0, "definition": "Workdays wrapped up by 23:59 the next day, counted from the day the ledger began; …" },
    "plan_done":       { "value": 61, "of": 73, "definition": "Planned tasks on counted workdays marked done by the end of their day; …" },
    "merged_prs":      { "value": 14, "assigned": 11, "self_initiated": 3, "definition": "Merged PRs authored, from the GitHub collector; …" },
    "reviews":         { "value": 47, "definition": "Review entries, one per PR per day" },
    "ai_days":         { "value": 17, "of": 19, "definition": "Counted workdays with an AI coding session or usage record, from the first day any AI source recorded" },
    "private_events":  { "value": 3, "definition": "Events in range exported as hashes only: private notes and reasons, entries marked digest or exclude, and entries not accepted" }
  },
  "days": [{
    "date": "2026-10-28", "kind": "workday",
    "first_activity": "09:41", "last_activity": "19:02",
    "sealed_at": "2026-10-28T17:24:10+05:30", "seal_ev": "9c41…",
    "items": [
      { "ev": "1f07…", "last_ev": "1f07…", "kind": "pr.merged", "family": "delivery",
        "title": "ACME-482901 Batch settlement writes", "occurred_at": "2026-10-28T15:12:40+05:30",
        "origin": "collected", "source": "github", "ticket": { "key": "ACME-482901", "class": "assigned" },
        "links": ["https://git.example.com/acme/ledger-core/pull/405"],
        "flags": { "edited": false, "after_seal": false, "backfilled": false } },
      { "ev": "77d2…", "last_ev": "77d2…", "kind": "note", "origin": "self", "redacted": true,
        "flags": { "edited": false, "after_seal": false, "backfilled": false } }
    ]
  }],
  "chain": {
    "algo": "sha256", "c14n": "cadence-c14n/1",
    "events": [
      { "v": 1, "seq": 1, "id": "01JB…", "at": "2026-10-01T03:58:00.000Z", "actor": "app", "type": "ledger.genesis",
        "subject": "ledger", "data_digest": "…", "prev": "0000…0000", "hash": "…", "data": { … } }
    ]
  },
  "witnesses": [{ "date": "2026-10-28", "code": "3f9ac21e77b01d4e", "where": "stand-up message" }],
  "checks": ["export_digest", "sequence", "links", "payload_digests", "event_hashes", "references", "witnesses"],
  "export_digest": "sha256 of the canonical file without this field"
}
```


  * **Chain:** every event from genesis to the last one before export, in order. Outside the range events carry hashes only. Inside the range, payloads are allow-listed: day marks, presence spans, plan tasks, seals, witnesses and AI usage carry theirs; free text that is the owner's own (day notes and focus lines, reason notes, status notes, day labels, collector errors) and any event type the exporter does not know stay hash-only. Entries carry their payload only when accepted with export policy `include` (notes default to `digest`). An event belongs to the day its subject names, or to the current day of the entry, task or session it is about. A year is roughly 10,000 to 20,000 events; items appear both in `days` and in the chain, so expect 10 to 17 MB.
  * **Redaction is visible:** an item with policy `exclude` is left out of `days`, but its event stays in the chain as hash-only, and `summary.private_events` counts every hash-only event in range.
  * **Seals:** a day's seal is its first seal. Sealing again later never undoes a seal that counted. `edited` means an `entry.updated` after that seal; status changes are not edits.
  * **Days before the ledger:** workdays before the ledger began (a backfill) are not counted as unsealed; `sealed_workdays.before_ledger` reports them.
  * **Summary** carries a definition next to every number, so an agent reading it never has to guess what a metric means. The verifier recomputes `merged_prs` and `reviews` from the items; the other numbers are computed by Cadence.
  * **Witnesses** are the codes that ended your stand-up messages. Slack sets those message timestamps, not you, so each one shows that the chain up to that event existed by then.
  * **Canonical JSON** must match byte for byte across Swift and Python. Keys are ASCII and sorted. `"` and `\` are escaped, as are `\b \f \n \r \t`; other characters below U+0020 become lowercase `\u00xx`; everything else is raw UTF-8, `/` included. Integers stay within ±253, and there are no floats. Swift uses a small custom writer, not `JSONEncoder`, which escapes slashes. Shared vectors in `Tests/Vectors/c14n.json` run in both the Swift tests and the Python verifier inside `make check`.


### 12.2 How to verify, as it appears in the file

how_to_verify


```
This is a Cadence work log export. To check it:
1. Save verifier_py from this file as verify.py and run: python3 verify.py THIS_FILE
   (Python 3.8+, standard library only). PASS means the event chain is complete and in
   order, and every item, seal, witness and the merged PR and review counts match the
   events in the chain. The other summary numbers are computed by Cadence from the same
   days; their definitions are next to them.
2. Spot-check items with origin "collected": open a few links on the company network
   and compare title, date and state.
3. Match witness codes to the last line of the person's stand-up messages for those
   dates. A match shows the log up to that point existed at the message's time.
4. Treat origin "self" and "agent" items as self-reported: plausible, not proven.
   Items flagged after_seal were added after that day's wrap-up, and items flagged
   edited were changed after it.
5. This file is tamper-evident, not tamper-proof: its owner could have rebuilt the
   whole chain before the first witness. Witnesses narrow that window. export_digest
   catches accidental edits only, since anyone can recompute it.
6. Private notes and items marked private are in the chain as hashes only; the
   summary counts them as private_events. Hash-only events still show their type,
   subject and recorded time.
```


### 12.3 The verifier

verify.py: about 130 lines, standard library only, tested against 21 tampered files

tools/verify_proof.py, also embedded as verifier_py


```python
#!/usr/bin/env python3
"""Verify a cadence.proof/1 file. Python 3.8+, standard library only.
Usage: python3 verify.py proof.json"""
import hashlib, json, re, sys
from datetime import datetime

HEAD = ("v", "seq", "id", "at", "actor", "type", "subject", "data_digest", "prev")
CODE = re.compile(r"[0-9a-f]{16}\Z")

def canon(x):
    return json.dumps(x, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")

def sha(x):
    return hashlib.sha256(canon(x)).hexdigest()

def instant(text):
    t = datetime.fromisoformat(text.replace("Z", "+00:00").replace("z", "+00:00"))
    return int(t.timestamp())

def replay(created, updates):
    """The entry as its events leave it: entry.created data with each entry.updated change applied."""
    entry = dict(created)
    for u in updates:
        for field, change in sorted(u["changes"].items()):
            entry[field] = change[1]
    return entry

def check_item(it, date, by_hash, by_subject, fails):
    e = by_hash.get(it["ev"])
    if e is None:
        return fails.append("%s: references an event that is not in the chain" % date)
    if e["type"] != "entry.created" or not str(e["subject"]).startswith("entry:"):
        return fails.append("%s: item %s does not cite an entry.created event" % (date, it["ev"][:16]))
    history = by_subject[e["subject"]]
    if it.get("last_ev") != history[-1]["hash"]:
        fails.append("%s: item %s last_ev is not the entry's last event" % (date, it["ev"][:16]))
    if it.get("redacted"):
        if "data" in e:
            fails.append("%s: item %s is marked redacted but its payload is in the chain" % (date, it["ev"][:16]))
        return
    updates = [x for x in history if x["type"] == "entry.updated"]
    if "data" not in e or any("data" not in x for x in updates):
        return fails.append("%s: item %s has no payload in the chain to check it against" % (date, it["ev"][:16]))
    entry = replay(e["data"], [x["data"] for x in updates])
    shown = {"kind": entry["kind"], "family": entry["family"], "title": entry["title"], "origin": entry["origin"],
             "ticket": entry["ticket"], "links": [l["url"] for l in entry["links"]], "day": entry["day"]}
    for field, value in sorted(shown.items()):
        got = date if field == "day" else it.get(field)
        if got != value:
            fails.append("%s: item %s %s does not match its events" % (date, it["ev"][:16], field))

def verify(p):
    fails, warns = [], []
    if not isinstance(p, dict) or p.get("format") != "cadence.proof/1":
        return ["unknown format " + repr(p.get("format") if isinstance(p, dict) else p)], warns
    body = {k: v for k, v in p.items() if k != "export_digest"}
    if sha(body) != p.get("export_digest"):
        fails.append("export_digest does not match the file: it was edited after export")
    prev, last_at, by_hash, by_subject, by_code = "0" * 64, "", {}, {}, {}
    for i, e in enumerate(p["chain"]["events"], start=1):
        tag = "event %s" % e.get("seq")
        if e["seq"] != i:
            fails.append(tag + ": sequence gap or reorder")
        if e["prev"] != prev:
            fails.append(tag + ": does not link to the event before it")
        if "data" in e and sha(e["data"]) != e["data_digest"]:
            fails.append(tag + ": payload changed after it was recorded")
        if sha({k: e[k] for k in HEAD}) != e["hash"]:
            fails.append(tag + ": event hash mismatch")
        if e["at"] < last_at:
            warns.append(tag + ": recorded time goes backwards (clock change?)")
        last_at, prev = max(last_at, e["at"]), e["hash"]
        by_hash[e["hash"]] = e
        by_subject.setdefault(e["subject"], []).append(e)
        by_code.setdefault(e["hash"][:16], []).append(e)
    lo, hi = p["range"]["from"], p["range"]["to"]
    counts = {"merged_prs": 0, "reviews": 0}
    for d in p["days"]:
        date = d["date"]
        if not lo <= date <= hi:
            fails.append("%s: day is outside the range" % date)
        if d.get("seal_ev") or d.get("sealed_at"):
            s = by_hash.get(d.get("seal_ev"))
            if s is None:
                fails.append("%s: references an event that is not in the chain" % date)
            elif s["type"] != "day.sealed" or s["subject"] != "day:" + date:
                fails.append("%s: seal_ev is not this day's seal" % date)
            elif not d.get("sealed_at") or instant(d["sealed_at"]) != instant(s["at"]):
                fails.append("%s: sealed_at does not match the seal event" % date)
        for it in d["items"]:
            check_item(it, date, by_hash, by_subject, fails)
            if it["kind"] == "pr.merged" and it["origin"] == "collected":
                counts["merged_prs"] += 1
            if it["kind"] == "review.given":
                counts["reviews"] += 1
    for key, n in sorted(counts.items()):
        value = p.get("summary", {}).get(key, {}).get("value", n)
        if value != n and not (value is None and n == 0):
            fails.append("summary %s says %s, the items show %d" % (key, value, n))
    for w in p.get("witnesses", []):
        hit = by_code.get(w["code"], []) if CODE.match(str(w["code"])) else []
        if not any(e["type"] == "witness.checkpoint" and e["subject"] == "day:" + w["date"] for e in hit):
            fails.append("witness %s (%s) matches no checkpoint for that day" % (w["code"], w["date"]))
    return fails, warns

def main(path):
    try:
        with open(path, encoding="utf-8") as f:
            p = json.load(f)
        fails, warns = verify(p)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError) as error:
        print("FAIL    the file is not a readable proof: %s %s" % (type(error).__name__, error))
        print("RESULT  FAIL")
        return 1
    if fails and fails[0].startswith("unknown format"):
        print("FAIL    " + fails[0])
        print("RESULT  FAIL")
        return 1
    ev = p["chain"]["events"]
    items = [it for d in p["days"] for it in d["items"]]
    by_origin = {}
    for it in items:
        by_origin[it["origin"]] = by_origin.get(it["origin"], 0) + 1
    print("cadence.proof/1  %s .. %s  (%s)" % (p["range"]["from"], p["range"]["to"], p["range"]["tz"]))
    print("chain   %d events, head %s" % (len(ev), ev[-1]["hash"][:16] if ev else "-"))
    print("items   %d: %s" % (len(items), ", ".join("%s %d" % kv for kv in sorted(by_origin.items()))))
    print("links   %d items carry a source link to check" % sum(1 for it in items if it.get("links")))
    print("witness %d codes, all found in chain" % len(p.get("witnesses", [])) if not any("witness" in f for f in fails) else "witness MISMATCH")
    for w in warns:
        print("warn    " + w)
    for f in fails:
        print("FAIL    " + f)
    print("RESULT  " + ("PASS: the chain is complete and in order, and every item, seal and witness matches it" if not fails else "FAIL"))
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
```


```sh
python3 verify.py october.cadence-proof.json
cadence.proof/1  2026-10-01 .. 2026-10-29  (Asia/Kolkata)
chain   1912 events, head 4be0c19a2271f3d8
items   214: agent 31, collected 118, observed 22, self 43
links   118 items carry a source link to check
witness 19 codes, all found in chain
warn    event 1204: recorded time goes backwards (clock change?)
RESULT  PASS: the chain is complete and in order, and every item, seal and witness matches it
```


the same file after editing one title


```
cadence.proof/1  2026-10-01 .. 2026-10-29  (Asia/Kolkata)
chain   1912 events, head 4be0c19a2271f3d8
items   214: agent 31, collected 118, observed 22, self 43
links   118 items carry a source link to check
witness 19 codes, all found in chain
FAIL    export_digest does not match the file: it was edited after export
FAIL    event 1388: payload changed after it was recorded
FAIL    2026-10-28: item 1f07a9c2e4b1d530 title does not match its events
RESULT  FAIL
```


### 12.4 What it proves, and what it does not

Proves| Does not prove
---|---
Every item, seal and witness matches the chain, so no title, origin, link or seal was edited after recording without rebuilding the chain| That self-reported work happened
No event was changed, dropped or reordered without rebuilding everything after it| That the owner did not rebuild the whole chain before the first witness
The log up to each witness existed by that stand-up message| Who wrote it. There are no keys, by design; identity comes from your manager receiving it from you
Which items came from the Mac, a collector, an agent or you, and which changed after sealing| That a collected item is still accurate. That is what the links are for
The merged PR and review counts match the items| The other summary numbers, which Cadence computes from the same days
Private items are present, counted and unchanged| Their text. A short private title with a guessable shape could be found by trying candidates against its digest; keep anything sensitive out of titles
Nothing about events outside the range beyond their hashes| That their type, subject and recorded time are hidden: those stay visible so the chain can be checked

Signing keys were left out on purpose. A key on the same laptop proves only that the laptop signed, adds key management to an open-source project, and would read as more certainty than the design has. Witnesses held by a third party do that job better.


## 13. Privacy and threats

Cadence keeps counts, timestamps and titles you can see and edit. It never reads content, keystrokes, app names or prompts, and the app itself is sandboxed with no network entitlement, so the OS stops it from reaching out.

#### Never collected

  * Keystrokes, key counts, mouse movement. Presence uses idle seconds only
  * App names, window titles, URLs, browser history, screenshots
  * Message or email content from any tool. Slack and Outlook are out of v1; if they arrive later, counts only
  * Prompts, AI responses, code, diffs, PR bodies (read for a marker, then dropped)
  * Other people's names or logins


#### Permissions it asks for

Notifications| Yes, on first wrap-up reminder
---|---
Login item and background agent| Yes, listed in System Settings, General, Login Items
Accessibility, Input Monitoring| No. Hotkeys and idle time need neither (verify)
Full Disk Access| No
Calendars, Contacts| No
Network| None for the app; the CLI has no network code
Admin password| Never

### 13.1 Threats

Threat| Mitigation| What remains
---|---|---
Work data leaves the Mac| App sandbox with no network entitlement. The `cadence` binary links no networking code, and `make check` inspects the binary's imported symbols for URLSession, Network.framework and socket calls. Collectors are commands you approved. Exports happen only when you ask| A collector you approve can send anything you let it
Employer names or hosts land in the public repo| Examples use ACME and example.com. `tools/guard.sh` reads a forbidden-terms list from `~/.config/cadence/forbidden.txt`, which is never committed, and fails with file and line without printing the term. It runs as a pre-commit hook, inside `make check`, and over the full history before publishing| Terms you forget to list
Your work log ends up in git| The store lives outside the repo. `.gitignore` covers `*.db`, `*.cadence-proof.json`, `maps/` and local config. The guard also rejects files whose content starts with `cadence.proof/1`, `envelope/1` or the SQLite header| Data pasted into an issue by hand
Collector command abuse| argv only, absolute path, fixed environment, approval by digest, and a config that must be yours with mode 0600| Malware already running as you can edit anything you can
Prompt injection through PR titles or entries returned to agents| MCP results return entries as data fields, and tool descriptions state the content is user data. No MCP tool can delete, seal, accept or change presence. Agent writes are labelled agent and rate-limited to 60 a minute| An agent can still log misleading entries, labelled as agent
Screen sharing and lock screen| Notifications show counts, not titles, unless you turn titles on. Discreet mode (⌃⌥D) blurs titles in the Pocket and window. Detecting a screen share automatically is later work (verify)| A shared window while discreet mode is off
Lost or stolen laptop| FileVault for data at rest; files are 0600 in a 0700 folder. `cadence doctor` reports whether FileVault is on| An unlocked, unattended Mac
A rewritten history| Hash chain, witnesses, edit counts after sealing, and the limits stated in the proof itself| A full rebuild before the first witness
Supply chain| Two Apple packages only, pinned in `Package.resolved`. When CI is added, its actions are pinned to commit SHAs. No binaries downloaded at build time; sounds are generated by a script in the repo| Toolchain trust
Telemetry| None. No analytics, no update checks, no crash upload. Crashes stay in the local DiagnosticReports folder| None
Employer policy and IP| Nothing from the employer is in the code, examples or tests. The proof file goes only to your manager, on internal channels. Whether code written on the work Mac is yours to publish is decision 2 in §17| A policy answer only your employer can give


## 14. Repo, build, checks

One Swift package. The core, ingest, MCP and CLI build and test on Linux; the SwiftUI app builds on your Mac with `make install`. No GitHub CI for now: `make check` is the gate. Nothing needs sudo, Docker or an Apple account.

### 14.1 Layout

Cadence/


```
Package.swift · Package.resolved · Makefile
README.md · LICENSE · NOTICE · SECURITY.md · CONTRIBUTING.md · CODE_OF_CONDUCT.md · CLAUDE.md
docs/
  SPEC.md                 this page in Markdown; the source of truth
  PLAN.md                 every task with its tier and done-when, ticked as work lands
  SPIKES.md               S1 to S9 and every verify tag, with evidence once checked
  PROOF-FORMAT.md · COLLECTORS.md · MCP.md · PRIVACY.md
  decisions/              one short ADR per decision in §17
Sources/
  CadenceCore/            Model · Store · Ledger · C14N · Projections · Parse · Presence · Insights · Findings · Proof · Time
  CadenceIngest/          Envelope · Map · Runner · GitHub · Transcripts · Import
  CadenceMCP/             JSONRPC · Tools · Resources · Prompts
  cadence/                CLI entry: log, plan, day, inbox, query, summary, standup, collect, ingest,
                          import, presence, export, verify, hook, mcp, doctor, rebuild, config
  CSQLite/                module map for libsqlite3 (Linux only)
  CadenceUI/              Tokens · Dot · Ring · Pocket · Capture · Plan · Wrap · Window · Charts (macOS only)
  CadenceApp/             AppDelegate · StatusItem · Panels · Notifications · Hotkeys · LoginItem · PresenceAdapter
Tests/
  CadenceCoreTests/ · CadenceIngestTests/ · CadenceMCPTests/ · CadenceUITests/ (snapshots)
  Vectors/                c14n.json · chains/ · envelopes/ · maps/ · proofs/valid.json · proofs/tampered.json
App/
  Info.plist · Cadence.entitlements · Agent.plist.in
  Resources/              AppIcon.icns · Sounds/*.caf · Localizable.xcstrings
integrations/claude-code/ hooks.json · skills/cadence/SKILL.md · README.md
examples/                 config.example.json · collectors/oncall.sh · collectors/oncall.py · maps/sample-*.json
tools/                    verify_proof.py · guard.sh · check_entitlements.sh · make_sounds.swift · seed_demo.swift · spike/
scripts/                  bundle.sh · install.sh · uninstall.sh
.githooks/ (pre-commit, pre-push) · .github/ISSUE_TEMPLATE/ · .gitignore
```


### 14.2 Package.swift

sketch; check versions against the installed toolchain


```swift
// swift-tools-version: 6.2
import PackageDescription

let core: [Target] = [
  .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", pkgConfig: "sqlite3",
                 providers: [.apt(["libsqlite3-dev"])]),
  .target(name: "CadenceCore", dependencies: [
    .target(name: "CSQLite", condition: .when(platforms: [.linux])),
    .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
  ]),
  .target(name: "CadenceIngest", dependencies: ["CadenceCore"]),
  .target(name: "CadenceMCP", dependencies: ["CadenceCore", "CadenceIngest"]),
  .executableTarget(name: "cadence", dependencies: [
    "CadenceCore", "CadenceIngest", "CadenceMCP",
    .product(name: "ArgumentParser", package: "swift-argument-parser"),
  ]),
  .testTarget(name: "CadenceCoreTests", dependencies: ["CadenceCore"]),   // reads Tests/Vectors via #filePath
  .testTarget(name: "CadenceIngestTests", dependencies: ["CadenceIngest"]),
  .testTarget(name: "CadenceMCPTests", dependencies: ["CadenceMCP"]),
]

let package = Package(
  name: "Cadence",
  platforms: [.macOS(.v26)],                       // (verify): case name in the 6.2 PackageDescription
  products: [.executable(name: "cadence", targets: ["cadence"])],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
  ],
  targets: core
)

#if os(macOS)   // the manifest runs on the host, so Linux never sees the SwiftUI targets
package.targets += [
  .target(name: "CadenceUI", dependencies: ["CadenceCore"]),
  .executableTarget(name: "CadenceApp", dependencies: ["CadenceUI", "CadenceCore", "CadenceIngest"]),
  .testTarget(name: "CadenceUITests", dependencies: ["CadenceUI"]),
]
package.products += [.executable(name: "CadenceApp", targets: ["CadenceApp"])]
#endif
```


  * Core code imports `SQLite3` and `CryptoKit` under `#if canImport(Darwin)`, and `CSQLite` and `Crypto` otherwise. Platform calls sit behind small protocols so Core stays testable on Linux.
  * App resources (sounds, icon, strings) are copied into the bundle by `bundle.sh` and loaded through `Bundle.main`, avoiding SwiftPM resource bundles inside a hand-built `.app`.
  * Avoid the `#Preview` macro in package targets until S8 shows Command Line Tools ship its plugin; use `PreviewProvider`, which needs no macro.


### 14.3 The bundle

~/Applications/Cadence.app, built by scripts/bundle.sh


```
Contents/
  Info.plist                         LSUIElement true, bundle id in.ashwingopalsamy.cadence (BUNDLE_PREFIX overrides)
  MacOS/Cadence                      the app: sandboxed, no network entitlement
  Helpers/cadence                    the CLI and agent: signed separately with no entitlements
  Library/LaunchAgents/
    in.ashwingopalsamy.cadence.agent.plist   BundleProgram Contents/Helpers/cadence, arguments collect run --due,
                                             StartInterval 900, RunAtLoad, WatchPaths …/Cadence/jobs (absolute, filled at build)
  Resources/                         AppIcon.icns · Sounds/ · Localizable strings
~/.local/bin/cadence  →  ~/Applications/Cadence.app/Contents/Helpers/cadence   (symlink)
```


Signing is ad-hoc, inside out: `codesign --force --sign - --options runtime` on the helper, then on the app with `App/Cadence.entitlements`. The bundle id uses your own domain; anyone else building it sets `BUNDLE_PREFIX`.

### 14.4 Make targets

Target| Does
---|---
`make build` · `make test`| `swift build` and `swift test`
`make check`| The gate before every push; see 14.6
`make app`| Release build, then `build/Cadence.app` via `bundle.sh`, signed ad-hoc
`make install` · `make uninstall`| Copies the app to `~/Applications`, links `~/.local/bin/cadence`, opens the app once. Uninstall unregisters the login item and agent and leaves your data
`make run`| Runs the app from `build/` against `CADENCE_HOME=build/dev-home`, never your real store
`make demo`| Seeds `build/demo-home` with deterministic ACME data for screenshots and snapshots
`make snapshots`| Renders key views to PNG with `ImageRenderer` in light and dark at 1x and 2x
`make spike`| Platform checks S1 to S9; prints PASS, FAIL or MANUAL with instructions
`make guard`| Forbidden terms, data-file signatures and secrets in staged files; installs as a pre-commit hook
`make sounds`| Regenerates `Sounds/*.caf` from `tools/make_sounds.swift`

### 14.5 Install on your Mac

no admin at any step


```sh
xcode-select -p || xcode-select --install     # Command Line Tools; Swift 6.2 or later
git clone https://github.com/OWNER/Cadence.git && cd Cadence
make spike && make test
make install
cadence doctor                                # store, permissions, FileVault, agent, hooks, MCP
claude mcp add --transport stdio --scope user cadence -- "$HOME/.local/bin/cadence" mcp
# then ask Claude Code to merge integrations/claude-code/hooks.json into ~/.claude/settings.json
```


### 14.6 The local gate

GitHub CI is off for now. `make check` is the one gate: it runs before every push, in the cloud project for core work and on your Mac for everything else. When CI comes back, its only job is to run the same target.

Step| Linux| macOS
---|---|---
`swift build` · `swift test`| Core, Ingest, MCP, CLI| Everything, the app included
Proof vectors| `verify_proof.py` passes `valid.json` and fails `tampered.json`; `cadence verify` agrees on both
`tools/guard.sh --all`| Forbidden terms from `~/.config/cadence/forbidden.txt`, data-file signatures, secrets
Copy lint| No en or em dashes in UI strings
`make app` and `check_entitlements.sh`| skipped| Sandbox on, no network keys, no socket or URLSession symbols in either binary
`make snapshots`| skipped| Key views in light and dark, 1x and 2x, compared with the last accepted set

Git hooks installed by `make guard`: pre-commit runs the guard on staged files and the fast core tests; pre-push runs `make check`.


## 15. Roadmap

Ledger first, then agents, then the menu bar. Claude Code can log your days through MCP from phase 2, before any UI exists, and every phase ends with something you use that day.

Phase 0 · v0.0 · 1 day

#### Bootstrap

  1. Repo, package, Makefile; `make check` green here and on your Mac
  2. `make spike` on your Mac; results into `docs/SPIKES.md`
  3. Guard and git hooks


Exit **`make check` green, S1 to S9 answered**

Phase 1 · v0.1 · 3 days

#### Ledger, CLI, proof

  1. Store, ledger, canonical JSON with shared vectors, projections, rebuild
  2. Capture parser, ticket classifier, `log`, `plan`, `day`, `today`, `query`
  3. `export proof`, `verify`, `tools/verify_proof.py`


Exit **rebuild is byte-identical; tampered vectors fail**

Phase 2 · v0.2 · 4 days

#### Agents and collectors

  1. MCP server (both revisions), hooks, spool, skill
  2. Runner, GitHub, transcripts, map/1, import, presence backfill
  3. Backfill from 1 October


Exit **October visible in`cadence summary`; import matches your app's totals**

Phase 3 · v0.3 · 1 to 2 weeks

#### The menu bar

  1. Status item and dot states, Pocket, capture bar, plan sheet
  2. Wrap-up and seal, stand-up copy with witness, notifications
  3. Presence engine live, login item, agent, sounds, hotkeys


Exit **a full week used daily; reminder to sealed in under 60 s**

Phase 4 · v0.4 · 1 to 2 weeks

#### Insights

  1. Window, heatmap, ring history, bead chain
  2. Plan vs done, assigned vs self-initiated, day shape, AI, review cadence
  3. Findings engine, weekly and cycle recaps


Exit **recaps read true for the last 4 weeks; every chart has a table and works with VoiceOver**

Phase 5 · v1.0 · 1 week

#### Open-source ready

  1. Docs, demo data, screenshots from demo only
  2. License, SECURITY.md, CONTRIBUTING, name decided
  3. Guard over the full history; publish from a fresh history if in doubt


Exit **fresh clone to running app in under 10 minutes on a clean account**

### 15.1 How each phase gets built

Every phase is split into tasks in `docs/PLAN.md`: 83 tasks, each with a tier and a "done when". The **planner** writes briefs and interfaces, writes the 14 critical modules itself (canonical JSON, hashing, schema, ledger append, projections, witness, proof export, MCP protocol, envelope ingest, collector runner, decimal mapping, app signing, presence, findings) and reviews every diff. A **builder** implements one brief at a time, tests first. A **mechanic** does fully specified mechanical work. An **auditor** with fresh context reviews every critical diff and each finished phase against this spec. A task is ticked only after the planner has run `make check` itself.

**100% means** every task ticked, every verify tag answered in `SPIKES.md`, and a final audit with no gaps. Phases 0 to 2 build and test on Linux in the cloud project; phases 3 to 5 need your Mac.

Durations assume Claude Code does most of the typing and you review. Later, in no order: GitHub CI that runs `make check`, Foundation Models smart capture and recap prose, Slack and Outlook counts once a mechanism exists, review turnaround, Shortcuts and App Intents, a widget, screen-share detection for discreet mode, proofs that start from a witnessed checkpoint instead of genesis.


## 16. Open source

Private until phase 5. Publishing needs three things beyond good code: a clean history, an employer policy answer, and a name that is not already taken.

Item| Recommendation
---|---
License| Apache-2.0: permissive, with a patent grant, and the same family as Swift itself
README| What it is, the three promises (local only, no admin, honest proof), install, a 20-second screen recording made from demo data
SECURITY.md| Report privately through GitHub security advisories. Scope: data leaving the Mac, chain integrity, collector execution
CONTRIBUTING.md| Build, test, guard, the hard rules from CLAUDE.md, "good first collector" issues
Demo data| Deterministic ACME seed behind `CADENCE_HOME`; screenshots and snapshot tests use only this
History| `tools/guard.sh --history` scans every commit. If anything ever slipped in, publish a squashed fresh history rather than rewriting the old one
Name| "Cadence" is taken by Cadence Design Systems and by Uber's Cadence workflow engine. Fine while private; decide before publishing (§17)
Distribution| Source only. Notarized binaries need a paid Developer ID; a Homebrew formula that builds from source can come later
Localization| English in v1, every string in a String Catalog from day one


## 17. Decisions

Two things to do today, then six decisions. Each has a recommendation, so the build can start on it while you think.

#### Do today

  * **Keep your October transcripts.** Add `"cleanupPeriodDays": 400` to `~/.claude/settings.json`. At the default of 30 days, 1 October's sessions are deleted around 31 October.
  * **Keep a plain daily note until phase 2.** Three lines at stand-up, in Claude Code or by dictation. They go in later through `log_entries` with a dry run, and streaks begin from real days.


1

**End your Slack stand-up with the witness code?**

A 16-character code from the ledger head, added as the last line of the copied stand-up. Slack's timestamp then anchors the proof, which keys on your own laptop cannot do. It costs one short line per day that teammates may ask about.

Recommend yes, with a short "cadence" prefix

2

**Check your employer's policy before publishing code built on the work Mac**

Many employment agreements claim code written on company hardware or time. The repo holds nothing from your employer, but authorship of the code itself is a policy question only they can answer.

Recommend asking before phase 5; build privately meanwhile

3

**Pick the public name**

"Cadence" collides with an EDA company and a well-known workflow engine, which hurts search and invites a trademark letter. The code uses the name in only a few places, so changing it later is cheap.

Recommend keeping Cadence privately and choosing before publishing

4

**Make your usage endpoint the source of truth for AI numbers**

Endpoint first, transcripts second, the October import third, never summed. Claude Code on your Mac writes both map files from real samples, so their formats never leave the machine.

Recommend endpoint first

5

**Sign ad-hoc or with a free personal team?**

Ad-hoc needs no Apple account, but macOS may ask again to allow the login item after each rebuild. A free personal team gives a stable identity at the cost of signing into Xcode.

Recommend ad-hoc; switch only if re-approval gets annoying

6

**Confirm what "consistency" means with your manager**

The proof summary leads with sealed workdays, plan done and merged and reviewed PRs, plus leadership signals. If your manager weighs something else, such as discussions raised or on-call, the summary order changes; the data model does not.

Recommend a two-minute check at your next 1:1


## 18. Hand-off

This page becomes `docs/SPEC.md` in the first push, with the task list `docs/PLAN.md` and `CLAUDE.md` beside it. Work goes task by task through the tiers, tests first in Core, and every verify tag closes with evidence in `docs/SPIKES.md`.

#### Read in this order

  1. §01 Brief and §02 Principles
  2. §07 Data model and §08 Architecture
  3. §09 Agents and §10 Collectors
  4. §12 Proof and §13 Privacy
  5. §03 to §06 before any UI work
  6. §14 and §15 for build order


#### Conventions

  * Swift 6 language mode, strict concurrency, no force unwraps outside tests
  * Clock, file roots and process runner are injected; Core never calls `Date()`
  * ULIDs for ids; times in UTC RFC 3339 with milliseconds; days as local date plus zone
  * Typed errors mapped to CLI exit codes and MCP error results
  * `os.Logger` on macOS, stderr on Linux, never entry titles at info level
  * One `docs/PLAN.md` task per commit, task ID in the subject, `make check` green


### 18.1 CLAUDE.md

CLAUDE.md (first draft)


```
# Cadence

Local-only macOS work log. docs/SPEC.md is the source of truth; read the relevant section before changing behaviour.

## Hard rules
- No network code in the app or the cadence binary. Network happens only in collector commands the user approved.
- No admin rights, no Docker, no dependencies beyond swift-argument-parser and swift-crypto (Linux only).
- Never commit work-log data, real config, map files or proof files. Examples use ACME and example.com only.
- No employer names, hosts, ticket prefixes or data anywhere in the repo. Run `make guard` before every commit.
- The ledger is append-only: no UPDATE or DELETE on events. Projections must rebuild byte for byte.
- Any change to canonical JSON or hashing needs new vectors in Tests/Vectors and a passing tools/verify_proof.py.
- Origin (observed, collected, agent, self) is set once and never changes.

## Commands
- make test        core, ingest and MCP tests (also run on Linux)
- make check       the gate before every push: build, tests, proof vectors, guard; on macOS also app, entitlements, snapshots
- make app         build/Cadence.app, ad-hoc signed
- make run         the app against build/dev-home, never the real store
- make install     ~/Applications/Cadence.app and ~/.local/bin/cadence
- make spike       platform checks S1 to S9

## Style
- UI copy: sentence case, finding first, no en or em dashes, unknown is not zero.
- Glass only on floating chrome (status panel, capture bar, sheets). Content stays matte.
- Every chart ships with a table twin and a VoiceOver summary.
- Tests first for Core. One docs/PLAN.md task per commit, with its ID in the subject.

## How work happens
- docs/PLAN.md is the work list. Every task has a tier: planner, builder, mechanic or auditor. ★ marks critical modules.
- The planner writes a brief for each builder or mechanic task, delegates it, reviews the diff against the spec and runs make check itself.
- If the cadence-builder, cadence-mechanic and cadence-auditor agents are installed, delegate by tier. If not, do the task yourself to the same standard.
- Never tick a task on a subagent's word alone. Every ★ diff gets a cold review from the auditor.
- A phase ends with an audit of its spec sections. Its gaps become tasks.
```


### 18.2 First push

  1. You create the private repo `Cadence` on GitHub and say so; it gets attached here.
  2. This project pushes phase 0 from `docs/PLAN.md`: package skeleton, Makefile and `make check`, guard and git hooks, `docs/SPEC.md`, `docs/PLAN.md`, `CLAUDE.md`, `SPIKES.md`, synthetic vectors and the verifier.
  3. On your Mac: clone, `make spike`, paste results into `SPIKES.md`. Spikes decide the two fallbacks (sandbox and login item) before phase 1 starts.
  4. Phases 1 and 2 run in the cloud project, where the core builds and tests on Linux. Phases 3 to 5 need macOS and run on your Mac with the same tiers, either from your local Claude Code or from a Remote Control session started here.


Cadence Blueprint · plan and design v1.1 · 30 October 2026 All examples are synthetic (ACME, example.com). Verify tags mark platform claims to prove on a Mac.
