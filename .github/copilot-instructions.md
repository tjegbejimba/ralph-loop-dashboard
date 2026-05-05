# Copilot instructions

## Ralph Loop

This repo is the source checkout for Ralph Loop. If an agent needs to understand, install, refresh, operate, or troubleshoot Ralph in this repo or another local repo, load the `ralph-loop` skill.

Key local facts:

- Ralph source checkout: `/Users/tjegbejimba/Code/ralph-loop-dashboard`
- Repo worker prompt: `.ralph/RALPH.md` in each target repo
- Repo config: `.ralph/config.json` in each target repo
- Refresh another repo's Ralph scripts with `./install.sh /path/to/repo --scripts-only`
- Refresh scripts plus the global dashboard extension with `./install.sh /path/to/repo --both`
- Check, stop, or clean workers with `/path/to/repo/.ralph/launch.sh --status`, `--stop`, or `--cleanup`

Do not overwrite a target repo's `.ralph/RALPH.md` or `.ralph/config.json` unless explicitly asked.
