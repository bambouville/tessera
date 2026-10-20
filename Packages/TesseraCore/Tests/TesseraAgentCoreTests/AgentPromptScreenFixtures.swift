// Captured from the real TUIs (Claude Code 2.1.285, Codex 0.157.1, Kimi Code 0.41.0)
// driven by scripted mock model providers in private tmux servers. Paths are
// replaced; rows above the last 26 are dropped. The phone fixtures (Claude
// Code 2.1.285, Codex 0.159.2, Kimi Code 2.1.1) are the apps' own capture of a
// phone-sized pane, `capture-pane -e -N`: styles kept, a taller dialog kept whole.

enum AgentPromptScreenFixtures {
    static let claudeAskSingle = Fixture(cursorRow: 15, cursorVisible: false, text: #"""
     · Which features should ship first? → Search, Sharing
     · Should I open a pull request when done? → No

⏺ Tool result received: "Your questions have been answered: \"Which database should the service
  use?\"=\"Postgres\", \"Which features should ship first?\"=\"Search, Sharing\", \"Should I open a pull
  request when done?\"=\"No\". You can now continue with these answers in mind."

✻ Churned for 0s · done 7:21 PM

❯ SCRIPT:ask1
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ☐ Database

Which database should the service use for the new ledger?

❯ 1. Postgres (Recommended)
     Mature, transactional, already deployed.
  2. SQLite
     Embedded file, zero operations.
  3. DynamoDB
     Managed key-value store.
  4. Type something.
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
"""#)
    static let claudeAskSingleTypeFocused = Fixture(cursorRow: 21, cursorVisible: false, text: #"""
     · Which features should ship first? → Search, Sharing
     · Should I open a pull request when done? → No

⏺ Tool result received: "Your questions have been answered: \"Which database should the service
  use?\"=\"Postgres\", \"Which features should ship first?\"=\"Search, Sharing\", \"Should I open a pull
  request when done?\"=\"No\". You can now continue with these answers in mind."

✻ Churned for 0s · done 7:21 PM

❯ SCRIPT:ask1
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ☐ Database

Which database should the service use for the new ledger?

  1. Postgres (Recommended)
     Mature, transactional, already deployed.
  2. SQLite
     Embedded file, zero operations.
  3. DynamoDB
     Managed key-value store.
❯ 4. Type something.
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · ↑/↓ to navigate · ctrl+g to edit in VS Code · Esc to cancel
"""#)
    static let claudeAskSingleTyped = Fixture(cursorRow: 21, cursorVisible: false, text: #"""
     · Which features should ship first? → Search, Sharing
     · Should I open a pull request when done? → No

⏺ Tool result received: "Your questions have been answered: \"Which database should the service
  use?\"=\"Postgres\", \"Which features should ship first?\"=\"Search, Sharing\", \"Should I open a pull
  request when done?\"=\"No\". You can now continue with these answers in mind."

✻ Churned for 0s · done 7:21 PM

❯ SCRIPT:ask1
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ☐ Database

Which database should the service use for the new ledger?

  1. Postgres (Recommended)
     Mature, transactional, already deployed.
  2. SQLite
     Embedded file, zero operations.
  3. DynamoDB
     Managed key-value store.
❯ 4. abc 123
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · ↑/↓ to navigate · ctrl+g to edit in VS Code · Esc to cancel
"""#)
    static let claudeAskChatSelected = Fixture(cursorRow: nil, cursorVisible: false, text: #"""

❯ SCRIPT:ask1

⏺ Tool result received: "The user doesn't want to proceed with this tool use. The tool use was rejected (eg.
  if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the
  user to tell you how to proceed."

✻ Cogitated for 0s · done 7:26 PM

❯ SCRIPT:ask1
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ☐ Database

Which database should the service use for the new ledger?

  1. Postgres (Recommended)
     Mature, transactional, already deployed.
  2. SQLite
     Embedded file, zero operations.
  3. DynamoDB
     Managed key-value store.
  4. Type something.
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 5. Chat about this

Enter to select · ↑/↓ to navigate · ctrl+g to edit in VS Code · Esc to cancel
"""#)
    static let claudeAskAfterEsc = Fixture(cursorRow: 23, cursorVisible: false, text: #"""
✻ Sautéed for 0s · done 7:20 PM

❯ multi SCRIPT:ask3

⏺ User answered Claude's questions:
  ⎿  · Which database should the service use? → Postgres
     · Which features should ship first? → Search, Sharing
     · Should I open a pull request when done? → No

⏺ Tool result received: "Your questions have been answered: \"Which database should the service
  use?\"=\"Postgres\", \"Which features should ship first?\"=\"Search, Sharing\", \"Should I open a pull
  request when done?\"=\"No\". You can now continue with these answers in mind."

✻ Churned for 0s · done 7:21 PM

❯ SCRIPT:ask1

⏺ User declined to answer questions
  ⎿  · Which database should the service use for the new ledger? (Postgres (Recommended) / SQLite / DynamoDB)

✻ Baked for 0s · done 7:26 PM

──────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏸ manual mode on · ? for shortcuts · ← for agents                                       ◐ medium · /effort
"""#)
    static let claudePermBash = Fixture(cursorRow: 20, cursorVisible: false, text: #"""
  said:\nThe user wants to clarify these questions.\n    This means they may have additional information,
  contex

✻ Crunched for 0s · done 7:26 PM

❯ SCRIPT:bash

⏺ Bash(python3 hello.py)
  ⎿  Waiting…

──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Bash command
 Tip: auto mode handles these prompts for you — choose "switch to auto mode" below

   python3 hello.py
   Run hello.py

 This command requires approval

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don’t ask again for: python3 *
   3. Yes, and switch to auto mode · auto mode handles these prompts for you
   4. No

 Esc to cancel · Tab to amend
"""#)
    static let claudePermWrite = Fixture(cursorRow: 20, cursorVisible: false, text: #"""

❯ SCRIPT:edit

⏺ Tool result received: "The user doesn't want to proceed with this tool use. The tool use was rejected (eg.
  if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the
  user to tell you how to proceed."

✻ Baked for 0s · done 7:27 PM

❯ SCRIPT:write

⏺ Write(new_file.txt)

──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Create file
 new_file.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
  1 fresh file
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to create new_file.txt?
 ❯ 1. Yes
   2. Yes, and switch to accept edits (auto-approve file edits and common file commands) for this session
      (shift+tab)
   3. No

 Esc to cancel · Tab to amend
"""#)
    static let claudePlanApproval = Fixture(cursorRow: 24, cursorVisible: false, text: #"""
  if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the
  user to tell you how to proceed."

✻ Crunched for 0s · done 7:28 PM

❯ 3SCRIPT:ask1

⏺ User declined to answer questions
  ⎿  · Which database should the service use for the new ledger? (Postgres (Recommended) / SQLite / DynamoDB)

⏺ Tool result received: "The user doesn't want to proceed with this tool use. The tool use was rejected (eg.
  if it was a file edit, the new_string was NOT written to the file). To tell you how to proceed, the user
  said:\nThe user wants to clarify these questions.\n    This means they may have additional information,
  contex

✻ Brewed for 0s · done 7:28 PM

❯ SCRIPT:plan

──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Exit plan mode?

  Claude wants to exit plan mode

