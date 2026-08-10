# Windows Workstation Setup

A PowerShell script that provisions a fresh Windows machine for development — installs core dev tools, restores your VS Code settings and extensions from an exported profile, and sets up Flutter.

## What's included

| File | Purpose |
|---|---|
| `setup-workstation.ps1` | The setup script |
| `*.code-profile` | Your own exported VS Code profile (see below — not included in this repo) |

> **Note:** VS Code profiles are personal — they hold your settings, keybinding tweaks, and extension list. This repo intentionally does **not** ship one, and `.code-profile` files are gitignored. Export your own before running the script.

## What the script installs

- **Git** (via winget)
- **NVM for Windows** + **Node.js LTS**
- **Flutter SDK** (stable branch, cloned to `C:\flutter`)
- **Visual Studio Code**
- Your VS Code **settings.json** (restored from your profile)
- Every **VS Code extension** listed in your profile
- Optional: **Figma**, **Android Studio** (asks y/N during the run)

## Prerequisites

- Windows 10/11 with `winget` available (comes preinstalled on modern Windows; if missing, install "App Installer" from the Microsoft Store)
- Administrator access
- Internet connection

## Setup steps

### 1. Export your VS Code profile

On a machine you've already configured, open VS Code and go to:

**Gear icon (bottom-left) → Profiles → Export Profile…** → save to file.

You'll get a file like `my-profile.code-profile`. Name it whatever you like — the script picks up any `*.code-profile` file sitting next to it.

If you're starting from scratch and have no profile to export, you can skip this step, but the script will exit with an error — it needs a profile to restore.

### 2. Put both files in one folder

Clone this repo (or download the script), and place your exported profile alongside it:

```
📁 setup/
├── setup-workstation.ps1
└── my-profile.code-profile
```

### 3. Open PowerShell as Administrator

Click **Start**, type `PowerShell`, right-click **Windows PowerShell**, choose **Run as administrator**.

Admin rights are required because `winget` installs software system-wide.

### 4. Navigate to the folder

```powershell
cd "$HOME\Desktop\setup"
```

Adjust the path to wherever you actually saved the files.

### 5. Allow the script to run (one-time, per session)

Windows blocks unsigned scripts by default. This only affects the current PowerShell window, not your system permanently:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### 6. Run the script

```powershell
.\setup-workstation.ps1
```

You'll see:
- The profile it picked up, printed at the top
- Package installs run one after another (Git → NVM → Node LTS → Flutter → VS Code)
- `winget` may show its own one-time source-agreement prompts — accept them if they appear
- VS Code settings get backed up (if any existed) before being overwritten
- Extensions install with per-extension status output
- Two y/N prompts at the end for Figma and Android Studio

### 7. Restart your terminal

Close the PowerShell window and open a new one so PATH changes (Flutter, Node, VS Code CLI) take effect.

Then verify Flutter:

```powershell
flutter doctor
```

## How the VS Code profile is structured

`.code-profile` files are valid JSON, but nested multiple layers deep as JSON-encoded strings — this is standard for any VS Code "Export Profile" output, not something specific to this setup:

```
my-profile.code-profile
├── name
├── settings   → string → { "settings": "<json string>" } → { <actual settings.json keys> }
├── extensions → string → [ { "identifier": { "id": ... }, "displayName": ... }, ... ]
└── globalState → string → UI/panel state (not used by the script)
```

The script unwraps this automatically — no manual editing of the profile needed.

## Troubleshooting

| Issue | Fix |
|---|---|
| `No '*.code-profile' file found` | Export a profile from VS Code (step 1) and save it in the same folder as the script |
| Wrong profile picked up | The script uses the first `.code-profile` it finds and warns if there are several — remove the extras |
| `code` command not recognized | Open a new terminal after VS Code installs, then re-run just the extensions step |
| `nvm`/`node` not recognized after install | Open a new terminal and run `nvm install lts` then `nvm use lts` manually |
| A `winget install` step fails | Note the exit code shown, re-run `winget install -e --id <PackageId>` manually to see the full error |
| Script won't run at all | Make sure you ran `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` in that same window first |

## Notes

- Flutter is hardcoded to install at `C:\flutter` on the stable branch. Edit the script if you want it elsewhere.
- Existing `settings.json` is backed up (timestamped `.bak` file) before being overwritten, so nothing is lost.
- The script is safe to re-run — it skips steps that are already done (e.g. won't re-clone Flutter if the folder exists).

## Customizing

The tool list lives in the script as plain `Install-WingetPackage` calls — add or remove lines to fit your own stack. Extensions are driven entirely by your profile, so change those in VS Code and re-export rather than editing the script.
