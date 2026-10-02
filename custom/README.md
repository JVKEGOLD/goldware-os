# custom/

Your own changes live here, and `make update` never touches them (everything in this folder except
this file is git-ignored).

- `office.css`: extra CSS for the Office tab. If the file exists, the dashboard loads it after the
  built-in `dashboard/office.css`, so your rules win. Reload the Office tab to see changes.

See docs/CUSTOMIZING.md for an example.
