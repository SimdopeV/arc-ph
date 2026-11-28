# Arc PH Live Quiz

Kahoot-style quiz for the Port Harcourt Community Meetup (Saturday 31 October 2026, 1:45 PM WAT).

- Players: https://simdopev.github.io/arc-ph/quiz/
- Host (projector): https://simdopev.github.io/arc-ph/quiz/host.html

Plain HTML, CSS and JavaScript. No build step. Supabase does the database and realtime.

## Files

| File | What it is |
| --- | --- |
| `index.html`, `player.js` | Player page (phones) |
| `host.html`, `host.js`, `host.css` | Host page (projector) |
| `quiz.css`, `common.js` | Shared styles and helpers |
| `config.js` | Supabase URL and anon key |
| `sw.js` | Lets the host page reload offline for card mode |
| `supabase.sql` | Tables, security and functions (no questions) |
| `questions.local.sql` | The 12 questions and answers. Git-ignored, so it never reaches GitHub. Keep a private copy. |
| `bank.local.sql` | The question bank you pick from (the 12 meetup questions plus the Arc 101 set). Git-ignored too. Keep a private copy. |
| `migrations/` | One-off SQL for a database that was set up before a feature existed |
| `loadtest/` | 100-player load test (Node) |

## 1. Create the Supabase project

1. Sign in at https://supabase.com and create a new project on the Free plan. Pick the region closest to Nigeria (for example West EU, London).
2. Wait for it to finish setting up.

## 2. Run the SQL

1. Open **SQL Editor**, start a new query, paste all of `supabase.sql` and click **Run**. It creates the tables, row level security, the functions and the game `ARCPH`, and adds the `games` table to realtime.
2. Start another new query, paste all of `questions.local.sql` and click **Run**. It loads the 12 questions and answers and should print `questions_loaded: 12`.

`questions.local.sql` is listed in `quiz/.gitignore`, so git never picks it up and GitHub Pages never serves it. It only exists on your computer, so keep a private copy (for example in a private Google Drive folder).

Running `supabase.sql` again wipes the game (players, answers, questions and the PIN), so run `questions.local.sql` and set the PIN again afterwards. Do that before the event, never during. Running `questions.local.sql` again on its own is safe: it only replaces the questions.

If you forget the questions file, the host page says "No questions loaded" and the quiz will not start.

### The question bank

3. Start another new query, paste all of `bank.local.sql` and click **Run**. It fills the bank and should print `bank_questions: 45`. Running it again is safe: it only replaces the bank.

If the database was created before the bank existed, run `migrations/question_bank.sql` once first. It adds the bank without touching players, scores or the PIN.

### Writing and editing questions

In the picker, press **New question**, or click a question and press **Edit** or **Duplicate**. Pick the **Question type** first:

- **Quiz**: pick the right answer (or several, with Multi-select).
- **Poll**: two to six answers, no right one. The big screen shows how the room voted. Nobody scores.
- **Type answer**: players type their answer. List up to four ways to write it (for example `USDC` and `USD Coin`). Capitals and spaces don't count, spelling does. The big screen shows the most common answers typed, leaving rude ones out.
- **Slider**: players slide to a number. Set the lowest and highest numbers, the step, the right answer, how far off still scores, and an optional unit.
- **Puzzle**: three or four items, typed in the right order. Phones get them shuffled and players tap them first to last.

**Add picture** (or paste one into the editor) puts one picture on the question. It shows on the big screen and on the phones while the question is open. The host page shrinks it to at most 1600 pixels and under 1 MB, then uploads it to the public `quiz-images` bucket under a random name, through the `quiz-upload` Edge Function, which checks the host PIN. Anyone with a picture's link can view it, but the links only reach the phones when the question opens. Removing a picture or deleting a question leaves the file in the bucket.

For a Quiz question, set the question, two to six answers (tick the right one, or press **True or false**; switch **Single answer** to **Multi-select** to tick several right answers), the label shown on the big screen, the time limit (5 seconds to 4 minutes), the points (Standard, Double points or No points), an explanation for after the reveal and a private note. Tick **Answer checked** once you have checked the answer. **Delete** takes two clicks.

A new question goes straight into the quiz you are building; press **Save quiz** to put it in play. Editing a question that is already in the saved quiz updates the quiz too, as long as the game is in the lobby. **Use this time for every question in this quiz** sets one time limit for the whole quiz. The editor shows the right answer, so keep the projector off the laptop screen while you use it.