  ❯ 1. Yes, and switch to default (ask each time) for this session
    2. No
"""#)
    static let claudeAsk3Q1 = Fixture(cursorRow: 17, cursorVisible: false, text: #"""

✻ Cogitated for 0s · done 7:47 PM

❯ SCRIPT:ask3

⏺ Tool result received: "The user doesn't want to proceed with this tool use. The tool use was rejected (eg.
  if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the
  user to tell you how to proceed."

✻ Brewed for 0s · done 7:49 PM

❯ SCRIPT:ask3
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
←  ☐ Database  ☐ Features  ☐ PR  ✔ Submit  →

Which database should the service use?

❯ 1. Postgres
     Transactional.
  2. SQLite
     Embedded.
  3. Type something.
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
  4. Chat about this

Enter to select · Tab/Arrow keys to navigate · Esc to cancel
"""#)
    static let claudeAsk3Q2Multi = Fixture(cursorRow: 14, cursorVisible: false, text: #"""
❯ SCRIPT:ask3

⏺ Tool result received: "The user doesn't want to proceed with this tool use. The tool use was rejected (eg.
  if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the
  user to tell you how to proceed."

✻ Brewed for 0s · done 7:49 PM

❯ SCRIPT:ask3
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
←  ☒ Database  ☐ Features  ☐ PR  ✔ Submit  →

Which features should ship first?

❯ 1. [ ] Search
         Full-text search.
  2. [ ] Export
         CSV export.
  3. [ ] Sharing
         Share links.
  4. [ ] Type something
     Next
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · Esc to cancel
"""#)
    static let claudeAsk3Q2Toggled = Fixture(cursorRow: 14, cursorVisible: false, text: #"""
❯ SCRIPT:ask3

⏺ Tool result received: "The user doesn't want to proceed with this tool use. The tool use was rejected (eg.
  if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the
  user to tell you how to proceed."

✻ Brewed for 0s · done 7:49 PM

❯ SCRIPT:ask3
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
←  ☒ Database  ☒ Features  ☐ PR  ✔ Submit  →

Which features should ship first?

❯ 1. [✔] Search
         Full-text search.
  2. [ ] Export
         CSV export.
  3. [✔] Sharing
         Share links.
  4. [ ] Type something
     Next
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · Esc to cancel
"""#)
    static let claudeAsk3Q2Row4Typed = Fixture(cursorRow: 20, cursorVisible: false, text: #"""
❯ SCRIPT:ask3

⏺ Tool result received: "The user doesn't want to proceed with this tool use. The tool use was rejected (eg.
  if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the
  user to tell you how to proceed."

✻ Brewed for 0s · done 7:49 PM

❯ SCRIPT:ask3
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
←  ☒ Database  ☒ Features  ☐ PR  ✔ Submit  →

Which features should ship first?

  1. [✔] Search
         Full-text search.
  2. [ ] Export
         CSV export.
  3. [✔] Sharing
         Share links.
❯ 4. [✔] Audit log
     Next
──────────────────────────────────────────────────────────────────────────────────────────────────────────────
  5. Chat about this

Enter to select · Tab/Arrow keys to navigate · ctrl+g to edit in VS Code · Esc to cancel
"""#)
    static let claudeAsk3Review = Fixture(cursorRow: 24, cursorVisible: false, text: #"""
❯ SCRIPT:ask3

⏺ Tool result received: "The user doesn't want to proceed with this tool use. The tool use was rejected (eg.
  if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the
  user to tell you how to proceed."

✻ Brewed for 0s · done 7:49 PM

❯ SCRIPT:ask3

──────────────────────────────────────────────────────────────────────────────────────────────────────────────
←  ☒ Database  ☒ Features  ☒ PR  ✔ Submit  →

Review your answers

 ● Which database should the service use?
   → Postgres
 ● Which features should ship first?
   → Search, Sharing, Audit log
 ● Should I open a pull request when done?
   → No

Ready to submit your answers?

❯ 1. Submit answers
  2. Cancel
"""#)
    static let codexAsync2Collapsed = Fixture(cursorRow: 22, cursorVisible: true, text: #"""
  • SQLite

  Describe the rollout window you prefer.












• Working (5s • esc to interrupt)

• Queued follow-up inputs
  ? 2 questions
    shift+← to answer


› Ask Codex to do anything

  GPT-6-Sol default · /home/dev/work…
  ? for shortcuts
"""#)
    static let codexAsyncCountdown = Fixture(cursorRow: 22, cursorVisible: true, text: #"""
  • SQLite
  • DynamoDB













• Working (16s • esc to interrupt)

• Queued follow-up inputs
  ? 1 question · 14s
    shift+← to answer


› Ask Codex to do anything

  GPT-6-Sol default · /home/dev/work…
  ? for shortcuts
"""#)
    static let codexAsync2OpenQ1 = Fixture(cursorRow: 13, cursorVisible: false, text: #"""
  • Postgres
  • SQLite

  Describe the rollout window you prefer.









• Working (7s • esc to interrupt)

• Queued follow-up inputs


  1 of 2
  Which database should the service use?

  › 1. Postgres
    2. SQLite
    3. Other

  enter submit   ctrl+] skip   ⌥+↓ main prompt   shift+← next question
"""#)
    static let codexAsync2AfterQ1 = Fixture(cursorRow: 23, cursorVisible: true, text: #"""
  • Postgres
  • SQLite

  Describe the rollout window you prefer.







• Working (16s • esc to interrupt)

• Messages to be submitted after next tool call (press esc to interrupt and send immediately)
  ↳ > Which database should the service use?

    Postgres

• Queued follow-up inputs


  Describe the rollout window you prefer.

  Type your answer

  enter submit   ctrl+] skip   ⌥+↓ main prompt
"""#)
    static let codexAsync2Q2Typed = Fixture(cursorRow: 23, cursorVisible: true, text: #"""
  • Postgres
  • SQLite

  Describe the rollout window you prefer.







• Working (25s • esc to interrupt)

• Messages to be submitted after next tool call (press esc to interrupt and send immediately)
  ↳ > Which database should the service use?

    Postgres

• Queued follow-up inputs


  Describe the rollout window you prefer.

  Weekend, 2 to 4 am

  enter submit   ctrl+] skip   ⌥+↓ main prompt
"""#)
    static let codexAsync2Done = Fixture(cursorRow: 22, cursorVisible: true, text: #"""
  • SQLite

  Describe the rollout window you prefer.








• Working (27s • esc to interrupt)

• Messages to be submitted after next tool call (press esc to interrupt and send immediately)
  ↳ > Which database should the service use?

    Postgres
  ↳ > Describe the rollout window you prefer.

    Weekend, 2 to 4 am


› Ask Codex to do anything

  GPT-6-Sol default · /home/dev/work…
  ? for shortcuts
"""#)
    static let codexAsync1Open = Fixture(cursorRow: 13, cursorVisible: false, text: #"""
■ Conversation interrupted - tell the model what to do differently. Something went wrong? Hit `/feedback` to
report the issue.


› SCRIPT:async1


• Which database should the service use for the new ledger?

  • Postgres
  • SQLite
  • DynamoDB

• Working (7s • esc to interrupt)

• Queued follow-up inputs


  Which database should the service use for the new ledger?

  › 1. Postgres
    2. SQLite
    3. DynamoDB
    4. Other

  enter submit   ctrl+] skip   ⌥+↓ main prompt
"""#)
    static let codexAsync1OtherFocused = Fixture(cursorRow: 23, cursorVisible: true, text: #"""
■ Conversation interrupted - tell the model what to do differently. Something went wrong? Hit `/feedback` to
report the issue.


› SCRIPT:async1


• Which database should the service use for the new ledger?

  • Postgres
  • SQLite
  • DynamoDB

• Working (8s • esc to interrupt)

• Queued follow-up inputs


  Which database should the service use for the new ledger?

    1. Postgres
    2. SQLite
    3. DynamoDB
  › 4. Other

  enter submit   ctrl+] skip   ⌥+↓ main prompt
"""#)
    static let codexAsync1OtherTyped = Fixture(cursorRow: 23, cursorVisible: true, text: #"""
■ Conversation interrupted - tell the model what to do differently. Something went wrong? Hit `/feedback` to
report the issue.


› SCRIPT:async1


• Which database should the service use for the new ledger?

  • Postgres
  • SQLite
  • DynamoDB

• Working (9s • esc to interrupt)

• Queued follow-up inputs


  Which database should the service use for the new ledger?

    1. Postgres
    2. SQLite
    3. DynamoDB
  › 4. CockroachDB 24

  enter submit   ctrl+] skip   ⌥+↓ main prompt
