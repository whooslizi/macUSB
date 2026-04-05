# User Flow and Navigation

## Main Flow Contract

The primary flow remains:
- `WelcomeView -> SystemAnalysisView -> UniversalInstallationView -> CreationProgressView -> FinishUSBView`

Destructive start requires explicit confirmation.

## Current Runtime Behavior

- User selects source and runs analysis.
- Analysis resolves compatibility flags and workflow branch.
- User selects target USB and confirms destructive start.
- Progress screen reflects helper-driven stages.
- Finish screen reports success/failure/cancel plus cleanup status.

## Tools Flow: Downloader

- `Tools -> Download macOS installer...` opens downloader window.
- Discovery starts on entering downloader window (never on app startup).
- While discovery runs, header/options remain visible; list area shows scanning panel.
- After discovery completes, grouped systems list is shown.

## Update Trigger

Update when flow order, transitions, or gate behavior changes.