Points: a right answer scores 500 to 1,000 (faster scores more). On a multi-select question players tick their answers and press Submit; they get a share of the points for each right answer ticked, and nothing if they tick any wrong one. On a slider, the exact number scores in full and a guess at the edge of the margin scores half; outside the margin scores nothing. A puzzle scores only when the whole order is right. A poll never scores. Double points doubles that. No points still shows who was right but adds nothing. Card mode awards stay at 100 a team.

Questions you write here live in the database. Running `bank.local.sql` again puts its own 45 questions back as written in the file (overwriting edits to those), but keeps your new questions and the time and points you set. If the database was created before the editor existed, run `migrations/question_editor.sql` once first. If it was created before Poll, Type answer, Slider and Puzzle existed, run `migrations/question_types.sql` once (it keeps players, scores and every question). For pictures, run `migrations/question_images.sql` once and deploy `functions/quiz-upload` as an Edge Function called `quiz-upload` with JWT verification off (the PIN is the check; Supabase supplies its service role key to the function, so it is never in this repo).

### Event name and teams

On the host page, in the lobby, press **Setup**. Type the event name (it shows at the top of the big screen and on the phone join page) and edit the teams: rename them, remove them or press **Add a team**. You can have 2 to 20 teams. Press **Save**. A team that already has players is locked, so set the teams before people join, or remove those players first. With more than eight teams the leaderboard shows the top eight; the final screen shows them all.

If the database was created before this existed, run `migrations/editable_setup.sql` once first. It keeps the teams you have now.

To choose the questions for a quiz: on the host page, in the lobby, press **Questions**. Filter by module or search, press **+** on each question you want, put them in order with the arrows (or **Shuffle**), then **Save quiz**. Click a question to see its options. **Show answers** highlights the right answer, so keep it unticked while the projector is showing your screen. A tag says whether each answer has been checked. The quiz can only be changed in the lobby, before it starts.

## 3. Set the host PIN

In a **new** query, run this once with your own PIN (at least 6 characters, letters and numbers are best):

```sql
select public.set_host_pin('ARCPH', 'your-pin-here');
```

Do not save that query or put the PIN in any file. The database only stores a bcrypt hash. Ten wrong PINs in a row lock host actions for 60 seconds.

## 4. Add the URL and key to `config.js`

In Supabase open **Project Settings > API** (or **API Keys**) and copy:

- the **Project URL** into `SUPABASE_URL`
- the **anon public** key (or the **publishable** key) into `SUPABASE_ANON_KEY`

Never use the `service_role` or **secret** key anywhere in this repo.

## 5. Add the logo

Put `Arc_Logo_White.svg` in this `quiz/` folder. Until it is there, the pages show the word "Arc" instead. Both pages are dark navy, so only the White logo is used.

Commit and push to `main`. GitHub Pages serves the pages a minute later.

## 6. On the day

1. On the host laptop, open the host page in Chrome **while online**, at least once before the quiz. This caches the questions and the page for card mode.
2. Enter the PIN. Press **Full screen**.
3. The lobby shows the QR code and how many players joined each group. Click **Players** to remove someone (click their name twice).
4. Run the quiz with the keyboard:

