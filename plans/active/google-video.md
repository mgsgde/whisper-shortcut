# Google OAuth Verification Demo Video Plan

Google Cloud Console verification page: <https://console.cloud.google.com/auth/verification?project=whisper-shortcut>

Current demo video field: <https://youtu.be/72ezh1mnRPQ>

## Review Feedback To Address

Google rejected the current demo video for app functionality:

> The video you submitted does not sufficiently demonstrate the functionality of your application. Please provide a side-by-side comparison of the source Gmail and Calendar versus the app dashboard results.

The replacement video must clearly show:

- The complete OAuth grant flow in English.
- The OAuth consent screen with the WhisperShortcut app name.
- The browser address bar with the OAuth client ID visible.
- Side-by-side source data from Google Calendar, Gmail, and Google Tasks compared with the results shown in WhisperShortcut.
- A real demonstration of each requested sensitive or restricted scope.

## Requested Scopes

Sensitive scopes:

- `https://www.googleapis.com/auth/calendar.events`
  - Needed to list upcoming events and create or update events when the user asks.
  - `calendar.events.readonly` is not sufficient because creating events is a core feature.
- `https://www.googleapis.com/auth/tasks`
  - Needed to list, create, complete, and delete tasks when the user asks.
  - `tasks.readonly` is not sufficient because the app creates and updates tasks.

Restricted scope:

- `https://www.googleapis.com/auth/gmail.readonly`
  - Needed to search and read email messages so the assistant can answer user-requested email questions.
  - Metadata-only Gmail scopes are not sufficient because the assistant must read message content to summarize or answer questions.
  - The app must not show sending, deleting, labeling, or modifying Gmail messages.

## Recording Setup

Use a dedicated test Google account with harmless demo data. Do not use a personal inbox or calendar with private content.

Recommended screen layout:

- Left side: Google source product in the browser.
- Right side: WhisperShortcut chat window.
- Keep the browser address bar visible during OAuth and source-data checks.
- Record at 1080p or higher so Google can read the text.
- Upload the final video to YouTube as Unlisted, not Private.

Before recording, prepare these demo items:

- Calendar event for today: `Team Sync at 3:00 PM`.
- Calendar event for tomorrow: `Product Planning at 10:00 AM`.
- Gmail message from `demo@example.com` with subject `Project Update` and body text that includes: `The launch review is scheduled for Friday. Please prepare the checklist and send the final notes.`
- Open task: `Prepare weekly report`.
- Open task: `Review product checklist`.

## Next To-Dos

- [ ] Create or clean up a dedicated Google test account.
- [ ] Add the Calendar demo events listed above.
- [ ] Add or send the Gmail demo message listed above.
- [ ] Add the Google Tasks demo tasks listed above.
- [ ] Disconnect Google inside WhisperShortcut so the video can start from a clean OAuth flow.
- [ ] Open WhisperShortcut on the right side of the screen.
- [ ] Open Google Calendar, Gmail, and Google Tasks in browser tabs on the left side.
- [ ] Confirm the OAuth consent screen language is English.
- [ ] Confirm the OAuth consent screen shows the same scopes submitted in Google Cloud Console.
- [ ] Record the full demo in one continuous flow or with only minimal cuts.
- [ ] Upload to YouTube as Unlisted.
- [ ] Replace the YouTube link in Google Cloud Console.
- [ ] Reply directly to the Google Trust and Safety email thread with the new video link.

## Video Structure

Target length: 5 to 8 minutes.

### 1. Intro

Show WhisperShortcut and the Google source tabs.

Goal: Explain what the app does and what the video will prove.

### 2. OAuth Consent Flow

In WhisperShortcut:

1. Open the chat or settings area where Google is connected.
2. Click the Google connection action.
3. Show the browser OAuth flow.
4. Keep the consent screen visible long enough for Google to read:
   - App name.
   - Requested scopes.
   - OAuth client ID in the browser URL.
5. Approve access.
6. Return to WhisperShortcut and show the connected state.

### 3. Calendar Read

Left side: Google Calendar showing today's events.

Right side: WhisperShortcut.

Ask:

> What is on my calendar today?

Expected result:

- WhisperShortcut lists the same visible calendar events.
- The viewer can compare the Google Calendar source data and the app result side by side.

### 4. Calendar Create

Ask:

> Create a calendar event tomorrow at 4 PM called OAuth Verification Demo Review.

Then refresh or navigate Google Calendar on the left side and show the new event.

