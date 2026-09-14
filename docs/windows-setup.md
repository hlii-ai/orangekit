# Installing on Windows

> Written click by click and copy-paste by copy-paste, so you can follow it without being a developer.
> It takes about 5 minutes.

## One-line summary

**To use this plugin properly on Windows you need one prerequisite — Git for Windows.**
Without it, the plugin's automatic guidance and automatic verification (the session-start briefing, the
feature that stops you from ending a session without building, and so on) **simply never run, silently, with
no error message.** This is the most common cause of "it installed but something feels off".

If you are on Mac or Linux you do not need this document — just go to the Quick Start in the
[README](../README.md).

---

## Which case am I?

Pick one of the following.

| I... | what to do |
| --- | --- |
| am new to Windows and do not even know what "WSL" is | go with **Method A** (install Git for Windows) |
| have used some development tools before (Git, VS Code, etc.) | go with **Method A** — the simplest and most common route |
| already have WSL (a Linux environment) installed and in use | go with **Method B** — keep doing exactly what you are doing |

If you cannot tell which to pick, pick **Method A**. It is the right choice for most Windows
users.

---

## Method A — Install Git for Windows (recommended)

### Step 1. Download

1. Open https://git-scm.com/downloads/win in your browser
2. Click the **"Click here to download"** button (the 64-bit version downloads automatically)
3. Run the downloaded `Git-x.xx.x-64-bit.exe`

### Step 2. Install

The setup wizard shows several screens. **Leave every screen at its default and just press "Next".**
There is nothing you need to change. At the end press "Install" → and "Finish" once it completes.

> Close to 10 screens appear, which can be alarming, but keeping every default is fine for using this
> plugin. If you want to know exactly what the tool does, looking it up later is soon enough.

### Step 3. Verify

1. Search for **"Git Bash"** in the Windows Start menu and run it — a terminal window with a black background opens
2. Type the command below and press Enter (copy it with the mouse → right-click in the window → paste)

```bash
bash --version
```

3. If text like `GNU bash, version ...` appears, it worked. If you get an error like
   `command not found`, the install did not take — go back and check Step 2.

---

## Installing jq (common to Methods A and B — required)

Git for Windows ships the terminal (`bash`) and the basic commands, but **`jq` (the tool for handling JSON)
that this plugin uses has to be installed separately.** (What exactly `jq` does is the same thing covered in
the [harness map Q&A](../README.md) — without it the install still works, but half of the plugin's
safety devices quietly switch off.)

The easiest route — open **plain PowerShell** (search "PowerShell" in the Start menu), not Git Bash,
and run:

```powershell
winget install jqlang.jq
```

On Windows 10 (updates from 2021 onward) and later, `winget` is already installed, so this one line is all
it takes. If you get an error saying `winget` does not exist, use the alternative below:

1. Open https://jqlang.org/download/
2. Download `jq-windows-amd64.exe` from the **Windows** section
3. Rename the file to `jq.exe` and copy it into the `C:\Windows\System32\` folder
   (if a "you need administrator permission" dialog appears while copying, click "Continue")

### Verify

In a Git Bash window:

```bash
jq --version
```

If a version like `jq-1.x.x` appears, it worked.

---

## Method B — Use WSL (if you already use WSL)

If you already run your development environment through WSL (Windows Subsystem for Linux), almost nothing
extra is needed. Inside WSL is a real Linux environment, so it behaves exactly as it does for Mac/Linux users.

1. Open your WSL terminal (Ubuntu, etc.)
2. Check whether `jq` is present:
   ```bash
   jq --version
   ```
3. If not, install it:
   ```bash
   sudo apt update && sudo apt install -y jq
   ```
4. Claude Code must also be installed and run **inside the WSL terminal** (use the `claude` command in the
   WSL window, not in PowerShell or CMD).

If you do not have WSL yet and still want it, open PowerShell as administrator, run `wsl --install`, and
reboot — but if this is your first time, **Method A** is far simpler.

---

## Installing Claude Code

Once the prerequisites are done, install Claude Code itself. Open **PowerShell** (or the WSL terminal if you
chose WSL) and run:

```powershell
irm https://claude.ai/install.ps1 | iex
```

When it finishes, type `claude` in any folder and check that the login screen appears.

---

## Installing the plugin

From here on it is identical to Mac/Linux — just follow the
[Quick Start in the README](../README.md#quick-start).

```
claude plugin install orangekit-product
```

---

## Final check that it worked

Run `claude` in the project folder you want to work in, and as soon as the session starts a notice reading
**"ORANGEKIT Operating Rules"** should appear on screen. If it does, the hooks are running correctly.

Checklist:

| what to check | how | if it is working |
| --- | --- | --- |
| Git Bash installed | `bash --version` in a Git Bash window | a version string is printed |
| jq installed | `jq --version` in the same window | `jq-1.x.x` is printed |
| Claude Code installed | `claude --version` in any terminal | a version number is printed |
| plugin hooks working | run `claude` in the project folder | the "ORANGEKIT Operating Rules" notice at session start |

---

## Warning signs — this is what a mismatched shell looks like

No error appears, but if any of the following applies, Git for Windows is missing or is not being
recognized (switching off silently with no error message is the signature of this problem).

- Starting a session never shows the **"ORANGEKIT Operating Rules"** notice
- You edit source code and try to end the session without building or testing, and **it just ends with no warning**
  (it is supposed to stop you)

In that case, work through this order:

1. Check that "Git Bash" shows up in Start menu search (if not, redo "Method A" above)
2. Check in Settings → Apps that "Git" is in the installed list
3. If it still fails, point at the Git Bash path directly in `%USERPROFILE%\.claude.json` or your settings
   file, like this (it is usually auto-detected, so the two steps above resolve most cases):
   ```json
   {
     "env": {
       "CLAUDE_CODE_GIT_BASH_PATH": "C:\\Program Files\\Git\\bin\\bash.exe"
     }
   }
   ```

---

## Further reading

- The technical grounds for why this plugin requires Git Bash on Windows are laid out with sources in
  [`docs/platform-contract.md`](platform-contract.md) §5.2.
- For general installation and usage, see the [README](../README.md).
