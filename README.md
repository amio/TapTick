# TapTick

An app launcher, script runner, menu bar customizer, and utilities hub. The swiss army knife for Mac.

TapTick brings four essential Mac workflows together:

- **Applications:** Launch, focus, or hide any app with a global shortcut.

  ![Applications settings](./public/screenshots/settings-applications.png)

- **Scripts:** Write scripts then run them globally or display result in menu bar.

  ![Scripts settings](./public/screenshots/settings-scripts.png)

- **Menu Bar:** Show live script output in customizable one-line or two-line slots.

  ![Menu Bar settings](./public/screenshots/settings-menubar.png)

- **Utilities:** Keep focused Mac tools one shortcut away.
  - **Capture & Mark:** Capture a screen region to the clipboard, with optional line and rectangle annotations.
  - **Large Type:** Display text full-screen or turn it into a QR code.
  - **Keystroke Overlay:** Show key combinations in a customizable overlay for demos and recordings.
  - **Window Manager (planned):** Snap, resize, and reposition windows with keyboard shortcuts.

  ![Utilities settings](./public/screenshots/settings-utilities.png)

Install from [GitHub Releases](https://github.com/amio/TapTick/releases)

## Development

TapTick uses SwiftUI and Swift 6, targets macOS 26+, and generates its Xcode 27
project from [project.yml](project.yml). Install Xcode and Homebrew, then:

```bash
make setup      # Install missing tools and generate the Xcode project
make run        # Build and launch TapTick Dev, replacing its running instance
```

After Swift changes, run `make format`, `make lint`, `make test`, and the relevant
build (`make build` for Debug or `make release` for Release). Unit tests use
`make test`; `make uitest` additionally drives the application UI.

Run `make gen` after changing `project.yml`; generated Xcode metadata is not
maintained by hand. Use `make open` to regenerate and open the project, and
`make help` for all available targets.

Debug uses the separate `TapTick Dev` identity and requires local development
signing credentials. See the [release guide](release.md) for signing setup,
versioning, CI behavior, notarization, and Sparkle updates.