Expected result:

- The created event appears in Google Calendar.
- This demonstrates why `calendar.events` write access is needed.

### 5. Gmail Read-Only Search And Summary

Left side: Gmail with the demo message visible.

Right side: WhisperShortcut.

Ask:

> Find the latest email from <demo@example.com> and summarize it.

Expected result:

- WhisperShortcut finds the correct email and summarizes the visible message content.
- Do not show any Gmail write action.
- Explicitly say that Gmail access is read-only.

### 6. Tasks Read

Left side: Google Tasks with open tasks visible.

Right side: WhisperShortcut.

Ask:

> What are my open tasks?

Expected result:

- WhisperShortcut lists the same visible tasks.

### 7. Tasks Create And Complete

Ask:

> Add a task called Finish OAuth verification video.

Show the new task in Google Tasks.

Then ask:

> Mark Finish OAuth verification video as completed.

Show the task completed in Google Tasks.

Expected result:

- The task is created and then completed in Google Tasks.
- This demonstrates why the full Tasks scope is needed instead of read-only access.

### 8. Closing Explanation

End with a short explanation that access is user initiated and scope limited.

## Voiceover Transcript

Use this transcript while recording. It is written in English because the OAuth verification video should be understandable to Google's review team.

Legend:

- `[SAY]` means spoken voiceover. Read this out loud in the video.
- `[ACTION]` means recording instructions. Do not read this out loud.
- `[CHECK]` means something that must be visible on screen. Do not read this out loud unless it helps the recording.

### 1. Intro

`[ACTION]` Show WhisperShortcut on the right and the Google source tabs on the left.

`[SAY]`

> This video demonstrates the Google OAuth integration for WhisperShortcut, a macOS productivity app. WhisperShortcut lets users connect their Google account so they can ask the assistant to look up calendar events, manage tasks, and read email content when they explicitly request it.
>
> In this video I will show the complete OAuth consent flow, then demonstrate each requested scope with a side-by-side comparison. The Google source data is shown on the left, and the WhisperShortcut app result is shown on the right.

### 2. OAuth Consent Flow

`[ACTION]` Start with Google disconnected in WhisperShortcut. Click the Google connection action in the app.

`[SAY]`

> I am starting from WhisperShortcut with Google not connected. I will now connect a Google account from inside the app.

`[ACTION]` When the browser opens, keep the OAuth consent screen visible long enough for review.

`[CHECK]` The app name, requested scopes, and browser address bar must be readable.

`[SAY]`

> The browser opens the Google OAuth consent flow. The consent screen shows the WhisperShortcut app name and the permissions requested by the app. The browser address bar is visible so the OAuth client information can be reviewed.

`[ACTION]` Approve the OAuth request and return to WhisperShortcut.

`[SAY]`

> I approve access because these permissions are required for the user-requested Calendar, Tasks, and Gmail features. After approval, the flow returns to WhisperShortcut and the app shows that the Google account is connected.

### 3. Calendar Read

`[ACTION]` Put Google Calendar on the left. Make today's demo events visible. Put WhisperShortcut on the right.

`[SAY]`

> First I will demonstrate Google Calendar access. On the left, Google Calendar shows the source calendar events for this test account. On the right, I will ask WhisperShortcut what is on my calendar today.

`[ACTION]` Type this prompt in WhisperShortcut:

```text
What is on my calendar today?
```

`[CHECK]` The visible Google Calendar events and the WhisperShortcut answer should match.

`[SAY]`

> The app returns the calendar events from Google Calendar. This shows how WhisperShortcut uses Calendar access to answer a user-requested question about upcoming events.

### 4. Calendar Create

`[ACTION]` Keep Google Calendar on the left and WhisperShortcut on the right.

`[SAY]`

> Next I will create a calendar event from WhisperShortcut. I will ask the app to create an event tomorrow at 4 PM called OAuth Verification Demo Review.

`[ACTION]` Type this prompt in WhisperShortcut:

```text
Create a calendar event tomorrow at 4 PM called OAuth Verification Demo Review.
```

`[ACTION]` Refresh or navigate Google Calendar and show the new event.

`[CHECK]` The event must be visible in Google Calendar.

`[SAY]`

> The app confirms the event creation. I will now check Google Calendar on the left. The new event is visible in the user's calendar, which demonstrates why WhisperShortcut requests calendar event write access. Read-only calendar access would not be sufficient for this feature.

### 5. Gmail Read-Only Search And Summary

