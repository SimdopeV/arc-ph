# Arc PH all-day scoreboard

Group scoreboard and countdown timer for "Prompt to Deploy with Arc Studio" (Saturday 31 October 2026, 11:30 AM to 4:30 PM WAT, Pyale WorkHub).

- TV (read only): https://simdopev.github.io/arc-ph/scoreboard/
- Keeper (phone, PIN): https://simdopev.github.io/arc-ph/scoreboard/keeper.html

Plain HTML, CSS and JavaScript, no build step. It uses the same Supabase project and the same publishable key as the quiz (it loads `../quiz/config.js`), and the same security pattern: the browser only reads one public row, and every change is a database function that checks the keeper PIN.

## Files

| File | What it is |
| --- | --- |
| `index.html` | TV page |
| `keeper.html` | Keeper page |
| `scoreboard.js` | Both pages. The point values are at the top. |
| `scoreboard.css` | Both pages |
| `scoreboard.sql` | Tables, security and functions. Additive only: it never touches the quiz. |

## 1. Run the SQL

1. In Supabase open **SQL Editor**, start a **new** query, paste all of `scoreboard.sql` and click **Run**. The last result is one row: `ARCPH`, six groups at 0, segment `Setup`, `pin_set` false.
2. Start another new query and set the keeper PIN (at least 6 characters, not the quiz host PIN):

   ```sql
   select public.sb_set_keeper_pin('ARCPH', 'your-keeper-pin');
   ```

   Do not save that query or put the PIN in any file. The database only keeps a bcrypt hash. Ten wrong PINs in a row lock the keeper for 60 seconds. Run the same line again to change the PIN.

3. Check the quiz still works: follow "7. Rehearsal" in `quiz/README.md`, or at least open the quiz host page and unlock it.

`scoreboard.sql` is safe to run again at any time. It keeps the awards, totals, timer, segment and PIN.

**If you ever run `quiz/supabase.sql` again, run `scoreboard.sql` again afterwards.** The quiz file revokes execute on every function in the database, which switches the scoreboard functions off (the TV still shows the scores, but the keeper page says "permission denied" on every tap). Running `scoreboard.sql` again switches them back on. It does not wipe anything.

## 2. Change the point values

Open `scoreboard.js`. The `GAMES` list at the top is the only place to edit:

```js
{ key: 'prompt', name: 'Prompt Battle', buttons: [
  { text: '1st place', points: 300, label: 'Prompt Battle 1st' },
  ...
```

- `points` is what one tap adds. `label` is what the TV shows under "Latest".
- Quiz: `entry: 'points'` means the keeper types each group's quiz points. When the quiz rule is decided, either keep typing them in or change it to buttons like the other games.
- Deploy: `perItem: 50` is the points per note.
- Do not change a `key` once points are on the board. Keys go into the database with each award.

Commit and push to `main`. GitHub Pages serves the change a minute later. Keepers should reload their phones.

The segment list is in two places (`SEGMENTS` in `scoreboard.js` and `_sb_segments()` in `scoreboard.sql`). Change both, then run `scoreboard.sql` again.

## 3. The TV

- Open the TV link on the laptop plugged into the venue TV. Chrome works best.
- Press **F** for full screen (or double click). That key press or click also turns the sound on: the timer beeps once at zero. Until then the footer says "Press F for full screen and sound".
- The cursor hides after 3 seconds without mouse movement.
- The chip in the bottom right says **Live**, **Connecting** or **Offline**. Offline, the TV keeps the last totals and the timer keeps counting. It catches up by itself when the connection is back (realtime, plus a check every 3 seconds while offline and every 15 seconds while live).
- Reloading the TV is safe at any time. It shows the last totals at once and then loads the current state.

## 4. The keeper

- Open the keeper link on the phone and enter the keeper PIN. It is kept only for that browser tab, so closing the tab locks it. **Lock** in the top bar locks it at once.
- Two phones can keep score at the same time. Each sees the other's awards.
- **Points:** pick the game at the top, then tap the button (or type the number and tap **Add**) next to the group. A toast shows "+300 Rachel" with **Undo**, which undoes that exact award, even if the other phone added one since.
- **Other** has a plus or minus switch, the points and a short reason.
- **Last 10 awards** shows undone awards crossed out. **Undo latest** undoes the newest award that is not undone yet.
- **Timer:** tap a preset (2, 5, 10, 15, 40 min) or type custom minutes and tap **Set**. The TV shows the time ready. Tap **Start**. Then Pause, Resume, Reset (back to the set time) or +1 min. If a timer is running, a preset needs a second tap so it cannot be replaced by accident. "Label on the TV" follows the current segment unless you type your own.
- **Now showing:** tap the segment the room is in. The TV shows it top right.
- **Reset all scores:** tap twice within 3 seconds. It deletes every award and sets all totals to 0. The timer and segment stay.

## 5. Day-of checklist

The day before:

- [ ] `scoreboard.sql` run, keeper PIN set, `pin_set` is true.
- [ ] Rehearse on the real URLs with the TV laptop and both keeper phones: award, undo, timer start, pause, resume, +1 min, reset, segment change, TV reload, wifi off and on.
- [ ] **Reset all scores** (two taps) after the rehearsal. Set the segment back to Setup.

On the day:

- [ ] TV laptop: plugged in to power, sleep and screen saver off, Chrome open on the TV link, HDMI to the TV, volume up.
- [ ] Press **F** on the TV. The footer sound hint disappears. The chip says Live.
- [ ] Both keeper phones unlocked, charged, screen timeout set long.
- [ ] Totals all 0 and "No points yet" on the TV before Welcome.
- [ ] Set the segment as each part of the day starts.
- [ ] Before "Scores and prizes", check the keeper's Last 10 awards for mistakes and undo them.

If the internet drops: keep awarding on the phones once they are back online (an award made with no connection is not saved, and the toast says so). The TV catches up when it reconnects.

## Data model

- `scoreboard_state`: one public row (code `ARCPH`) with `totals` (group to points), `last_award`, `segment`, the timer (`timer_label`, `timer_duration_s`, `timer_ends_at` while running or `timer_remaining_s` while stopped, `timer_running`), `rev` (goes up on every write) and `updated_at`. anon can select it. It is in the `supabase_realtime` publication.
- `scoreboard_awards`: one row per award, with `undone`. No browser access.
- `scoreboard_secrets`: the keeper PIN hash and the lockout counter. No browser access.

Functions (all return jsonb with `error` and a friendly `message` on a bad PIN or bad input): `sb_keeper_state`, `sb_award`, `sb_undo` (latest, or one award by id), `sb_timer` (set, start, pause, resume, reset, add_minute), `sb_segment`, `sb_reset`. `sb_server_time` is public and lets the TV correct its clock. `sb_set_keeper_pin` runs only in the SQL editor.

Every write recomputes `totals` from the awards that are not undone and updates the state row, so the TV only listens to that one row.