"""#)
    static let codexRuiPlan = Fixture(cursorRow: 25, cursorVisible: false, text: #"""
  7:32 PM

• Model changed to gpt-6-sol medium for Plan mode.


› blocking SCRIPT:rui












  Question 1/1 (1 unanswered)
  Which database should we use?

  › 1. Postgres (Recommended)  Transactional and deployed.
    2. SQLite                  Embedded, zero operations.
    3. None of the above       Optionally, add details in notes (tab)

  tab to add notes | enter to submit answer | esc to interrupt
"""#)
    static let codexRuiNotesOpen = Fixture(cursorRow: 23, cursorVisible: true, text: #"""
















  Question 1/1 (1 unanswered)
  Which database should we use?

    1. Postgres (Recommended)  Transactional and deployed.
    2. SQLite                  Embedded, zero operations.
  › 3. None of the above       Optionally, add details in notes (tab)

  › Add notes

  tab or esc to clear notes | enter to submit answer
"""#)
    static let codexRuiNotesTyped = Fixture(cursorRow: 23, cursorVisible: true, text: #"""
















  Question 1/1 (1 unanswered)
  Which database should we use?

    1. Postgres (Recommended)  Transactional and deployed.
    2. SQLite                  Embedded, zero operations.
  › 3. None of the above       Optionally, add details in notes (tab)

  › CockroachDB instead

  tab or esc to clear notes | enter to submit answer
"""#)
    static let codexRuiAfter2 = Fixture(cursorRow: 22, cursorVisible: true, text: #"""

• Model changed to gpt-6-sol medium for Plan mode.


› blocking SCRIPT:rui


• Questions 1/1 answered
  • Which database should we use?
    answer: SQLite

• Tool output: {"answers":{"database":{"answers":["SQLite"]}}}

  7:32 PM






                                               Tip: Run /review to get a code review of your current changes.

› Ask Codex to do anything

  GPT-6-Sol medium · /home/dev/work… Plan mode
  ? for shortcuts
"""#)
    static let codexExecApproval = Fixture(cursorRow: 25, cursorVisible: false, text: #"""












  Would you like to run the following command?

  Environment: local

  Reason: Run the hello script outside the sandbox

  $ python3 hello.py


› 1. Yes, proceed (y)
  2. Yes, and don't ask again for commands that start with `python3 hello.py` (p)
  3. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel
"""#)
    static let kimiAskSingle = Fixture(cursorRow: 25, cursorVisible: false, text: #"""
 ✨ hi

 ✗ Could not collect your input
   Invalid args for tool "AskUserQuestion": must NOT have additional property 'multiSelect'

 ● Tool result: <system>ERROR: Tool execution failed.</system>
   Invalid args for tool "AskUserQuestion": must NOT have additional property 'multiSelect'

 ✨ q SCRIPT:ask1
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
  question

   Database    Submit

  ? Which database should the service use for the new ledger?

   → [1] Postgres
         Mature and transactional.
     [2] SQLite
         Embedded file.
     [3] Other

   ↑↓ select  1-3 / ↵ choose  ←/→/tab switch  esc cancel
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Mock  ~/work                               /sessions to browse and resume earlier sessions
                                                                                        context: 1% (15/256k)
"""#)
    static let kimiAskAfter2 = Fixture(cursorRow: 25, cursorVisible: false, text: #"""
 ✗ Could not collect your input
   Invalid args for tool "AskUserQuestion": must NOT have additional property 'multiSelect'

 ● Tool result: <system>ERROR: Tool execution failed.</system>
   Invalid args for tool "AskUserQuestion": must NOT have additional property 'multiSelect'

 ✨ q SCRIPT:ask1
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
  question

  (✓) Database   Submit

  Review your answer before submit

   Q  Which database should the service use for the new ledger?
   →  SQLite

  Ready to submit your answers?

   → [1] Submit
     [2] Cancel

   ↑↓ select  1/2 choose  ↵ confirm  ←/→/tab switch  esc cancel
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Mock  ~/work       /goal next to queue follow-up work while the current goal keeps running
                                                                                        context: 1% (15/256k)
"""#)
    static let kimiAsk2 = Fixture(cursorRow: 25, cursorVisible: false, text: #"""

 ✦ Kimi Code Desktop is here — Everything you love about Kimi Code, now on desktop
   Run /desktop or visit https://www.kimi.com/code to install

   No session yet — one will be created on your first message.
   tmux extended-keys is off. Modified Enter keys may not work. Add `set -g extended-keys on` to ~/.tmux.conf
 and restart tmux.

 ✨ go SCRIPT:ask2
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
  question

   Database   (○) Features   Submit

  ? Which database should the service use?

   → [1] Postgres
         Transactional.
     [2] SQLite
         Embedded.
     [3] Other

   ↑↓ select  1-3 / ↵ choose  ←/→/tab switch  esc cancel
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Mock  ~/work
                                                                                        context: 1% (15/256k)
"""#)
    static let kimiAsk2Multi = Fixture(cursorRow: 22, cursorVisible: false, text: #"""
 ● Ran a command · $ python3 hello.py
   hello

   Approved for session: Running: python3 hello.py

 ● Tool result: Wall time: 0.030 seconds
   hello

 ✨ go SCRIPT:ask2
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
  question

  (✓) Database   Features    Submit

  ? Which features should ship first?

   [ ] Search
         Full-text search.
   [ ] Export
         CSV export.
   [ ] Other

   ↑↓ select  1-3 / ↵ toggle  ←/→/tab switch  esc cancel
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Mock  ~/work                                                     /init: generate AGENTS.md
                                                                                        context: 1% (15/256k)
"""#)
    static let kimiAsk2MultiToggled = Fixture(cursorRow: 18, cursorVisible: false, text: #"""
 ● Ran a command · $ python3 hello.py
   hello

   Approved for session: Running: python3 hello.py

 ● Tool result: Wall time: 0.030 seconds
   hello

 ✨ go SCRIPT:ask2
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
  question

  (✓) Database   Features    Submit

  ? Which features should ship first?

   [ ] Search
         Full-text search.
   [✓] Export
         CSV export.
   [ ] Other

   ↑↓ select  1-3 / ↵ toggle  ←/→/tab switch  esc cancel
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Mock  ~/work                                                     /init: generate AGENTS.md
                                                                                        context: 1% (15/256k)
"""#)
    static let kimiAsk2Review = Fixture(cursorRow: 25, cursorVisible: false, text: #"""

 ● Tool result: Wall time: 0.030 seconds
   hello

 ✨ go SCRIPT:ask2
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
  question

  (✓) Database  (✓) Features   Submit

  Review your answer before submit

   Q  Which database should the service use?
   →  Postgres
   Q  Which features should ship first?
   →  Export

  Ready to submit your answers?

   → [1] Submit
     [2] Cancel

   ↑↓ select  1/2 choose  ↵ confirm  ←/→/tab switch  esc cancel
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Mock  ~/work                                   @: mention files | ! to run a shell command
                                                                                        context: 1% (15/256k)