`[ACTION]` Put Gmail on the left with the demo email visible. Put WhisperShortcut on the right.

`[SAY]`

> Next I will demonstrate Gmail access. WhisperShortcut requests Gmail read-only access. The app does not send emails, delete emails, change labels, or modify the mailbox.
>
> On the left, Gmail shows a test email from <demo@example.com>. On the right, I will ask WhisperShortcut to find the latest email from <demo@example.com> and summarize it.

`[ACTION]` Type this prompt in WhisperShortcut:

```text
Find the latest email from demo@example.com and summarize it.
```

`[CHECK]` The app should identify the visible email and summarize its body content. Do not show Gmail write actions.

`[SAY]`

> The app finds the matching email and summarizes the message content. This demonstrates why Gmail message body access is required. Metadata-only access would not be enough, because the assistant needs the email content to answer the user's question accurately.

### 6. Tasks Read

`[ACTION]` Put Google Tasks on the left with the demo task list visible. Put WhisperShortcut on the right.

`[SAY]`

> Now I will demonstrate Google Tasks access. On the left, Google Tasks shows the source task list for this test account. On the right, I will ask WhisperShortcut what my open tasks are.

`[ACTION]` Type this prompt in WhisperShortcut:

```text
What are my open tasks?
```

`[CHECK]` The visible Google Tasks list and the WhisperShortcut answer should match.

`[SAY]`

> The app returns the open tasks from Google Tasks. This shows how the app uses task access to answer a user-requested productivity question.

### 7. Tasks Create And Complete

`[ACTION]` Keep Google Tasks on the left and WhisperShortcut on the right.

`[SAY]`

> Next I will create a new task from WhisperShortcut. I will ask the app to add a task called Finish OAuth verification video.

`[ACTION]` Type this prompt in WhisperShortcut:

```text
Add a task called Finish OAuth verification video.
```

`[CHECK]` The new task must appear in Google Tasks.

`[SAY]`

> The task now appears in Google Tasks on the left. I will also ask WhisperShortcut to mark that task as completed.

`[ACTION]` Type this prompt in WhisperShortcut:

```text
Mark Finish OAuth verification video as completed.
```

`[CHECK]` The task must be marked completed in Google Tasks.

`[SAY]`

> The task is now completed in Google Tasks. This demonstrates why WhisperShortcut requests the full Tasks scope. Read-only task access would not be sufficient because users can ask the app to create and complete tasks.

### 8. Closing

`[ACTION]` Keep WhisperShortcut visible. Optionally keep the last Google source view visible on the left.

`[SAY]`

> This completes the demonstration of the requested Google scopes. Calendar access is used to read and create calendar events when the user asks. Tasks access is used to read, create, and complete tasks when the user asks. Gmail access is read-only and is used only to search and summarize email content requested by the user.
>
> WhisperShortcut does not use Google user data for advertising, does not perform background bulk syncing, and only accesses this data after the user connects their Google account and requests an action in the app.

## On-Screen Prompts To Type

Use these exact prompts during the recording:

```text
What is on my calendar today?
```

```text
Create a calendar event tomorrow at 4 PM called OAuth Verification Demo Review.
```

```text
Find the latest email from demo@example.com and summarize it.
```

```text
What are my open tasks?
```

```text
Add a task called Finish OAuth verification video.
```

```text
Mark Finish OAuth verification video as completed.
```

## Final Quality Checklist

- [ ] The video clearly shows WhisperShortcut.
- [ ] The OAuth consent screen is shown in English.
- [ ] The app name on the consent screen is visible.
- [ ] The browser address bar is visible during OAuth.
- [ ] Calendar source data and WhisperShortcut results are visible side by side.
- [ ] Gmail source data and WhisperShortcut results are visible side by side.
- [ ] Tasks source data and WhisperShortcut results are visible side by side.
- [ ] Gmail is only demonstrated as read-only.
- [ ] Calendar event creation is demonstrated.
- [ ] Task creation and completion are demonstrated.
- [ ] The final YouTube video is Unlisted.

## Reply To Google After Uploading

```text
Hello Google Trust and Safety team,

Thank you for the feedback. I have updated the demo video to show a side-by-side comparison of the source Google Calendar, Gmail, and Google Tasks data with the corresponding WhisperShortcut app results.

The updated video also demonstrates the complete OAuth consent flow and shows how each requested scope is used in the app.

Updated demo video: https://youtu.be/q7bjb6yX7K0

Best regards,
Magnus
```
