# Contributing

## Branch Workflow

Use `main` as the stable branch. Create a branch for each small change:

```sh
git checkout main
git pull
git checkout -b feature/short-description
```

Run tests before pushing:

```sh
cd PennDashboardKit
swift test
```

Then commit and push:

```sh
git add .
git commit -m "Short imperative summary"
git push origin feature/short-description
```

Open a pull request into `main`.

## Pull Request Expectations

Each PR should include:

- What changed.
- How it was tested.
- Screenshots for UI changes.
- Notes about any scraper assumptions.

## Local App Testing

Run the app directly:

```sh
cd PennDashboardKit
swift run penn-dashboard
```

Build a shareable app:

```sh
cd PennDashboardKit
bash scripts/bundle-mac.sh
```

## Design Implementation Notes

When implementing UI designs:

- Keep the dashboard as the first screen.
- Preserve the active/completed/other model.
- Do not expose raw sync or scraper details as primary actions.
- Prefer connection/setup states over repeated manual refresh buttons.
- Keep source badges visible: Canvas, Gradescope, Manual, Canvas Found.

## Scraper Implementation Notes

Canvas and Gradescope are intentionally session-cookie based. Keep parsing isolated in:

- `PennDashboardKit/Sources/PennDashboardKit/Gradescope/`
- `PennDashboardKit/Sources/PennDashboardKit/CanvasDiscovery/`
- `PennDashboardKit/Sources/PennDashboardKit/Canvas/`

Add tests with small sanitized HTML samples whenever selectors or parsing rules change.