"""#)
    static let kimiOtherFocused = Fixture(cursorRow: 20, cursorVisible: false, text: #"""
   →  Postgres
   Q  Which features should ship first?
   →  Export

 ● Tool result: {"answers":{"Which database should the service use?":"Postgres","Which features should ship
   first?":"Export"}}

 ✨ q SCRIPT:ask1
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
  question

   Database    Submit

  ? Which database should the service use for the new ledger?
    Type your answer, then press Enter to save.

     [1] Postgres
         Mature and transactional.
     [2] SQLite
         Embedded file.
   → [3] Other:

   type answer  ↵ save  tab switch  esc cancel
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Mock  ~/work      ! to run a shell command | /compact compresses context when it gets long
                                                                                        context: 1% (15/256k)
"""#)
    static let kimiOtherTyped = Fixture(cursorRow: 20, cursorVisible: false, text: #"""
   →  Postgres
   Q  Which features should ship first?
   →  Export

 ● Tool result: {"answers":{"Which database should the service use?":"Postgres","Which features should ship
   first?":"Export"}}

 ✨ q SCRIPT:ask1
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
  question

   Database    Submit

  ? Which database should the service use for the new ledger?
    Type your answer, then press Enter to save.

     [1] Postgres
         Mature and transactional.
     [2] SQLite
         Embedded file.
   → [3] Other: abc 12

   type answer  ↵ save  tab switch  esc cancel
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Mock  ~/work      ! to run a shell command | /compact compresses context when it gets long
                                                                                        context: 1% (15/256k)
"""#)
    static let kimiBash = Fixture(cursorRow: 25, cursorVisible: false, text: #"""

 ✨ go SCRIPT:bash

 ● Collected your answers
   User dismissed the question without answering.

 ● Tool result: {"answers":{},"note":"User dismissed the question without answering."}

 ✨ go SCRIPT:bash

 ● Running a command · $ python3 hello.py
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
   ▶ Run this command?

   cwd: /home/dev/work
   $ python3 hello.py

   ▶ 1. Approve once
     2. Approve for this session
     3. Reject
     4. Reject with feedback

   ↑/↓ select · 1/2/3/4 choose · ↵ confirm
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Mock  ~/work                                     ctrl+o expand | /init: generate AGENTS.md
                                                                                        context: 1% (15/256k)
"""#)
    static let kimiAskbg = Fixture(cursorRow: 25, cursorVisible: false, text: #"""
   task_id: question-kjcxwchm
   status: running
   next_step: Continue your work; the answer arrives automatically in a later message. Use TaskStop only to …

 ● Tool result: task_id: question-kjcxwchm
   status: running
   next_step: Continue your work; the answer arrives automatically in a later message. Use TaskStop only to
   cancel the question.

 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
  question

   Region    Submit

  ? Which region should host the ledger?

   → [1] eu-west-1
         Ireland.
     [2] us-east-1
         Virginia.
     [3] Other

   ↑↓ select  1-3 / ↵ choose  ←/→/tab switch  esc cancel
 ────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Mock  [1 task running]  ~/work                                               ctrl+o expand
                                                                                        context: 1% (15/256k)
"""#)
    static let kimiReviewAfter1 = Fixture(cursorRow: 22, cursorVisible: false, text: #"""
   Invalid args for tool "AskUserQuestion": must NOT have additional property 'multiSelect'

 ● Tool result: <system>ERROR: Tool execution failed.</system>
   Invalid args for tool "AskUserQuestion": must NOT have additional property 'multiSelect'

 ✨ hi

 ✗ Could not collect your input
   Invalid args for tool "AskUserQuestion": must NOT have additional property 'multiSelect'

 ● Tool result: <system>ERROR: Tool execution failed.</system>
   Invalid args for tool "AskUserQuestion": must NOT have additional property 'multiSelect'

 ✨ q SCRIPT:ask1

 ● Collected your answers
   Q  Which database should the service use for the new ledger?
   →  SQLite

 ● Tool result: {"answers":{"Which database should the service use for the new ledger?":"SQLite"}}

 ╭──────────────────────────────────────────────────────────────────────────────────────────────────────────╮
 │ >                                                                                                        │
 ╰──────────────────────────────────────────────────────────────────────────────────────────────────────────╯
 Mock  ~/work                                  /web: use the Web UI for a better experience
                                                                                        context: 1% (15/256k)
"""#)

    // MARK: Phone-sized panes

    static let claudeAskWidePhone = Fixture(cursorRow: 23, cursorVisible: false, text: #"""
\#u{1B}[38;5;231m⏺\#u{1B}[39m Tool result received: "The user answered: \"Which     
  database should the service use?\"=\"CockroachDB\",   
  \"Which features should ship first?\"=\"Export,       
  Sharing\", \"Should I open a pull request when        
  done?\"=\"No\". Read the answers carefully \u2014 they
  may request clarification, changes, or that you not   
  proceed \u2014 and        

\#u{1B}[38;5;246m✻\#u{1B}[39m \#u{1B}[38;5;246mCrunched for 0s · done 7:45 AM\#u{1B}[39m                        
                                                        
\#u{1B}[38;5;239m\#u{1B}[48;5;237m❯ \#u{1B}[38;5;231mSCRIPT:askwide\#u{1B}[39m                                        
\#u{1B}[38;5;246m\#u{1B}[49m────────────────────────────────────────────────────────
← \#u{1B}[38;5;16m\#u{1B}[48;5;153m ☐ Run plan \#u{1B}[39m\#u{1B}[49m ☐ Report  ✔ Submit  →                    
                            
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mWhich plan should the next run use? The last run of \#u{1B}[0m  
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mthe ledger import (src/…/import/batch_job.py, 120 rows
\#u{1B}[0;2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mper batch) finished in 244 s against a 164–190 s \#u{1B}[0m     
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mbudget, and the retry pass after it took 62.6 s for \#u{1B}[0m  
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231m33,945 rows. The fast path is about 1.7× quicker than 
\#u{1B}[0;2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mthe current one, but it skips the checksum pass, so a 
\#u{1B}[0;2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mcorrupt batch would only show up in the nightly audit.
\#u{1B}[0;2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mWhich trade-off do you want?\#u{1B}[0m                          

\#u{1B}[38;5;153m❯\#u{1B}[39m \#u{1B}[38;5;246m1.\#u{1B}[39m \#u{1B}[38;5;153mKeep the current plan (safe)\#u{1B}[39m                       
     \#u{1B}[38;5;246mRun the same batches with the checksum pass on \#u{1B}[39m    
     \#u{1B}[38;5;246mevery batch, and report the timing against the \#u{1B}[39m    
     \#u{1B}[38;5;246m164–190 s budget again so the regression is \#u{1B}[39m       
     \#u{1B}[38;5;246mvisible: −23.63% → about −13%.\#u{1B}[39m                     
  \#u{1B}[38;5;246m2.\#u{1B}[39m Switch to the fast path
     \#u{1B}[38;5;246mSkip the checksum pass for this run, keep a copy of
\#u{1B}[39m     \#u{1B}[38;5;246mevery batch, and rely on the nightly audit to \#u{1B}[39m     
     \#u{1B}[38;5;246mcatch a corrupt one.\#u{1B}[39m                               
  \#u{1B}[38;5;246m3.\#u{1B}[39m Stop and report                                    
     \#u{1B}[38;5;246mStop now and report the partial timings.\#u{1B}[39m           
  \#u{1B}[38;5;246m4. Type something.\#u{1B}[39m        
\#u{1B}[38;5;246m────────────────────────────────────────────────────────
\#u{1B}[39m  5. Chat about this                                    

\#u{1B}[38;5;246mEnter to select · Tab/Arrow keys to navigate · Esc to \#u{1B}[39m  
\#u{1B}[38;5;246mcancel\#u{1B}[39m                                                  
"""#)
    static let claudeAskWideNarrow = Fixture(cursorRow: 14, cursorVisible: false, text: #"""
\#u{1B}[38;5;246m\#u{1B}[49m─────────────────────────────────────────────────
← \#u{1B}[38;5;16m\#u{1B}[48;5;153m ☐ Run plan \#u{1B}[39m\#u{1B}[49m ☐ Report  ✔ Submit  →             

\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mWhich plan should the next run use? The last \#u{1B}[0m  
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mrun of the ledger import \#u{1B}[0m                      
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231m(src/…/import/batch_job.py, 120 rows per batch)
\#u{1B}[0;2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mfinished in 244 s against a 164–190 s budget, \#u{1B}[0m 
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mand the retry pass after it took 62.6 s for \#u{1B}[0m   
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231m33,945 rows. The fast path is about 1.7× \#u{1B}[0m      
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mquicker than the current one, but it skips the 
\#u{1B}[0;2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mchecksum pass, so a corrupt batch would only \#u{1B}[0m  
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mshow up in the nightly audit. Which trade-off \#u{1B}[0m 
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mdo you want?\#u{1B}[0m          

\#u{1B}[38;5;153m❯\#u{1B}[39m \#u{1B}[38;5;246m1.\#u{1B}[39m \#u{1B}[38;5;153mKeep the current plan (safe)\#u{1B}[39m                
     \#u{1B}[38;5;246mRun the same batches with the checksum pass 
\#u{1B}[39m     \#u{1B}[38;5;246mon every batch, and report the timing \#u{1B}[39m      
     \#u{1B}[38;5;246magainst the 164–190 s budget again so the \#u{1B}[39m  
     \#u{1B}[38;5;246mregression is visible: −23.63% → about −13%.
\#u{1B}[39m  \#u{1B}[38;5;246m2.\#u{1B}[39m Switch to the fast path                     
     \#u{1B}[38;5;246mSkip the checksum pass for this run, keep a 
\#u{1B}[39m     \#u{1B}[38;5;246mcopy of every batch, and rely on the nightly
\#u{1B}[39m     \#u{1B}[38;5;246maudit to catch a corrupt one.\#u{1B}[39m               
  \#u{1B}[38;5;246m3.\#u{1B}[39m Stop and report    
     \#u{1B}[38;5;246mStop now and report the partial timings.\#u{1B}[39m    
  \#u{1B}[38;5;246m4. Type something.\#u{1B}[39m    
\#u{1B}[38;5;246m─────────────────────────────────────────────────
\#u{1B}[39m  5. Chat about this    

\#u{1B}[38;5;246mEnter to select · Tab/Arrow keys to navigate · \#u{1B}[39m  
\#u{1B}[38;5;246mEsc to cancel\#u{1B}[39m           


"""#)
    static let claudeAskWideShortPane = Fixture(cursorRow: 7, cursorVisible: false, text: #"""
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mper batch) finished in 244 s against a 164–190 s \#u{1B}[0m     
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mbudget, and the retry pass after it took 62.6 s for \#u{1B}[0m  
\#u{1B}[2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231m33,945 rows. The fast path is about 1.7× quicker than 
\#u{1B}[0;2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mthe current one, but it skips the checksum pass, so a 
\#u{1B}[0;2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mcorrupt batch would only show up in the nightly audit.
\#u{1B}[0;2m│\#u{1B}[0m \#u{1B}[1m\#u{1B}[38;5;231mWhich trade-off do you want?\#u{1B}[0m                          

\#u{1B}[38;5;153m❯\#u{1B}[39m \#u{1B}[38;5;246m1.\#u{1B}[39m \#u{1B}[38;5;153mKeep the current plan (safe)\#u{1B}[39m                       
     \#u{1B}[38;5;246mRun the same batches with the checksum pass on \#u{1B}[39m    
     \#u{1B}[38;5;246mevery batch, and report the timing against the \#u{1B}[39m    
     \#u{1B}[38;5;246m164–190 s budget again so the regression is \#u{1B}[39m       
     \#u{1B}[38;5;246mvisible: −23.63% → about −13%.\#u{1B}[39m                     
  \#u{1B}[38;5;246m2.\#u{1B}[39m Switch to the fast path
     \#u{1B}[38;5;246mSkip the checksum pass for this run, keep a copy of
\#u{1B}[39m     \#u{1B}[38;5;246mevery batch, and rely on the nightly audit to \#u{1B}[39m     
     \#u{1B}[38;5;246mcatch a corrupt one.\#u{1B}[39m   
  \#u{1B}[38;5;246m3.\#u{1B}[39m Stop and report        
     \#u{1B}[38;5;246mStop now and report the partial timings.\#u{1B}[39m           
  \#u{1B}[38;5;246m4. Type something.\#u{1B}[39m        
\#u{1B}[38;5;246m────────────────────────────────────────────────────────
\#u{1B}[39m  5. Chat about this        

\#u{1B}[38;5;246mEnter to select · Tab/Arrow keys to navigate · Esc to \#u{1B}[39m  
\#u{1B}[38;5;246mcancel\#u{1B}[39m        
"""#)
    static let codexRuiPhone = Fixture(cursorRow: 14, cursorVisible: false, text: #"""



  \#u{1B}[2mQuestion 1/1 (1 unanswered)\#u{1B}[0m                           
  \#u{1B}[38;5;75mWhich database should we use?\#u{1B}[39m                         

  \#u{1B}[1;7m› 1. Postgres (Recommended)  \#u{1B}[0;7mTransactional and\#u{1B}[1m      \#u{1B}[0m  
  \#u{1B}[1;7m                             \#u{1B}[0;7mdeployed.\#u{1B}[1m              \#u{1B}[0m  
    2. SQLite                  \#u{1B}[2mEmbedded, zero\#u{1B}[0m           
                               \#u{1B}[2moperations.\#u{1B}[0m              
    3. None of the above       \#u{1B}[2mOptionally, add details\#u{1B}[0m  
                               \#u{1B}[2min notes (tab)\#u{1B}[0m           
                            
  \#u{1B}[1mtab\#u{1B}[0m to add notes\#u{1B}[2m | \#u{1B}[0;1menter\#u{1B}[0m to submit answer             
  \#u{1B}[1mesc\#u{1B}[0m to interrupt                                      
                            
"""#)
    static let kimiAskPhone = Fixture(cursorRow: 18, cursorVisible: false, text: #"""
 \#u{1B}[1m\#u{1B}[38;5;222m✨ SCRIPT:ask1\#u{1B}[0m                                         
 \#u{1B}[38;5;111m──────────────────────────────────────────────────────\#u{1B}[39m 
 \#u{1B}[1m\#u{1B}[38;5;111m question\#u{1B}[0m    
              
  \#u{1B}[1m\#u{1B}[38;5;253m\#u{1B}[48;5;111m Database \#u{1B}[0m  \#u{1B}[38;5;244m Submit \#u{1B}[39m      
              
 \#u{1B}[38;5;111m ? Which database should the service use for the new\#u{1B}[39m   
 \#u{1B}[38;5;111m   ledger?\#u{1B}[39m   
              
 \#u{1B}[38;5;111m  → [1] Postgres\#u{1B}[39m           
 \#u{1B}[38;5;244m        Mature and transactional.\#u{1B}[39m                      
 \#u{1B}[38;5;244m    [2] SQLite\#u{1B}[39m             
 \#u{1B}[38;5;244m        Embedded file.\#u{1B}[39m     
 \#u{1B}[38;5;244m    [3] Other
\#u{1B}[39m              
 \#u{1B}[38;5;244m  ↑↓ select  1-3 / ↵ choose  ←/→/tab switch  esc ca\#u{1B}[39m... 
 \#u{1B}[38;5;111m──────────────────────────────────────────────────────\#u{1B}[39m 
 \#u{1B}[38;5;253mMock\#u{1B}[39m  \#u{1B}[38;5;244m…/dev/ki\#u{1B}[39m… 
                                  \#u{1B}[38;5;253mcontext: 1% (15/256k)\#u{1B}[39m 
"""#)
    static let kimiReviewElidedPhone = Fixture(cursorRow: 19, cursorVisible: false, text: #"""
              
 \#u{1B}[38;5;111m──────────────────────────────────────────────────────\#u{1B}[39m 
 \#u{1B}[1m\#u{1B}[38;5;111m question\#u{1B}[0m    
              
  \#u{1B}[38;5;114m(✓) Region\#u{1B}[39m  \#u{1B}[1m\#u{1B}[38;5;253m\#u{1B}[48;5;111m Submit \#u{1B}[0m      
              
 \#u{1B}[1m\#u{1B}[38;5;253m Review your answer before submit\#u{1B}[0m                      
              
   \#u{1B}[38;5;244mQ\#u{1B}[39m  Which region should host the ledger?              
   \#u{1B}[38;5;111m→\#u{1B}[39m  \#u{1B}[38;5;253map-south-1 (Mumbai)\#u{1B}[39m   
              
 \#u{1B}[38;5;253m Ready to submit your answers?\#u{1B}[39m                         
              
 \#u{1B}[38;5;111m  → [1] Submit\#u{1B}[39m             
 \#u{1B}[38;5;244m    [2] Cancel\#u{1B}[39m             
              
 \#u{1B}[38;5;244m  ↑↓ select  1/2 choose  ↵ confirm  ←/→/tab switch \#u{1B}[39m... 
 \#u{1B}[38;5;111m──────────────────────────────────────────────────────\#u{1B}[39m 
 \#u{1B}[38;5;253mMock\#u{1B}[39m  \#u{1B}[38;5;111m[1 task running]\#u{1B}[39m  \#u{1B}[38;5;244m…/dev\#u{1B}[39m… 
                                  \#u{1B}[38;5;253mcontext: 1% (15/256k)\#u{1B}[39m 
"""#)

    // MARK: Reviews of long questions

    // Real reviews after three or four long questions at 56 columns: taller
    // than 30 rows (Claude) or 24 (Kimi), and in a 30-row pane (Claude) or
    // a 48-row one (Kimi), taller than the pane, which scrolls the top rule
    // off. Claude's review shows no key hints.
    static let claudeReviewTallPhone = Fixture(cursorRow: 46, cursorVisible: false, text: #"""
                                                        
\#u{1B}[38;5;231m⏺\#u{1B}[39m Tool result received: "Your questions have been       
  answered: "Which plan should the next run use? The    
  last run of the ledger import                         
  (src/\u2026/import/batch_job.py, 120 rows per batch)  
  finished in 244 s against a 164\u2013190 s budget, and
  the retry pass after it took 62.6 s for 33,945 rows.  
  The fast path is about 1.7\u00d                       
                                                        
\#u{1B}[38;5;246m✻\#u{1B}[39m \#u{1B}[38;5;246mSautéed for 0s · done 10:42 AM\#u{1B}[39m                        
                                                        
\#u{1B}[38;5;239m\#u{1B}[48;5;237m❯ \#u{1B}[38;5;231mSCRIPT:askreview\#u{1B}[39m                                      
\#u{1B}[49m                                                        
\#u{1B}[38;5;246m────────────────────────────────────────────────────────
\#u{1B}[39m←  ☒ Import lever  ☒ Release  ☒ Audit check \#u{1B}[38;5;16m\#u{1B}[48;5;153m ✔ Submit \#u{1B}[38;5;246m\#u{1B}[49m →
\#u{1B}[39m                                                        
\#u{1B}[1m\#u{1B}[38;5;231mReview your answers\#u{1B}[0m                                     
                                                        
 \#u{1B}[2m│\#u{1B}[0m ● Which lever should the importer try first? The     
 \#u{1B}[2m│\#u{1B}[0m   nightly import (src/…/import/ledger_job.py, 400    
 \#u{1B}[2m│\#u{1B}[0m   rows per batch) now spends 71% of its time         
 \#u{1B}[2m│\#u{1B}[0m   re-reading the same vendor table, and the cache    
 \#u{1B}[2m│\#u{1B}[0m   that would fix it doubles peak memory to about 3.2 
 \#u{1B}[2m│\#u{1B}[0m   GB on the smallest worker. Batching the vendor     
 \#u{1B}[2m│\#u{1B}[0m   reads keeps memory flat but only saves about a     
 \#u{1B}[2m│\#u{1B}[0m   third of the time, and it changes the order the    
 \#u{1B}[2m│\#u{1B}[0m   audit log sees. Which one should I try first,      
 \#u{1B}[2m│\#u{1B}[0m   keeping the audit order stable?                    
   \#u{1B}[38;5;114m→ Batch the vendor reads\#u{1B}[39m                             
 \#u{1B}[2m│\#u{1B}[0m ● The release branch test suite passes on            
 \#u{1B}[2m│\#u{1B}[0m   release/2026-09-ledger (tip 4c1e9a7b2). All 14     
 \#u{1B}[2m│\#u{1B}[0m   suites pass, the parity audit reports 0 failures,  
 \#u{1B}[2m│\#u{1B}[0m   and the output is identical to the current main.   
 \#u{1B}[2m│\#u{1B}[0m   Fast-forward main to it now?                       
   \#u{1B}[38;5;114m→ Fast-forward\#u{1B}[39m                                       
 \#u{1B}[2m│\#u{1B}[0m ● Open item from the last round: a vendor payment is 
 \#u{1B}[2m│\#u{1B}[0m   checked for currency, limits and funds, but not for
 \#u{1B}[2m│\#u{1B}[0m   the holiday calendar. A payment due on a bank      
 \#u{1B}[2m│\#u{1B}[0m   holiday reads settle_early=true, then gets dropped 
 \#u{1B}[2m│\#u{1B}[0m   when the batch closes at the cut-off. Both ledgers 
 \#u{1B}[2m│\#u{1B}[0m   agree, so parity holds, but the published total is 
 \#u{1B}[2m│\#u{1B}[0m   optimistic. Fix it?                                
   \#u{1B}[38;5;114m→ can payments settle a day late?\#u{1B}[39m                    

\#u{1B}[38;5;246mReady to submit your answers?\#u{1B}[39m                           

\#u{1B}[38;5;153m❯\#u{1B}[39m \#u{1B}[38;5;246m1. \#u{1B}[38;5;153mSubmit answers\#u{1B}[39m         
  \#u{1B}[38;5;246m2. \#u{1B}[39mCancel   
"""#)
    static let claudeReviewTallerPhone = Fixture(cursorRow: 46, cursorVisible: false, text: #"""
                                                        
\#u{1B}[38;5;239m\#u{1B}[48;5;237m❯ \#u{1B}[38;5;231mSCRIPT:tallreview\#u{1B}[39m                                     
\#u{1B}[49m                                                        
\#u{1B}[38;5;246m────────────────────────────────────────────────────────
\#u{1B}[39m←  ☒ Import … ☒ Release ☒ Audit c… ☒ Rollback\#u{1B}[38;5;16m\#u{1B}[48;5;153m ✔ Submit\#u{1B}[38;5;246m\#u{1B}[49m →
\#u{1B}[39m                                             \#u{1B}[38;5;16m\#u{1B}[48;5;153m \#u{1B}[39m\#u{1B}[49m          
                                                        
\#u{1B}[1m\#u{1B}[38;5;231mReview your answers\#u{1B}[0m                                     
                                                        
 \#u{1B}[2m│\#u{1B}[0m ● Which lever should the importer try first? The     
 \#u{1B}[2m│\#u{1B}[0m   nightly import (src/…/import/ledger_job.py, 400    
 \#u{1B}[2m│\#u{1B}[0m   rows per batch) now spends 71% of its time         
 \#u{1B}[2m│\#u{1B}[0m   re-reading the same vendor table, and the cache    
 \#u{1B}[2m│\#u{1B}[0m   that would fix it doubles peak memory to about 3.2 
 \#u{1B}[2m│\#u{1B}[0m   GB on the smallest worker. Batching the vendor     
 \#u{1B}[2m│\#u{1B}[0m   reads keeps memory flat but only saves about a     
 \#u{1B}[2m│\#u{1B}[0m   third of the time, and it changes the order the    
 \#u{1B}[2m│\#u{1B}[0m   audit log sees. Which one should I try first,      
 \#u{1B}[2m│\#u{1B}[0m   keeping the audit order stable?                    
   \#u{1B}[38;5;114m→ Batch the vendor reads\#u{1B}[39m                             
 \#u{1B}[2m│\#u{1B}[0m ● The release branch test suite passes on            
 \#u{1B}[2m│\#u{1B}[0m   release/2026-09-ledger (tip 4c1e9a7b2). All 14     
 \#u{1B}[2m│\#u{1B}[0m   suites pass, the parity audit reports 0 failures,  
 \#u{1B}[2m│\#u{1B}[0m   and the output is identical to the current main.   
 \#u{1B}[2m│\#u{1B}[0m   Fast-forward main to it now?                       
   \#u{1B}[38;5;114m→ Fast-forward\#u{1B}[39m                                       
 \#u{1B}[2m│\#u{1B}[0m ● Open item from the last round: a vendor payment is 
 \#u{1B}[2m│\#u{1B}[0m   checked for currency, limits and funds, but not for
 \#u{1B}[2m│\#u{1B}[0m   the holiday calendar. A payment due on a bank      
 \#u{1B}[2m│\#u{1B}[0m   holiday reads settle_early=true, then gets dropped 
 \#u{1B}[2m│\#u{1B}[0m   when the batch closes at the cut-off. Both ledgers 
 \#u{1B}[2m│\#u{1B}[0m   agree, so parity holds, but the published total is 
 \#u{1B}[2m│\#u{1B}[0m   optimistic. Fix it?                                
   \#u{1B}[38;5;114m→ can payments settle a day late?\#u{1B}[39m                    
 \#u{1B}[2m│\#u{1B}[0m ● If the fast-forward goes wrong, should the rollback
 \#u{1B}[2m│\#u{1B}[0m   restore the previous main tip and replay the three 
 \#u{1B}[2m│\#u{1B}[0m   ledger migrations in reverse, or keep main and     
 \#u{1B}[2m│\#u{1B}[0m   ship a revert commit? Replaying takes about twenty 
 \#u{1B}[2m│\#u{1B}[0m   minutes and needs the ledger writer stopped; a     
 \#u{1B}[2m│\#u{1B}[0m   revert commit is instant but leaves the migrations 
 \#u{1B}[2m│\#u{1B}[0m   applied until the next release, which the parity   
 \#u{1B}[2m│\#u{1B}[0m   audit would then flag every night.                 
   \#u{1B}[38;5;114m→ Revert commit\#u{1B}[39m                                      
                            
\#u{1B}[38;5;246mReady to submit your answers?\#u{1B}[39m                           

\#u{1B}[38;5;153m❯\#u{1B}[39m \#u{1B}[38;5;246m1. \#u{1B}[38;5;153mSubmit answers\#u{1B}[39m         
  \#u{1B}[38;5;246m2. \#u{1B}[39mCancel   
"""#)
    static let claudeReviewScrolledShort = Fixture(cursorRow: 28, cursorVisible: false, text: #"""
 \#u{1B}[2m│\#u{1B}[0m   keeping the audit order stable?                    
   \#u{1B}[38;5;114m→ Batch the vendor reads\#u{1B}[39m                             
 \#u{1B}[2m│\#u{1B}[0m ● The release branch test suite passes on            
 \#u{1B}[2m│\#u{1B}[0m   release/2026-09-ledger (tip 4c1e9a7b2). All 14     
 \#u{1B}[2m│\#u{1B}[0m   suites pass, the parity audit reports 0 failures,  
 \#u{1B}[2m│\#u{1B}[0m   and the output is identical to the current main.   
 \#u{1B}[2m│\#u{1B}[0m   Fast-forward main to it now?                       
   \#u{1B}[38;5;114m→ Fast-forward\#u{1B}[39m                                       
 \#u{1B}[2m│\#u{1B}[0m ● Open item from the last round: a vendor payment is 
 \#u{1B}[2m│\#u{1B}[0m   checked for currency, limits and funds, but not for
 \#u{1B}[2m│\#u{1B}[0m   the holiday calendar. A payment due on a bank      
 \#u{1B}[2m│\#u{1B}[0m   holiday reads settle_early=true, then gets dropped 
 \#u{1B}[2m│\#u{1B}[0m   when the batch closes at the cut-off. Both ledgers 
 \#u{1B}[2m│\#u{1B}[0m   agree, so parity holds, but the published total is 
 \#u{1B}[2m│\#u{1B}[0m   optimistic. Fix it?                                
   \#u{1B}[38;5;114m→ can payments settle a day late?\#u{1B}[39m                    
 \#u{1B}[2m│\#u{1B}[0m ● If the fast-forward goes wrong, should the rollback
 \#u{1B}[2m│\#u{1B}[0m   restore the previous main tip and replay the three 
 \#u{1B}[2m│\#u{1B}[0m   ledger migrations in reverse, or keep main and     
 \#u{1B}[2m│\#u{1B}[0m   ship a revert commit? Replaying takes about twenty 
 \#u{1B}[2m│\#u{1B}[0m   minutes and needs the ledger writer stopped; a     
 \#u{1B}[2m│\#u{1B}[0m   revert commit is instant but leaves the migrations 
 \#u{1B}[2m│\#u{1B}[0m   applied until the next release, which the parity   
 \#u{1B}[2m│\#u{1B}[0m   audit would then flag every night.                 
   \#u{1B}[38;5;114m→ Revert commit\#u{1B}[39m                                      
                            
\#u{1B}[38;5;246mReady to submit your answers?\#u{1B}[39m                           

\#u{1B}[38;5;153m❯\#u{1B}[39m \#u{1B}[38;5;246m1. \#u{1B}[38;5;153mSubmit answers\#u{1B}[39m         
  \#u{1B}[38;5;246m2. \#u{1B}[39mCancel   
"""#)
    static let kimiReviewTallPhone = Fixture(cursorRow: 47, cursorVisible: false, text: #"""
 \#u{1B}[1m\#u{1B}[38;5;222m✨ SCRIPT:ask1\#u{1B}[0m                                         
              
 \#u{1B}[38;5;114m● \#u{1B}[1m\#u{1B}[38;5;111mCollected your answers\#u{1B}[0m   
   \#u{1B}[2mQ\#u{1B}[0m  Which database should the service use for the new 
 ledger?                                                
   \#u{1B}[38;5;111m→\#u{1B}[39m  Postgres                                          
              
 \#u{1B}[38;5;253m● \#u{1B}[39mTool result: {"answers":{"Which database should the  
   service use for the new ledger?":"Postgres"}}        
              
 \#u{1B}[1m\#u{1B}[38;5;222m✨ SCRIPT:askreview\#u{1B}[0m                                    
 \#u{1B}[38;5;111m──────────────────────────────────────────────────────\#u{1B}[39m 
 \#u{1B}[1m\#u{1B}[38;5;111m question\#u{1B}[0m    
              
  \#u{1B}[38;5;114m(✓) Import lever\#u{1B}[39m  \#u{1B}[38;5;114m(✓) Release\#u{1B}[39m  \#u{1B}[38;5;114m(✓) Audit check\#u{1B}[39m  \#u{1B}[1m\#u{1B}[38;5;253m\#u{1B}[48;5;111m S\#u{1B}[0m... 
              
 \#u{1B}[1m\#u{1B}[38;5;253m Review your answer before submit\#u{1B}[0m                      
              
   \#u{1B}[38;5;244mQ\#u{1B}[39m  Which lever should the importer try first? The    
        nightly import now spends 71% of its time       
        re-reading the same vendor table, and the cache 
        that would fix it doubles peak memory to about  
        3.2 GB on the smallest worker. Batching the     
        vendor reads keeps memory flat but only saves   
        about a third of the time. Which one should I   
        try first?          
   \#u{1B}[38;5;111m→\#u{1B}[39m  \#u{1B}[38;5;253mBatch the vendor reads\#u{1B}[39m                            
   \#u{1B}[38;5;244mQ\#u{1B}[39m  The release branch test suite passes on           
        release/2026-09-ledger. All 14 suites pass and  
        the parity audit reports 0 failures.            
        Fast-forward main to it now?                    
   \#u{1B}[38;5;111m→\#u{1B}[39m  \#u{1B}[38;5;253mFast-forward\#u{1B}[39m          
   \#u{1B}[38;5;244mQ\#u{1B}[39m  A vendor payment is checked for currency,         
        limits and funds, but not for the holiday       
        calendar, so a payment due on a bank holiday is 
        dropped at the cut-off. Both ledgers agree, but 
        the published total is optimistic. Fix it?      
   \#u{1B}[38;5;111m→\#u{1B}[39m  \#u{1B}[38;5;253mLog it\#u{1B}[39m  
              
 \#u{1B}[38;5;253m Ready to submit your answers?\#u{1B}[39m                         
              
 \#u{1B}[38;5;111m  → [1] Submit\#u{1B}[39m             
 \#u{1B}[38;5;244m    [2] Cancel\#u{1B}[39m             
              
 \#u{1B}[38;5;244m  ↑↓ select  1/2 choose  ↵ confirm  ←/→/tab switch \#u{1B}[39m... 
 \#u{1B}[38;5;111m──────────────────────────────────────────────────────\#u{1B}[39m 
 \#u{1B}[38;5;253mMock\#u{1B}[39m  \#u{1B}[38;5;244m…/dev/ki\#u{1B}[39m… 
                                  \#u{1B}[38;5;253mcontext: 1% (15/256k)\#u{1B}[39m 
"""#)
    static let kimiReviewScrolledPhone = Fixture(cursorRow: 47, cursorVisible: false, text: #"""
              
 \#u{1B}[1m\#u{1B}[38;5;253m Review your answer before submit\#u{1B}[0m                      
              
   \#u{1B}[38;5;244mQ\#u{1B}[39m  Which lever should the importer try first? The    
        nightly import (src/…/import/ledger_job.py, 400 
        rows per batch) now spends 71% of its time      
        re-reading the same vendor table, and the cache 
        that would fix it doubles peak memory to about  
        3.2 GB on the smallest worker. Batching the     
        vendor reads keeps memory flat but only saves   
        about a third of the time, and it changes the   
        order the audit log sees. Which one should I    
        try first, keeping the audit order stable?      
   \#u{1B}[38;5;111m→\#u{1B}[39m  \#u{1B}[38;5;253mBatch the vendor reads\#u{1B}[39m                            
   \#u{1B}[38;5;244mQ\#u{1B}[39m  The release branch test suite passes on           
        release/2026-09-ledger (tip 4c1e9a7b2). All 14  
        suites pass, the parity audit reports 0         
        failures, and the output is identical to the    
        current main. Fast-forward main to it now?      
   \#u{1B}[38;5;111m→\#u{1B}[39m  \#u{1B}[38;5;253mFast-forward\#u{1B}[39m          
   \#u{1B}[38;5;244mQ\#u{1B}[39m  Open item from the last round: a vendor payment   
        is checked for currency, limits and funds, but  
        not for the holiday calendar. A payment due on  
        a bank holiday reads settle_early=true, then    
        gets dropped when the batch closes at the       
        cut-off. Both ledgers agree, so parity holds,   
        but the published total is optimistic. Fix it?  
   \#u{1B}[38;5;111m→\#u{1B}[39m  \#u{1B}[38;5;253mLog it\#u{1B}[39m  
   \#u{1B}[38;5;244mQ\#u{1B}[39m  If the fast-forward goes wrong, should the        
        rollback restore the previous main tip and      
        replay the three ledger migrations in reverse,  
        or keep main and ship a revert commit?          
        Replaying takes about twenty minutes and needs  
        the ledger writer stopped; a revert commit is   
        instant but leaves the migrations applied until 
        the next release, which the parity audit would  
        then flag nightly.  
   \#u{1B}[38;5;111m→\#u{1B}[39m  \#u{1B}[38;5;253mRevert commit\#u{1B}[39m         
              
 \#u{1B}[38;5;253m Ready to submit your answers?\#u{1B}[39m                         
              
 \#u{1B}[38;5;111m  → [1] Submit\#u{1B}[39m             
 \#u{1B}[38;5;244m    [2] Cancel\#u{1B}[39m             
              
 \#u{1B}[38;5;244m  ↑↓ select  1/2 choose  ↵ confirm  ←/→/tab switch \#u{1B}[39m... 
 \#u{1B}[38;5;111m──────────────────────────────────────────────────────\#u{1B}[39m 
 \#u{1B}[38;5;253mMock\#u{1B}[39m  \#u{1B}[38;5;244m…/dev/ki\#u{1B}[39m… 
                                  \#u{1B}[38;5;253mcontext: 1% (15/256k)\#u{1B}[39m 
"""#)

    static let all: [(name: String, fixture: Fixture)] = [
        ("claudeAskWidePhone", claudeAskWidePhone),
        ("claudeAskWideNarrow", claudeAskWideNarrow),
        ("claudeAskWideShortPane", claudeAskWideShortPane),
        ("codexRuiPhone", codexRuiPhone),
        ("kimiAskPhone", kimiAskPhone),
        ("kimiReviewElidedPhone", kimiReviewElidedPhone),
        ("claudeReviewTallPhone", claudeReviewTallPhone),
        ("claudeReviewTallerPhone", claudeReviewTallerPhone),
        ("claudeReviewScrolledShort", claudeReviewScrolledShort),
        ("kimiReviewTallPhone", kimiReviewTallPhone),
        ("kimiReviewScrolledPhone", kimiReviewScrolledPhone),
        ("claudeAskSingle", claudeAskSingle),
        ("claudeAskSingleTypeFocused", claudeAskSingleTypeFocused),
        ("claudeAskSingleTyped", claudeAskSingleTyped),
        ("claudeAskChatSelected", claudeAskChatSelected),
        ("claudeAskAfterEsc", claudeAskAfterEsc),
        ("claudePermBash", claudePermBash),
        ("claudePermWrite", claudePermWrite),
        ("claudePlanApproval", claudePlanApproval),
        ("claudeAsk3Q1", claudeAsk3Q1),
        ("claudeAsk3Q2Multi", claudeAsk3Q2Multi),
        ("claudeAsk3Q2Toggled", claudeAsk3Q2Toggled),
        ("claudeAsk3Q2Row4Typed", claudeAsk3Q2Row4Typed),
        ("claudeAsk3Review", claudeAsk3Review),
        ("codexAsync2Collapsed", codexAsync2Collapsed),
        ("codexAsyncCountdown", codexAsyncCountdown),
        ("codexAsync2OpenQ1", codexAsync2OpenQ1),
        ("codexAsync2AfterQ1", codexAsync2AfterQ1),
        ("codexAsync2Q2Typed", codexAsync2Q2Typed),
        ("codexAsync2Done", codexAsync2Done),
        ("codexAsync1Open", codexAsync1Open),
        ("codexAsync1OtherFocused", codexAsync1OtherFocused),
        ("codexAsync1OtherTyped", codexAsync1OtherTyped),
        ("codexRuiPlan", codexRuiPlan),
        ("codexRuiNotesOpen", codexRuiNotesOpen),
        ("codexRuiNotesTyped", codexRuiNotesTyped),
        ("codexRuiAfter2", codexRuiAfter2),
        ("codexExecApproval", codexExecApproval),
        ("kimiAskSingle", kimiAskSingle),
        ("kimiAskAfter2", kimiAskAfter2),
        ("kimiAsk2", kimiAsk2),
        ("kimiAsk2Multi", kimiAsk2Multi),
        ("kimiAsk2MultiToggled", kimiAsk2MultiToggled),
        ("kimiAsk2Review", kimiAsk2Review),
        ("kimiOtherFocused", kimiOtherFocused),
        ("kimiOtherTyped", kimiOtherTyped),
        ("kimiBash", kimiBash),
        ("kimiAskbg", kimiAskbg),
        ("kimiReviewAfter1", kimiReviewAfter1),
    ]

    struct Fixture {
        let cursorRow: Int?
        let cursorVisible: Bool
        let text: String
        var cursorLine: String? {
            let rows = text.components(separatedBy: "\n")
            return cursorRow.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
        }
    }
}
