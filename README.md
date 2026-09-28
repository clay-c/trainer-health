# Trainer Health

iPhone app for logging weigh-ins, workouts, and meals, copying stored rows into Apple Health, and building a doctor-visit prompt from Apple Health.

The ledger address, token, and Telegram bot username are typed into the app on the phone. They are not in this repository. Shortcuts use the stored address. They do not take an address as a parameter.

An example address, not a real server, is `https://ledger.example`.

## What the app does

- Today shows the current plan, a weigh-in, a note to the trainer, and Open in Telegram.
- A meal can be a plate photo, a nutrition-label photo, a short estimate, or any mix.
- When the ledger cannot be reached, weigh-ins, workouts, and meals stay on the phone and a count stays on screen until they upload. Notes are not queued.
- Apple Health is updated from rows already stored, and only while the ledger is reachable.
- Doctor visit reads Apple Health for the dates you pick, shows you the prompt, and shares it to Gemini or any other installed app. This app does not call those model APIs.

## Signing

Team ID belongs in the GitHub Actions variable `APPLE_TEAM_ID`.

Repository secrets, pasted into GitHub and not into git:

- `BUILD_CERTIFICATE_BASE64`
- `BUILD_CERTIFICATE_PASSWORD`
- `BUILD_PROVISION_PROFILE_BASE64` (profile name `Trainer Health App Store`, bundle id `me.ycross.trainer-health`)
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_P8`

Every push builds an unsigned simulator app. TestFlight upload is the manually run `testflight` workflow, after those secrets exist and the bundle id has the HealthKit capability in the developer portal.

The distribution certificate can be made without a Mac: create a key and CSR with `openssl`, upload the CSR as an Apple Distribution certificate, and turn the result into the `.p12` secret. The private key stays out of git.
