# Cloud setup

This monitor is prepared for GitHub Actions and runs at 22:00 UTC every
Tuesday, equivalent to 08:00 AEST Wednesday (fixed UTC+10).

Repository requirements:

1. Create a private GitHub repository.
2. Add all files in this directory, preserving `.github/workflows/aldi-market-update.yml`.
3. In repository **Settings > Secrets and variables > Actions**, create the
   encrypted repository secret `GMAIL_APP_PASSWORD` using the current Google
   app password.
4. In **Actions**, manually run **Aldi Sauces Market Update** once to verify it.

The workflow sends no email when there are no detected changes. A successful
run commits the refreshed `baseline.json`; a failed email does not advance the
baseline.

