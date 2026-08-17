# VideoNotes Privacy Policy

VideoNotes creates illustrated notes from media you select. Speech recognition, on-screen text recognition, source-frame selection, note structuring and illustration rendering run on your device. VideoNotes does not upload your source media or extracted content, and it does not include third-party analytics or advertising SDKs.

## Data stored on your device

To recover your current project after the app closes, VideoNotes saves a private local recovery copy containing the generated notes, transcript, recognized on-screen text, source-derived sketches, evidence timestamps, detected source-language metadata, display settings and a reference to the selected source file. It does **not** copy the source video or audio into that recovery file.

Recovery content is protected with AES-256-GCM authenticated encryption. Its randomly generated 256-bit key is stored separately in Apple Keychain as a device-bound, non-synchronizing item. The recovery folder is excluded from device backups, uses owner-only file permissions on macOS, and also uses iOS Data Protection where available. Copying the recovery file alone does not disclose its transcript, notes, sketches, bookmark or source path.

Selecting **Start New** deletes the current recovery copy and any quarantined unreadable copy before retiring its Keychain key. Because the key is device-bound and excluded from synchronization, an encrypted recovery file is not designed to move to another device. Exports are written only to locations you choose and remain there until you delete them.

When you choose a semantic export, VideoNotes derives it directly from the local typed note document; it does not require a rendered image or PDF. The versioned JSON format intentionally includes the document title, optional subtitle, detected language, source label, selected presentation identifier, evidence coverage and timestamps, review flags, source-derived sketch strokes and the complete typed content of every note section. Markdown, plain text and HTML contain readable representations of the same source-cited notes. These files are created only at the destination you select.

## Purchases and network use

Subscription products, purchases and restores are handled by Apple through StoreKit. Apple may process purchase information under Apple's own privacy policy. VideoNotes does not receive your full payment details.

The media-analysis pipeline requires on-device speech recognition and performs OCR, language classification, frame selection, grounding checks and rendering locally. StoreKit is the app's only service boundary; VideoNotes does not send lecture content through it.

VideoNotes does not sell or share personal information and does not collect analytics, advertising identifiers, lecture files, transcripts, recognized text or generated notes.

Contact: lukekevinmclaughlin@gmail.com

Effective: July 13, 2026.
