# custom/

Your own changes live here, and `make update` never touches them (everything in this folder except
this file is git-ignored).

- `office.css`: extra CSS for the Office tab. If the file exists, the dashboard loads it after the
  built-in `dashboard/office.css`, so your rules win. Reload the Office tab to see changes.
- `office-cast.js`: your own look for the agent characters (colours or the whole pixel grid). The
  Office and the dictation pill at the bottom of the screen both use it, so they always match.

See docs/CUSTOMIZING.md for an example.
