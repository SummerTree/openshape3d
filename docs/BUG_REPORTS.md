# In-app bug reports

The ladybug button at the right end of the editor toolbar (and "Report a
Bug…" under the gallery's ⋯ menu) opens a form: summary, what happened,
steps, optional email, and in the editor a toggle to attach the open design
as an `.os3d` archive. Send writes one document to the Firestore collection
`bugReports` and, when attached, one object to Cloud Storage under
`bugReports/<reportID>/<name>.os3d`.

## What ships in the app

No Firebase SDK. `openshape3d/App/BugReporting.swift` makes two plain
HTTPS calls to the Firestore and Cloud Storage REST APIs. There is no
analytics, crash reporting, or device identifier of any kind; nothing
leaves the device until the user presses Send, and the form's footer lists
exactly what goes along:

| Field | Source |
|---|---|
| `title`, `details`, `steps`, `contactEmail` | typed by the user (trimmed) |
| `createdAt`, `status: "new"`, `reportID` | set at send time |
| `context.appVersion`, `context.build` | `CFBundleShortVersionString` / `CFBundleVersion` |
| `context.osVersion`, `context.deviceModel` | `UIDevice` (e.g. "iOS 26.0", "iPad") |
| `context.documentName`, `bodyCount`, `featureCount`, `lastAction` | the open design (editor only) |
| `attachment.path`, `attachment.bytes` | when the design was attached |
| `attachmentError` | when an attachment was requested but could not be uploaded (report still filed) |

Attachments are capped at 40 MB (`BugAttachment.maxBytes`); a larger design
is refused with a message before anything uploads.

## Configuration (not in git)

The reporter reads three keys — `API_KEY`, `PROJECT_ID`, `STORAGE_BUCKET` —
from `openshape3d/GoogleService-Info.plist`, which is **git-ignored**. Copy
`docs/GoogleService-Info.example.plist` there and fill it in from the
Firebase console (Project settings → Your apps → the iOS app's plist). The
file sits in the app target's synchronized folder, so Xcode bundles it
automatically. A build without it still shows the button; the sheet then
says reporting isn't configured and Send stays disabled
(`FirebaseConfig.bundled == nil`). The placeholder values in the example
are rejected on purpose, so a copied-but-unedited example also reads as
"not configured".

The web API key is not a secret in the usual sense (it identifies the
project; Firebase security rules do the gating) but it is still kept out of
the repository as asked.

## One-time Firebase setup (project owner)

Done on 2026-09-05: Firestore and Storage are both provisioned for
`openshape3d`, and a report sent from the simulator landed end to end
(document `81c8c1d7-8d09-44ba-9ae3-2bb9247e3c41` with a 27 KB `.os3d` in
the bucket). Two probe artifacts are labeled "safe to delete": Firestore
document `curl-probe-safe-to-delete` and Storage object
`bugReports/curl-probe/probe.txt`.

**Open item — lock the rules down.** During that check an unauthenticated
client could also *list* the `bugReports` collection and the bucket
prefix, which means anyone holding the app's API key can read every
report, including contact emails and attached designs. Publish the
create-only rules below (Firestore → Rules, Storage → Rules) before the
build reaches anyone else.

For a fresh project the steps are: Firestore Database → Create database
(Native mode), Storage → Get started (Blaze plan), then paste the rules.
If only Firestore is set up, reports still arrive: a failed upload is
recorded in the document's `attachmentError` and the sender is told the
design was not attached.

## Firebase rules the reporter needs

The app writes as an unauthenticated client, so the rules must allow
*create only* on the collection and the attachment prefix — never read,
update or delete:

```
// Firestore
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /bugReports/{reportID} {
      allow create: if request.resource.data.keys().hasAll(['title', 'createdAt', 'status'])
                    && request.resource.data.title is string
                    && request.resource.data.title.size() <= 200
                    && request.resource.data.details.size() <= 20000
                    && request.resource.data.status == 'new';
      allow read, update, delete: if false;
    }
  }
}

// Cloud Storage
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /bugReports/{reportID}/{fileName} {
      allow create: if request.resource.size < 40 * 1024 * 1024
                    && request.resource.contentType == 'application/octet-stream';
      allow read, update, delete: if false;
    }
  }
}
```

Reports are then read in the Firebase console (Firestore → `bugReports`,
sorted by `createdAt`); an attachment's `path` is its object in Storage.

## Verifying

- `BugReportingTests` covers config parsing, the Firestore document shape
  (integers as decimal strings, RFC 3339 timestamps, optional context and
  attachment maps), attachment-path sanitising, and server-error extraction.
- `BugReportUITests` opens the sheet from the toolbar, checks Send is
  disabled until a summary is typed, that the attach toggle is offered in
  the editor, and cancels. It never presses Send.
- A real send is a manual check: fill the form on the simulator, press
  Send, and confirm the document (and object) appear in the console. The
  success alert shows the report ID, which is also the document ID.