| Key | What it does |
| --- | --- |
| Space or Enter (or a clicker's next button) | Next step: Start, Reveal, Leaderboard, Next question, Final results, Top players |
| Left arrow (or a clicker's back button) | Back |

Buttons at the bottom of the screen (they brighten when the mouse is over them): Back, Pause, the next step, End quiz, Reset game, Setup, Questions, Players, Team scores, Sound, Voice, Card mode, Full screen. End quiz and Reset game need two clicks.

**Sound** plays the effects (join blip, heartbeat for the last five seconds, reveal chime, drumroll and fanfare). **Voice** makes the browser read out questions, answers and winners. Both are on by default and are made in the browser, so plug the laptop into the room speakers. The browser only allows sound after you have clicked or pressed a key on the page once.

How a question runs: 20 seconds on the ring timer, "Answers in: 63 / 88" below it. It reveals by itself one second after time runs out, or when you press Space. Back during an open question cancels it (and deletes its answers, after a second press). A reveal cannot be undone.

If the host page reloads, it picks up where the game is in the database.

### Card mode (if the internet fails)

Tick **Card mode**. Phone answers turn off. Groups hold up A, B, C or D cards. After you reveal, click each group that held up the right card for 100 points. Card points are added to the group's average.

Card mode keeps working with no internet at all: it runs from the questions cached in step 1, and if you reload the page offline it continues where you were. When the internet comes back, the host page sends its position and card points to Supabase, and phones catch up. Turn card mode off once you are back online to let phones answer again.

## 7. Rehearsal with 10 phones

Do this a day or two before the event, on the real Supabase project and the real GitHub Pages URL, with the laptop and projector you will use. Hand out 10 phones (a mix of Android and iPhone, some on mobile data, some on wifi) and cover all six groups.

Phone mode:

1. Host page on the projector, PIN entered, full screen. Everyone scans the QR code from the back of the room.
2. Join with a few edge cases: two people with the same name (the leaderboard should show "Ada (2)"), a 20-character name, and one rude name (it should be refused).
3. In the lobby, remove one player with **Players** (two clicks). Their phone should ask them to join again.
4. Start. Check every phone shows the question, the four buttons and the countdown within a second or two of the projector.
5. During questions: one phone answers instantly (close to 1000 points), one at about 10 seconds (about 750), one answers wrong, one does not answer.
6. One phone reloads the page mid-question: it should come back to the same question with its answer still locked.
7. One phone turns on airplane mode for 10 seconds: it should show "Reconnecting...", then catch up when it comes back.
8. One new phone joins at question 3: it should start on the current question with 0 points.
9. Press **Pause**, check the phones show "Paused", then resume.
10. Let one question run out (it reveals by itself) and reveal another early with Space.
11. Check each reveal: right answer highlighted, answer bars, explanation, group scores. Then the leaderboard.

Card mode (the backup):

12. Tick **Card mode** in the middle of a question. Phones should say "Card round. Hold up your group's card." and stop taking answers.
13. Turn the laptop's wifi off. Reveal, click the groups that held up the right card, go to the leaderboard and on to the next question. The chip should say Offline.
14. Still offline, reload the host page. It should come back to the same card round. (This needs the host page to have been opened online earlier, see step 1 of "On the day". Do it in Chrome, which keeps an offline copy of the page.)
15. Turn wifi back on. Within a few seconds the chip says Live and the phones jump to the same question. Untick **Card mode**: phones can answer again.

Finish:

16. **End quiz** (two clicks). Check the group podium, then Space for the top 5 players. Each phone shows its total, its rank and its group's rank.
17. **Reset game** (two clicks). The lobby should show 0 players.

Note anything that looked wrong, with the phone model and the question number.

## 8. Reset after the event (or after a rehearsal)

Press **Reset game** twice. This deletes all players, answers and card points and goes back to the lobby. The questions and PIN stay.

## Scoring

- Correct: `500 + round(500 * (1 - seconds / time limit))`, so 1000 for an instant answer and at least 500. Double points questions score twice that; No points questions score 0. Wrong or no answer: 0.
- Multi-select: that share of the points for each right answer ticked, 0 if any wrong answer is ticked.
- Slider: inside the margin, `points * (1 - 0.5 * distance / margin)`, so the exact number scores in full and the edge of the margin half. Outside the margin: 0.
- Puzzle: all or nothing. Type answer: right when it matches an accepted answer, ignoring capitals and spaces. Poll: always 0.
- Time is measured with the database clock, not the phone's.
- One answer per player per question. Answers after 21 seconds (20 plus 1 second grace) or after the reveal are rejected.
- Group score = average of the members' totals (players who never answered count as 0) + 100 per card-mode award. Ties go to the group with more correct answers.

## How the answers stay secret

- `questions` has row level security and no grants for the browser roles, so the correct index cannot be read.
- Phones read only the `games` row, which has no correct index until the host reveals. For type answer and slider questions the accepted answers and the right number are not in that row either until the reveal; puzzle items go out shuffled.
- `submit_answer` scores on the server and returns only `{"ok": true}`.
- Results come from `player_sync`, which only returns a result once the question is revealed.

- The questions and answers are only in `questions.local.sql`, which is git-ignored, so they are not in this public repo or on GitHub Pages.

## Load test

Run it before the event, never during. It deletes all players and answers in the game.

```bash
cd quiz/loadtest
npm install
SUPABASE_URL=https://xxxx.supabase.co SUPABASE_ANON_KEY=your-anon-key HOST_PIN=your-pin node loadtest.mjs --yes
```

On Windows PowerShell set the variables first with `$env:SUPABASE_URL="..."` and so on.

It joins 100 simulated players, each with its own realtime connection, runs all 12 questions with answers at random times inside the 20 seconds, and reports joins, realtime subscriptions, accepted and rejected answers, realtime events received and dropped, event latency, answer leaks and score mismatches. It takes about 7 minutes. Add `--fast` to reveal as soon as everyone has answered.

## Free plan limits

Supabase Free allows 200 concurrent realtime connections and 100 realtime messages per second (https://supabase.com/docs/guides/realtime/limits). Each phone opens one channel and listens to one row. Each host step sends one update, which fans out to about 100 phones once. Countdowns run on the phones. Phones also check in every 15 seconds (every 3 seconds while realtime is down), so a missed message is caught up quickly.
