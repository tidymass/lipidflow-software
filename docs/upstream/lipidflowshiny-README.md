# LipidFlow Shiny App

A web-based (R Shiny) tool for untargeted lipidomics: peak picking, lipid annotation, and absolute quantification from raw LC-MS data, in one guided browser workflow.

It is built on top of [`jaspershen/lipidflow`](https://github.com/jaspershen/lipidflow) and [`tidymass/massprocesser`](https://github.com/tidymass/massprocesser). This repo is a plain Shiny app (not an R package) — the original package's logic was reorganized into `mod_*`/`utils_*` files under `R/`, with content preserved verbatim.

## Install and make changes to the shiny
### Step 1 — Install the required software

You need three things installed on your computer:

1. **Git** — the tool that talks to GitHub.
   - Mac: open the **Terminal** app (search for it with Spotlight, `Cmd + Space`) and type `git --version`, then press Enter. If it's not installed, macOS will prompt you to install the "Command Line Developer Tools" — click Install.
   - Windows: download and install it from https://git-scm.com/downloads. This also installs "Git Bash", a terminal app you'll use below.
2. **R** — download and install from https://cran.r-project.org (pick "Download R for macOS" or "Download R for Windows").
3. **RStudio Desktop** — download and install the free version from https://posit.co/download/rstudio-desktop/.

### Step 2 — Connect your computer to GitHub with SSH

SSH is how your computer proves to GitHub "this is really me" without typing a password every time. You generate a pair of keys once, keep one half secret on your computer, and give GitHub the other (public) half.

1. Open a terminal (**Terminal** on Mac, **Git Bash** on Windows).
2. Generate a key pair — replace the email with the one you used for GitHub:
   ```bash
   ssh-keygen -t ed25519 -C "your_email@example.com"
   ```
   Press Enter to accept the default file location, and press Enter twice more to skip setting a passphrase (or set one if you prefer — you'll just need to remember it).
3. Start the SSH agent and add your new key to it:
   ```bash
   eval "$(ssh-agent -s)"
   ssh-add ~/.ssh/id_ed25519
   ```
4. Copy your **public** key to the clipboard:
   - Mac: `pbcopy < ~/.ssh/id_ed25519.pub`
   - Windows (Git Bash): `cat ~/.ssh/id_ed25519.pub | clip`
5. On GitHub, go to **Settings** (click your profile picture, top right) → **SSH and GPG keys** → **New SSH key**. Give it any title (e.g. "My Laptop"), paste the key into the "Key" box, and click **Add SSH key**.
6. Test the connection:
   ```bash
   ssh -T git@github.com
   ```
   Type `yes` if asked whether to continue connecting. You should see a message like `Hi <your-username>! You've successfully authenticated...`.

### Step 3 — Clone the repository from RStudio

"Cloning" downloads a full copy of the project, linked back to GitHub so you can pull updates and push your own changes later. RStudio can do this for you directly:

1. Open RStudio.
2. Go to **File → New Project…**
3. Choose **Version Control**, then choose **Git**.
4. In **Repository URL**, paste:
   ```
   git@github.com:jaspershen-lab/lipidflowshiny.git
   ```
5. The **Project directory name** field will auto-fill as `lipidflowshiny`. Under **Create project as subdirectory of**, click **Browse…** and pick where you want the project folder to live (e.g. your Documents folder).
6. Click **Create Project**. RStudio will clone the repository and reopen itself with the project already loaded — you'll see the file list (`app.R`, `R/`, `www/`, etc.) in the bottom-right panel.

### Step 4 — Install the R packages the app needs

In RStudio's **Console** panel (bottom-left), paste and run:

```r
install.packages(c(
  "shiny", "bslib", "shinyjs", "DT", "reactable", "htmltools",
  "readxl", "readr", "openxlsx", "callr", "ps", "zip",
  "dplyr", "tidyr", "purrr", "plotly", "htmlwidgets",
  "ggplot2", "patchwork"
))

if (!requireNamespace("BiocManager", quietly = TRUE)) install.packages("BiocManager")
BiocManager::install(c("MSnbase", "xcms"))

if (!requireNamespace("remotes", quietly = TRUE)) install.packages("remotes")
remotes::install_github("tidymass/massdataset")
remotes::install_github("tidymass/massprocesser")
remotes::install_github("tidymass/metid")
remotes::install_github("jaspershen/lipidflow")
```

This can take a while the first time (several minutes) — that's normal. You only need to do this once per computer (RStudio will remember the installed packages the next time you open the project).

### Step 5 — Run the app

In RStudio's **Console** panel (bottom-left), type the following command and press Enter:

```r
shiny::runApp(".")
```

The app will open in a new window (or your browser). When you're done, click the red **Stop** icon at the top of the Console (or press `Esc` in the Console) to stop the app before making further code changes.

### Step 6 — Make changes and save them back to GitHub

**Every time you make a change, push it back to GitHub right away** — don't let changes sit only on your own computer. Otherwise your edits can be lost, or conflict with someone else's work later.

1. Edit any file (e.g. something in `R/`) directly in RStudio's editor, then save with `Cmd/Ctrl + S`.
2. Re-run the app (Step 5) to check your change works.
3. Open a terminal in the project folder — in RStudio, use the **Terminal** tab next to the Console (bottom-left panel) — and run these three commands, in order:
   ```bash
   git add .
   git commit -m "describe what you changed here"
   git push
   ```
   - `git add .` stages every file you changed.
   - `git commit -m "..."` saves those staged changes as a checkpoint, with a short message describing what you did (write your own message between the quotes, e.g. `"fix quantification bug"`).
   - `git push` sends the checkpoint to GitHub so everyone else can see it.
4. Repeat these three commands after every meaningful change — don't wait until the end of the day to push.

If `git push` is rejected because there are newer changes on GitHub, run `git pull` first to bring those changes into your copy, then run `git push` again.


## Authors of lipidflowshiny

- Do Ha Lan (https://github.com/helencutie31)
- Radhakrishnan Sivani (https://github.com/sivaniradh-bit)
- Liu Yijiang (https://github.com/ejoliu)
