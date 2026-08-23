# VideoNotes Direct distribution

VideoNotes has two deliberately separate commercial editions:

- **App Store (`Release`)** — bundle ID `com.lukemclaughlin.videonotes`; StoreKit subscriptions, purchase restoration, and the daily free-analysis allowance remain available.
- **Website (`Direct`)** — bundle ID `com.lukemclaughlin.videonotes.direct`; one-time purchase, permanently unlocked, with StoreKit and subscription UI excluded at compile time.

Build the signed website edition with:

```sh
./scripts/build-direct.sh
```

Set `SKIP_NOTARIZATION=1` only for a local verification build. Production releases must use the `macossoftware-notary` keychain profile and pass notarization, stapling, and Gatekeeper assessment.
