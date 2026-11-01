# ChartForge

ChartForge is an original, responsive chart studio for building animated data stories. Signed-in users can save private drafts to their Supabase account and publish projects to a public community feed. Signed-out drafts stay in the current browser. New workspaces start empty; your own CSV or JSON data is required to populate a chart.

## Run it

Serve this folder from a local web server, then open the address it prints. For example:

```sh
cd outputs/chartforge
python3 -m http.server 4173
```

Open `http://localhost:4173`. No package installation or build step is required. A web server gives the browser a stable origin for saved projects and share links.

## Included

- Dashboard, project library, search, sort, status filters, and grid/list views.
- Nine chart types, with animated bar-race playback, pause, restart, frame stepping, timeline, ranking, and speed settings.
- Editable data table plus CSV and JSON upload or paste import. Supported JSON formats are an array of objects (for example, `[{"year":2020,"Northland":12}]`) and `{ "timeLabel": "Year", "categories": ["Northland"], "rows": [[2020, 12]] }`.
- Project create, save, edit, duplicate, delete, publish, public chart pages, likes, reports, profile editing, and a local moderation preview.
- Supabase email/password and Google sign-in, email confirmation, private account drafts, shared public projects, public likes and view counts, PKCE OAuth callback handling, session restore, and sign-out.
- SVG chart export, CSV dataset download, JSON chart configuration export, share links, and full-screen presentation mode.
- No seeded charts, accounts, or datasets. Existing demo records are removed on first load while saved projects you created are retained.

## Main flow

1. Choose **Create Chart** to start with a blank chart.
2. Open **Dataset** to edit cells or import a CSV/JSON file or pasted data.
3. Use the **General**, **Animation**, **Labels**, and **Style** controls to customize the chart. Playback controls change the displayed frame.
4. Choose **Save** to keep a private draft in this browser, or **Publish** to make a public chart page.
5. Open **Public Projects** to find a published chart. Open it to play, like, share, or download its configuration.

Signed-in private drafts and published projects sync through Supabase. Signed-out drafts stay in browser storage. Download a local workspace backup from **Settings → Data & privacy** before clearing browser storage. The moderation role selector is a local interface preview; it does not grant production privileges.

## Configure Supabase sign-in

1. Create a Supabase project.
2. In Supabase Authentication settings, enable email/password sign-up and **Confirm email** if you want email accounts.
3. Add the app URL as an allowed redirect URL. For the included local server, use `http://localhost:4173/`.
4. Configure email delivery in Supabase. Its built-in sender is rate-limited; configure custom SMTP for reliable production email.
5. Run `supabase/schema.sql` in the Supabase SQL Editor. This creates profile, dataset, project, and community tables with owner-only private access and public read access for published projects.
6. In ChartForge, open **Settings → Account** and check the supplied project URL and publishable key. The project URL and browser-safe publishable key are prefilled for this Supabase project. Never put a service-role or secret key in the browser.
7. To enable Google, create a Web OAuth client in Google Cloud and add `https://btkxgzzuitnwpyyqqrxg.supabase.co/auth/v1/callback` as an **Authorized redirect URI**. Then enable Google in Supabase Authentication → Providers and enter that OAuth client ID and secret. Add the production app URL and any local development URL to Supabase's allowed Redirect URLs.
8. Use **Create account** for email sign-up; users confirm their email before their first email/password sign-in. **Continue with Google** signs in through Supabase OAuth once the provider is configured.

Run [`supabase/schema.sql`](supabase/schema.sql) in the Supabase SQL Editor to enable project sync. Row-level security lets each account read and edit its own private projects; everyone can read published public projects. The app sends the publishable key plus the signed-in user's Auth token and never uses a service-role key in the browser. Production moderation should use trusted server-side authorization; client-side role selection is not a security boundary. The current static app stores public connection details in this browser's local storage.

## Verification checklist

- Create a chart, change its title, edit data, and preview more than one frame.
- Import valid CSV and JSON; confirm malformed data reports a useful error.
- Save, navigate away, reopen the project, then duplicate and delete a copy.
- Publish a chart, open its public page, use playback, and try like/share/export actions.
- Search projects and check the public, popular, top, and approved collections.
- Resize the browser to a narrow viewport and check the editor and project cards.

Run through the checklist above after launching the local server to verify the full create, import, preview, save, and publish flow.
